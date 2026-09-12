import Foundation

/// Per-provider on/off toggles surfaced to the user via `server.json`.
/// `nil` is the "let Sissy decide" state: Claude Code is
/// always on (it's the v0.1.0 baseline), and Codex is auto-detected from
/// disk activity. Explicit `false` forces off even if data exists; explicit
/// `true` forces on even if no recent activity is detected.
struct ProviderToggles: Sendable, Codable {
    var claudeCode: Bool?
    var codex: Bool?

    static let defaults = ProviderToggles(claudeCode: nil, codex: nil)
}

struct ServerConfig: Sendable, Codable {
    var claudeDataDir: String
    var codexDataDir: String
    var pollIntervalSeconds: Double
    var pricingOverride: [String: ModelPricing]?
    /// Whether Sissy fetches LiteLLM's rate table at runtime
    /// (`PriceCatalog`). `nil` means on — it's what keeps a newly launched
    /// model from mispricing until the next Sissy release. Set `false` to pin
    /// pricing to the tables compiled into the binary and make Sissy fully
    /// offline; `pricingOverride` still applies either way.
    var remotePricing: Bool?
    var providers: ProviderToggles
    /// Whether Sissy reads Claude Code's OAuth token from the login
    /// keychain to show that CLI's 5-hour and weekly subscription windows.
    /// Off unless the user asks for it in Settings: turning it on is what
    /// makes the one-time macOS keychain prompt expected rather than something
    /// a first launch springs on someone who never asked for limits.
    var claudeLimits: Bool
    /// How many days of the day-by-model archive Sissy keeps. `nil` means the
    /// default; `0` stops it recording and reporting, and leaves what is
    /// already there for the Settings button, which is the one place a user
    /// asks for their own data to be deleted. Clamped on read, so a
    /// hand-edited absurdity cannot turn "keep some days" into "keep forever".
    var historyRetentionDays: Int?
    /// Whether Sissy holds a power assertion so the Mac does not idle to
    /// sleep. Persisted here rather than kept in memory because it is a
    /// setting, not a hold: a user who switched their Mac to never sleep
    /// expects that to survive Sissy restarting at login.
    var keepAwake: KeepAwakeMode
    /// Whether the keep-awake hold covers the screen as well as the Mac.
    ///
    /// On, which is the hold someone switching keep-awake on from the panel
    /// expects. Off is for the Mac left running agents unattended: the display
    /// sleeps and the Mac locks itself on its usual schedule while the system
    /// assertion keeps the work going. A `server.json` written before this key
    /// existed decodes through the partial-config path below and lands on the
    /// default, which is the behaviour it already had.
    var keepScreenAwake: Bool

    static let defaults = ServerConfig(
        claudeDataDir: "~/.claude/projects",
        codexDataDir: "~/.codex/sessions",
        pollIntervalSeconds: 60.0,
        pricingOverride: nil,
        remotePricing: nil,
        providers: .defaults,
        claudeLimits: false,
        historyRetentionDays: nil,
        keepAwake: .off,
        keepScreenAwake: true
    )

    static var defaultURL: URL {
        SissyPaths.appSupportDir.appendingPathComponent("server.json")
    }

    static func load(from url: URL = ServerConfig.defaultURL) throws -> ServerConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .defaults
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(ServerConfig.self, from: data)
        } catch {
            // Partial config OK: fall back to defaults and overlay decodable keys.
            let merged = try mergeWithDefaults(data: data) ?? .defaults
            return merged
        }
    }

    private static func mergeWithDefaults(data: Data) throws -> ServerConfig? {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var merged = defaults
        if let v = obj["claudeDataDir"] as? String { merged.claudeDataDir = v }
        if let v = obj["codexDataDir"] as? String { merged.codexDataDir = v }
        if let v = obj["pollIntervalSeconds"] as? Double { merged.pollIntervalSeconds = v }
        if let v = obj["remotePricing"] as? Bool { merged.remotePricing = v }
        if let v = obj["claudeLimits"] as? Bool { merged.claudeLimits = v }
        if let v = obj["historyRetentionDays"] as? Int { merged.historyRetentionDays = v }
        // An unknown mode reads as off rather than failing the whole file: a
        // value written by a newer build must not cost the user every other
        // setting in here.
        merged.keepAwake = (obj["keepAwake"] as? String).flatMap(KeepAwakeMode.init(rawValue:)) ?? .off
        if let v = obj["keepScreenAwake"] as? Bool { merged.keepScreenAwake = v }
        if let prov = obj["providers"] as? [String: Any] {
            var toggles = ProviderToggles.defaults
            toggles.claudeCode = prov["claudeCode"] as? Bool
            toggles.codex = prov["codex"] as? Bool
            merged.providers = toggles
        }
        if let raw = obj["pricingOverride"],
            let nested = try? JSONSerialization.data(withJSONObject: raw),
            let decoded = try? JSONDecoder().decode([String: ModelPricing].self, from: nested)
        {
            merged.pricingOverride = decoded
        }
        return merged
    }

    /// Atomic write to disk. Used by the engine's runtime config-change paths
    /// so a change survives a relaunch. Pretty-printed + sorted-keys so the
    /// file stays hand-editable.
    static func save(_ config: ServerConfig, to url: URL = ServerConfig.defaultURL) throws {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        // Owner-only, and owner-only before it is reachable under its own
        // name. Nothing secret lives here since the bearer token went with the
        // socket, but this is the file that decides which directories Sissy
        // reads and what it prices them at, and there is no reason for another
        // user on the machine to be able to edit it. Writing first and
        // chmod-ing after left the file world-readable for the width of that
        // gap, which is the only window the mode has to cover.
        let staging = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        do {
            try data.write(to: staging)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: staging.path)
            // `rename(2)` rather than `FileManager.replaceItemAt`, which needs
            // something already there to replace: this is also the first save
            // on a fresh install. It keeps the mode set above, where an atomic
            // `Data.write` would leave the default one until the chmod landed.
            if rename(staging.path, url.path) != 0 {
                let code = errno
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(code),
                    userInfo: [NSFilePathErrorKey: url.path])
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Retention in days, bounded. Reading it anywhere else than through
    /// here would let an unset value and a hand-edited one disagree about
    /// what the archive keeps.
    var resolvedHistoryRetentionDays: Int {
        guard let historyRetentionDays else { return UsageHistoryStore.defaultRetentionDays }
        return min(max(historyRetentionDays, 0), UsageHistoryStore.maxRetentionDays)
    }

    var resolvedClaudeDataDir: URL {
        Self.expandTilde(claudeDataDir)
    }

    /// Resolved Codex rollout dir. Honors the `CODEX_HOME` env var when set
    /// (matches the upstream `codex` CLI behavior); otherwise the configured
    /// path. Tilde-prefixed paths expand against `$HOME`.
    var resolvedCodexDataDir: URL {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appendingPathComponent("sessions")
        }
        return Self.expandTilde(codexDataDir)
    }

    private static func expandTilde(_ path: String) -> URL {
        if path.hasPrefix("~/") {
            return URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }

    var remotePricingEnabled: Bool {
        remotePricing ?? true
    }
}
