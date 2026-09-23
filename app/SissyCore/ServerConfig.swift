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

    /// One provider's toggle, by the id the frame and the readiness list
    /// carry, so a surface that has a row can set that row without knowing
    /// which stored property is behind it.
    ///
    /// Named fields rather than a map because there are two of them and a map
    /// would have to answer for a key no build knows. An id this build does
    /// not meter reads `nil` and writes nothing, which is why the engine
    /// checks the id against its own list before calling: a toggle written
    /// under a name nothing reads is a switch that silently does nothing.
    subscript(id: String) -> Bool? {
        get {
            switch id {
            case ProviderID.claudeCode: return claudeCode
            case ProviderID.codex: return codex
            default: return nil
            }
        }
        set {
            switch id {
            case ProviderID.claudeCode: claudeCode = newValue
            case ProviderID.codex: codex = newValue
            default: break
            }
        }
    }
}

/// Which of a forge row's counters the panel carries.
///
/// `nil` means on, which is what `ProviderToggles` means by it and for the
/// same reason: a `server.json` written before a counter existed must not read
/// as that counter being switched off. There is no entry for the contribution
/// total, because it is what the section is called.
///
/// **A counter switched off is not fetched**, so this is not only a rendering
/// choice — which is why it lives here rather than in a view's own state, and
/// why changing one rebuilds the poll the way connecting a forge does.
struct ForgeCounters: Sendable, Codable, Equatable {
    var merged: Bool?
    var issues: Bool?
    var comments: Bool?

    static let defaults = Self(merged: nil, issues: nil, comments: nil)

    /// One counter's switch, by the name a Settings row carries, so a surface
    /// listing them needs to know no stored property. The same shape
    /// `ProviderToggles` is on.
    subscript(counter: ForgeCounter) -> Bool? {
        get {
            switch counter {
            case .merged: return merged
            case .issues: return issues
            case .comments: return comments
            }
        }
        set {
            switch counter {
            case .merged: merged = newValue
            case .issues: issues = newValue
            case .comments: comments = newValue
            }
        }
    }

    /// The counters that are on, which is what the reader is built with. An
    /// absent switch is an on one.
    var enabled: Set<ForgeCounter> {
        Set(ForgeCounter.allCases.filter { self[$0] ?? true })
    }
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
    /// Whether Sissy reads each metering vendor's public status page, so a CLI
    /// that has started failing can be told apart from a vendor that has.
    ///
    /// On, like `remotePricing` and for the same reason: it is a reading the
    /// user opened the app for, it carries no account, no credential and no
    /// identity, and the request is one a browser tab would make anyway. Off
    /// is for the Mac that is to make no request Sissy was not asked for.
    /// Non-optional, so a `server.json` written before this key existed falls
    /// through the partial-config path below and lands on the default, which
    /// is what `keepScreenAwake` already does.
    var statusChecks: Bool
    var providers: ProviderToggles
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
    /// Whether Sissy registers a `SessionStart` hook with the CLIs it meters,
    /// so a session writes down which repository its directory belongs to
    /// while that directory still exists.
    ///
    /// Off unless the user asks for it. It is the only thing Sissy writes
    /// outside its own directory, and a first launch that edited two other
    /// programs' configuration files would be exactly the surprise the rest of
    /// the app is built to avoid.
    var agentHooks: Bool
    /// Whether a removal is still owed to one of those files.
    ///
    /// Written before either file is touched and cleared only once both are
    /// clear, so a removal interrupted — by a crash, a quit, a file Sissy
    /// could not rewrite — is retried at the next launch. Without it the
    /// switch is already off and nothing would ever go back for the line left
    /// in someone else's configuration. Like `keepScreenAwake`, a
    /// `server.json` written before this key existed decodes through the
    /// partial-config path below and lands on the default.
    var agentHooksRemovalPending: Bool

    /// Which counters each forge row carries, and therefore which ones are
    /// read at all. Optional so a `server.json` predating it decodes straight
    /// through with every counter on.
    var forgeCounters: ForgeCounters?

    static let defaults = ServerConfig(
        claudeDataDir: "~/.claude/projects",
        codexDataDir: "~/.codex/sessions",
        pollIntervalSeconds: 60.0,
        pricingOverride: nil,
        remotePricing: nil,
        statusChecks: true,
        providers: .defaults,
        historyRetentionDays: nil,
        keepAwake: .off,
        keepScreenAwake: true,
        agentHooks: false,
        agentHooksRemovalPending: false,
        forgeCounters: nil
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

    /// What a run of the app reads out of `server.json`: the config it runs
    /// on, and whether it may save over the file.
    struct LoadedForRun {
        let config: ServerConfig
        /// False when the file is there and will not parse. The run carries
        /// on with the defaults, and saving them would replace the user's
        /// overrides, data directories and switches for good, so nothing this
        /// run changes is written back.
        let isWritable: Bool
        /// Where the unreadable bytes were copied, or nil when there were
        /// none to copy or the copy failed.
        let setAside: URL?
    }

    /// Suffix of the copy an unreadable `server.json` is kept under, beside
    /// the file itself.
    static let unreadableCopySuffix = ".unreadable"

    /// `load`, for a run of the app rather than a tool that can stop on the
    /// error.
    ///
    /// The file is hand-editable, so an unclosed brace is an ordinary way for
    /// it to stop parsing. Before this the run fell back to the defaults
    /// silently and the first toggle saved them over the file. Now the bytes
    /// are copied aside, the failure is logged, and the file stays exactly as
    /// the user left it for them to fix.
    static func loadForRun(from url: URL = ServerConfig.defaultURL) -> LoadedForRun {
        do {
            return LoadedForRun(config: try load(from: url), isWritable: true, setAside: nil)
        } catch {
            let copy = setAside(url)
            sissyLog(
                "sissy: \(url.path) could not be read (\(error)); running on the defaults "
                    + "and leaving the file as it is, a copy is at \(copy?.path ?? "nowhere")")
            return LoadedForRun(config: .defaults, isWritable: false, setAside: copy)
        }
    }

    /// Copies the file beside itself, replacing an earlier copy: the original
    /// is never written over, so the copy is only ever of the bytes still
    /// there.
    private static func setAside(_ url: URL) -> URL? {
        let copy = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + unreadableCopySuffix)
        do {
            if FileManager.default.fileExists(atPath: copy.path) {
                try FileManager.default.removeItem(at: copy)
            }
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        } catch {
            sissyLog("sissy: could not copy \(url.path) aside: \(error)")
            return nil
        }
    }

    /// The counter switches out of a partly-readable file, key by key.
    ///
    /// This path is what a file with one unreadable field falls through, so a
    /// counter left out of it would come back **on** — and on, for this
    /// setting, means asking the vendor for it again on the next poll. A
    /// switch a neighbouring key's typo silently undoes is worse than no
    /// switch. Its own function because the overlay above is already at the
    /// complexity the linter allows, and this reads as one question anyway.
    private static func forgeCounters(in obj: [String: Any]) -> ForgeCounters? {
        guard let counters = obj["forgeCounters"] as? [String: Any] else { return nil }
        var switches = ForgeCounters.defaults
        for counter in ForgeCounter.allCases {
            switches[counter] = counters[counter.rawValue] as? Bool
        }
        return switches
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
        if let v = obj["historyRetentionDays"] as? Int { merged.historyRetentionDays = v }
        // An unknown mode reads as off rather than failing the whole file: a
        // value written by a newer build must not cost the user every other
        // setting in here.
        merged.keepAwake = (obj["keepAwake"] as? String).flatMap(KeepAwakeMode.init(rawValue:)) ?? .off
        if let v = obj["keepScreenAwake"] as? Bool { merged.keepScreenAwake = v }
        if let v = obj["statusChecks"] as? Bool { merged.statusChecks = v }
        if let v = obj["agentHooks"] as? Bool { merged.agentHooks = v }
        if let v = obj["agentHooksRemovalPending"] as? Bool { merged.agentHooksRemovalPending = v }
        if let prov = obj["providers"] as? [String: Any] {
            var toggles = ProviderToggles.defaults
            toggles.claudeCode = prov["claudeCode"] as? Bool
            toggles.codex = prov["codex"] as? Bool
            merged.providers = toggles
        }
        merged.forgeCounters = forgeCounters(in: obj) ?? merged.forgeCounters
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

    static func expandTilde(_ path: String) -> URL {
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
