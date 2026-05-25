import Foundation

/// Per-provider on/off toggles surfaced to the user via `server.json`.
/// `nil` is the "let the daemon decide" state: ClaudeCodeUsageReader is
/// always on (it's the v0.1.0 baseline), and Codex is auto-detected from
/// disk activity. Explicit `false` forces off even if data exists; explicit
/// `true` forces on even if no recent activity is detected.
struct ProviderToggles: Sendable, Codable, Equatable {
    var claudeCode: Bool?
    var codex: Bool?

    static let defaults = ProviderToggles(claudeCode: nil, codex: nil)
}

struct ServerConfig: Sendable, Codable {
    var host: String
    var port: Int
    var authToken: String
    var claudeDataDir: String
    var codexDataDir: String
    var pollIntervalSeconds: Double
    var primaryMetric: String
    var stateThresholds: StateThresholds
    var pricingOverride: [String: ModelPricing]?
    /// `MilestoneFrequency` preset key. Drives the whole-dollar cost step;
    /// see `MilestoneFrequency.presets`. Unknown values fall back to
    /// `"normal"` at lookup time, so a hand-edited typo degrades gracefully.
    var milestoneFrequency: String
    var providers: ProviderToggles

    static let defaults = ServerConfig(
        host: "127.0.0.1",
        // Default port differs between Debug (8788) and Release (8787) so a
        // dev daemon launched by launchd before the app has written its own
        // server.json doesn't fight the release daemon on 8787.
        port: SissyPaths.defaultServerPort,
        authToken: "",
        claudeDataDir: "~/.claude/projects",
        codexDataDir: "~/.codex/sessions",
        pollIntervalSeconds: 60.0,
        primaryMetric: "tokens",
        stateThresholds: StateThresholds(),
        pricingOverride: nil,
        milestoneFrequency: "normal",
        providers: .defaults
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
            return restrictTokenlessWildcardBind(try decoder.decode(ServerConfig.self, from: data))
        } catch {
            // Partial config OK: fall back to defaults and overlay decodable keys.
            let merged = try mergeWithDefaults(data: data) ?? .defaults
            return restrictTokenlessWildcardBind(merged)
        }
    }

    private static func mergeWithDefaults(data: Data) throws -> ServerConfig? {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var merged = defaults
        if let v = obj["host"] as? String { merged.host = v }
        if let v = obj["port"] as? Int { merged.port = v }
        if let v = obj["authToken"] as? String { merged.authToken = v }
        if let v = obj["claudeDataDir"] as? String { merged.claudeDataDir = v }
        if let v = obj["codexDataDir"] as? String { merged.codexDataDir = v }
        if let v = obj["pollIntervalSeconds"] as? Double { merged.pollIntervalSeconds = v }
        if let v = obj["primaryMetric"] as? String { merged.primaryMetric = v }
        if let v = obj["milestoneFrequency"] as? String { merged.milestoneFrequency = v }
        if let prov = obj["providers"] as? [String: Any] {
            var toggles = ProviderToggles.defaults
            toggles.claudeCode = prov["claudeCode"] as? Bool
            toggles.codex = prov["codex"] as? Bool
            merged.providers = toggles
        }
        if let raw = obj["stateThresholds"],
            let nested = try? JSONSerialization.data(withJSONObject: raw),
            let decoded = try? JSONDecoder().decode(StateThresholds.self, from: nested)
        {
            merged.stateThresholds = decoded
        }
        if let raw = obj["pricingOverride"],
            let nested = try? JSONSerialization.data(withJSONObject: raw),
            let decoded = try? JSONDecoder().decode([String: ModelPricing].self, from: nested)
        {
            merged.pricingOverride = decoded
        }
        return merged
    }

    /// Atomic write to disk. Used by runtime config-change paths (e.g.
    /// menubar "Milestone frequency" picker) so the new value survives
    /// daemon restarts. Pretty-printed + sorted-keys so the file stays
    /// hand-editable.
    static func save(_ config: ServerConfig, to url: URL = ServerConfig.defaultURL) throws {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: url, options: [.atomic])
        // server.json carries the bearer token in plaintext for the
        // daemon (this process) to re-read on restart. Match the app's
        // permissions so a same-user unprivileged process can't read it.
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
    }

    private static func restrictTokenlessWildcardBind(_ config: ServerConfig) -> ServerConfig {
        guard config.authToken.isEmpty, isWildcardHost(config.host) else { return config }
        var restricted = config
        restricted.host = "127.0.0.1"
        return restricted
    }

    private static func isWildcardHost(_ host: String) -> Bool {
        host == "0.0.0.0" || host == "::" || host == "*"
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

    var resolvedPrimaryMetric: PrimaryMetric {
        PrimaryMetric(rawValue: primaryMetric) ?? .tokens
    }
}
