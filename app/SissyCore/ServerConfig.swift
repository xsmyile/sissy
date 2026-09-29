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
/// total, because it is the figure the section is about.
///
/// **A counter switched off is not fetched**, so this is not only a rendering
/// choice — which is why it lives here rather than in a view's own state, and
/// why changing one rebuilds the poll the way connecting a forge does.
struct ForgeCounters: Sendable, Codable, Equatable {
    var merged: Bool?
    var issues: Bool?
    var comments: Bool?
    var latest: Bool?

    static let defaults = Self(merged: nil, issues: nil, comments: nil, latest: nil)

    /// One counter's switch, by the name a Settings row carries, so a surface
    /// listing them needs to know no stored property. The same shape
    /// `ProviderToggles` is on.
    subscript(counter: ForgeCounter) -> Bool? {
        get {
            switch counter {
            case .merged: return merged
            case .issues: return issues
            case .comments: return comments
            case .latest: return latest
            }
        }
        set {
            switch counter {
            case .merged: merged = newValue
            case .issues: issues = newValue
            case .comments: comments = newValue
            case .latest: latest = newValue
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
    /// Non-optional, and a `server.json` written before this key existed
    /// lands on the default, which is what `keepScreenAwake` already does.
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
    /// existed lands on the default, which is the behaviour it already had.
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
    /// `server.json` written before this key existed lands on the default.
    var agentHooksRemovalPending: Bool

    /// Which counters each forge row carries, and therefore which ones are
    /// read at all. Optional so a `server.json` predating it decodes straight
    /// through with every counter on.
    var forgeCounters: ForgeCounters?

    /// Whether Sissy reads the Mac's own memory pressure, swap, load and
    /// uptime.
    ///
    /// On: the reading asks for no permission, holds no entitlement and makes
    /// no request, which is what lets a default switch it on. Like
    /// `statusChecks`, a `server.json` written before this key existed lands
    /// on the default.
    var macHealth: Bool

    /// Whether Sissy reads the disks, for the Disk tab and the menu bar's dot,
    /// and samples their byte counters once a second while the Disk tab is on
    /// screen and logs them every five seconds otherwise, see `LiveCadence`.
    ///
    /// On by default and apart from `macHealth`, for the same reasons: it asks
    /// for nothing, and off means no disk is read at all, the counters
    /// included.
    ///
    /// **A file that predates the key takes `macHealth`'s value**, not the
    /// default: before the split that one switch also stopped the disk reads,
    /// so a user who had switched it off must not find the disks read after an
    /// upgrade. A file that names `disk` keeps what it says.
    var disk: Bool

    /// Whether the panel carries a Network tab, which samples the Mac's
    /// interfaces once a second while it is on screen and logs their byte
    /// counters every five seconds otherwise, see `LiveCadence`.
    ///
    /// On, for `macHealth`'s reasons: the counters, the default route and the
    /// Wi-Fi signal all answer with no permission and no request.
    var network: Bool

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
        forgeCounters: nil,
        macHealth: true,
        disk: true,
        network: true
    )

    static var defaultURL: URL {
        SissyPaths.appSupportDir.appendingPathComponent("server.json")
    }

    static func load(from url: URL = ServerConfig.defaultURL) throws -> ServerConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .defaults
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
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

/// One decoder for the whole file, key by key.
///
/// The file is hand-editable, so a key can be absent, because the file
/// predates it, or unreadable, because of a typo. Either lands that key on its
/// default and costs nothing else: a switch a neighbouring key's typo silently
/// undid would be worse than no switch, and for a forge counter on means
/// asking the vendor for it again on the next poll. A file that is not an
/// object at all reads as the defaults. Only bytes that are not JSON throw,
/// which `loadForRun` answers for.
///
/// One decoder rather than the synthesized one with an overlay behind it,
/// because two had to be kept in step by hand, and a key added to only one of
/// them would have every existing file read it as its default.
extension ServerConfig {
    init(from decoder: any Decoder) throws {
        guard let keys = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = .defaults
            return
        }
        let defaults = Self.defaults
        claudeDataDir = keys.lenient(.claudeDataDir) ?? defaults.claudeDataDir
        codexDataDir = keys.lenient(.codexDataDir) ?? defaults.codexDataDir
        pollIntervalSeconds = keys.lenient(.pollIntervalSeconds) ?? defaults.pollIntervalSeconds
        pricingOverride = keys.lenient(.pricingOverride) ?? defaults.pricingOverride
        remotePricing = keys.lenient(.remotePricing) ?? defaults.remotePricing
        statusChecks = keys.lenient(.statusChecks) ?? defaults.statusChecks
        providers = keys.lenient(.providers) ?? defaults.providers
        historyRetentionDays = keys.lenient(.historyRetentionDays) ?? defaults.historyRetentionDays
        keepAwake = keys.lenient(.keepAwake) ?? defaults.keepAwake
        keepScreenAwake = keys.lenient(.keepScreenAwake) ?? defaults.keepScreenAwake
        agentHooks = keys.lenient(.agentHooks) ?? defaults.agentHooks
        agentHooksRemovalPending =
            keys.lenient(.agentHooksRemovalPending) ?? defaults.agentHooksRemovalPending
        forgeCounters = keys.lenient(.forgeCounters) ?? defaults.forgeCounters
        macHealth = keys.lenient(.macHealth) ?? defaults.macHealth
        disk = keys.lenient(.disk) ?? macHealth
        network = keys.lenient(.network) ?? defaults.network
    }
}

/// Key by key for the same reason as the file around it: one unreadable
/// provider toggle must not reset the other.
extension ProviderToggles {
    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        self.init(claudeCode: keys.lenient(.claudeCode), codex: keys.lenient(.codex))
    }
}

/// Key by key, so a typo in one counter's switch leaves every other one as the
/// user set it rather than switching them all back on.
extension ForgeCounters {
    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            merged: keys.lenient(.merged), issues: keys.lenient(.issues),
            comments: keys.lenient(.comments), latest: keys.lenient(.latest))
    }
}

extension KeyedDecodingContainer {
    /// The value under `key`, or nil when it is absent, null or of a shape
    /// that does not decode, which a hand-edited file is free to hold. An
    /// unknown `KeepAwakeMode` written by a newer build is the case that
    /// shape covers.
    fileprivate func lenient<Value: Decodable>(_ key: Key) -> Value? {
        try? decodeIfPresent(Value.self, forKey: key)
    }
}
