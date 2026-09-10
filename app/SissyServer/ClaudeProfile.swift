import Foundation

/// Reads the subscription plan Claude Code records in its own config file.
///
/// Nothing else on the Claude side answers for it. The usage endpoint the
/// limits probe polls carries utilization buckets and no plan field
/// (measured), and the copy in the login keychain sits behind the
/// authorization prompt the `claudeLimits` toggle exists to gate — reaching
/// for it would put a keychain dialog in front of someone who only switched
/// the daemon on. `.claude.json` is therefore the one source that also
/// answers for a user who never enabled limits.
///
/// A class rather than an actor because `UsageProvider.currentPlan()` is
/// nonisolated: the aggregator reads it while the emitting provider still
/// holds its own actor, so an actor hop here would deadlock the pair.
final class ClaudeProfileSource: @unchecked Sendable {
    private static let fileName = ".claude.json"
    private static let configDirEnvVar = "CLAUDE_CONFIG_DIR"

    /// Claude Code rewrites this file on nearly every interaction — project
    /// history, feature counters — so a changed mtime is no evidence the plan
    /// moved, while the plan itself changes on the order of never. The floor
    /// keeps the safety-net poll from re-parsing 300 KB every minute.
    private static let minimumReparseInterval: TimeInterval = 900

    /// `oauthAccount.organizationType` prefixes the plan the CLI displays:
    /// `claude_max` against the bare `max` its own label switch takes.
    /// Verified against 2.1.267, whose enumeration is exactly
    /// pro / max / team / enterprise.
    private static let planPrefix = "claude_"

    /// Claude Code's config file, in the config home the CLI resolves for
    /// itself: `CLAUDE_CONFIG_DIR` when set, `$HOME` otherwise — the same
    /// env-var deference `ServerConfig.resolvedCodexDataDir` pays `CODEX_HOME`.
    /// Deliberately not derived from `claudeDataDir`: that setting points at
    /// the projects tree, which is not where this file lives.
    static var defaultURL: URL {
        let configured = ProcessInfo.processInfo.environment[configDirEnvVar]
        let configHome =
            configured.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return configHome.appendingPathComponent(fileName)
    }

    private let url: URL
    private let lock = NSLock()
    private var plan: String?
    private var lastParsedAt: Date = .distantPast
    private var lastMTime: TimeInterval = 0

    init(url: URL = ClaudeProfileSource.defaultURL) {
        self.url = url
    }

    /// Plan last read, as the CLI's own token (`max`, `team`). Nil until a
    /// refresh finds one, and nil for good for an API-key user or a config
    /// file with no `oauthAccount` — which leaves the panel row without a
    /// plan rather than guessing at one.
    func currentPlan() -> String? { lock.withLock { plan } }

    /// Re-reads the file when it has changed on disk and the floor has
    /// passed. A file that has stopped naming a plan clears the held one: a
    /// signed-out CLI should not leave a stale plan on the row.
    func refresh(now: Date = Date()) {
        let (parsedBefore, knownMTime, dueAt) = lock.withLock {
            (lastParsedAt != .distantPast, lastMTime, lastParsedAt + Self.minimumReparseInterval)
        }
        if parsedBefore && now < dueAt { return }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
        else { return }
        if parsedBefore && abs(mtime - knownMTime) < UsageReaderShared.mtimeTolerance { return }
        guard let data = try? Data(contentsOf: url) else { return }
        let parsed = Self.parsePlan(data)
        lock.withLock {
            plan = parsed
            lastParsedAt = now
            lastMTime = mtime
        }
    }

    /// Pulls the plan out of a `.claude.json` payload. Returns nil for every
    /// shape that does not name one, so a config file the CLI reorganises
    /// costs the panel a plan rather than showing a wrong one.
    static func parsePlan(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let account = root["oauthAccount"] as? [String: Any],
            let organizationType = account["organizationType"] as? String
        else { return nil }
        let token =
            organizationType.hasPrefix(planPrefix)
            ? String(organizationType.dropFirst(planPrefix.count))
            : organizationType
        return UsageReaderShared.sanitizedPlanToken(token)
    }
}
