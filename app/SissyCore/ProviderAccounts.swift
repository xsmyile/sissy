import Foundation

/// Which CLI a provider instance reads, and which of that CLI's accounts.
///
/// One person holds more than one account with the same vendor — a personal
/// subscription and a work seat — and the two are not one reading: they have
/// their own plan, their own windows, their own spend cap and their own
/// tokens. The vendor alone can therefore no longer identify a provider, and
/// what replaces it is this pair.
///
/// The account of the *first* account is nil rather than a name, so its `id`
/// is the bare vendor string it has always been. That is not tidiness: the id
/// is the suffix on the persistence file and the directory name in the
/// archive, so giving the existing account a key would strand every offset
/// and every recorded day behind a renamed file.
struct ProviderKey: Sendable, Equatable, Hashable {
    /// Separates the two halves in the flat id. Not a path or a host
    /// separator: the id names a file and a directory, so it must be a
    /// character neither the filesystem nor a user's label can collide with.
    static let separator: Character = ":"

    /// The CLI: `claude-code`, `codex`. What the app words, colours and draws
    /// a mark for.
    let vendor: String
    /// Which account of it, or nil for the one that was there before accounts
    /// existed.
    let account: String?

    /// Flat form, which is what crosses to the app, names the snapshot and
    /// keys the archive.
    var id: String {
        guard let account, !account.isEmpty else { return vendor }
        return "\(vendor)\(Self.separator)\(account)"
    }

    init(vendor: String, account: String? = nil) {
        self.vendor = vendor
        self.account = (account?.isEmpty ?? true) ? nil : account
    }

    /// Reads a flat id back. Total on purpose: an id from an older snapshot,
    /// a hand-edited config or a build that predates accounts is a vendor with
    /// no account, which is exactly what it meant when it was written.
    init(id: String) {
        guard let cut = id.firstIndex(of: Self.separator) else {
            self.init(vendor: id, account: nil)
            return
        }
        self.init(
            vendor: String(id[id.startIndex..<cut]),
            account: String(id[id.index(after: cut)...]))
    }

    /// The vendor half of a flat id, for the surfaces that colour and name a
    /// row rather than key one.
    static func vendor(of id: String) -> String { Self(id: id).vendor }
}

/// One account of one vendor, as `server.json` records it.
///
/// `home` is the whole of it. Both CLIs relocate their entire state — the
/// session logs, the credential, the profile the plan is read from — under one
/// environment variable (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`), which is also the
/// only way to *use* two accounts of the same vendor without logging in and
/// out. So a home is what an account is, and everything Sissy reads about that
/// account is resolved from it rather than configured beside it. That is what
/// makes a row pairing one account's identity with another's limits
/// unrepresentable, which is the bug this type exists to remove.
struct AccountConfig: Sendable, Codable, Equatable {
    /// Key within the vendor, and the suffix on this account's own snapshot.
    /// Empty for the account that predates accounts.
    var id: String
    /// Which CLI this is an account of.
    var vendor: String
    /// What the user calls it. Nil until they say, and then the panel prefers
    /// it over the organisation the vendor's own files name.
    var label: String?
    /// The config home: `CLAUDE_CONFIG_DIR` / `CODEX_HOME` for this account.
    /// Tilde-prefixed paths expand against `$HOME`.
    var home: String
}

/// Where one account's files are, resolved.
///
/// Every path here comes from the same `home`, which is the invariant the
/// whole design rests on. A caller takes the paths it needs and cannot
/// assemble a reading out of two accounts even by mistake.
struct ResolvedAccount: Sendable, Equatable {
    let key: ProviderKey
    /// The user's own name for it, when they gave one.
    let label: String?
    /// Config home this account's CLI was pointed at.
    let home: URL
    /// Root of the session-log tree the tail reads.
    let dataDir: URL

    var id: String { key.id }

    /// Claude Code's config file for this account.
    ///
    /// The odd case is the default home, and it is the CLI's own: with
    /// `CLAUDE_CONFIG_DIR` unset the config home is `~/.claude` but
    /// `.claude.json` sits beside it at `$HOME/.claude.json`, while a home the
    /// variable names holds its own copy. Measured against 2.1.272, which
    /// creates `<home>/.claude.json` on first run under a home it was given.
    var claudeProfileURL: URL {
        home == AccountDefaults.claudeHome
            ? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
                AccountDefaults.claudeProfileName)
            : home.appendingPathComponent(AccountDefaults.claudeProfileName)
    }

    /// Claude Code's own OAuth credential for this account, which is the only
    /// per-account source for the live usage endpoint: the login keychain
    /// holds one item for the whole machine, and a claude.ai cookie belongs to
    /// whichever account Claude.app happens to be signed into.
    var claudeCredentialsURL: URL {
        home.appendingPathComponent(AccountDefaults.claudeCredentialsName)
    }

    /// Codex's own credential and plan claim for this account.
    var codexAuthURL: URL {
        home.appendingPathComponent(AccountDefaults.codexAuthName)
    }
}

/// The paths a vendor uses when nobody has said otherwise.
enum AccountDefaults {
    static let claudeConfigDirEnvVar = "CLAUDE_CONFIG_DIR"
    static let codexHomeEnvVar = "CODEX_HOME"
    static let claudeProfileName = ".claude.json"
    static let claudeCredentialsName = ".credentials.json"
    static let codexAuthName = "auth.json"
    static let claudeLogsSubdirectory = "projects"
    static let codexLogsSubdirectory = "sessions"

    /// Claude Code's config home, deferring to the CLI's own environment
    /// variable exactly as `ClaudeProfileSource` already does.
    static var claudeHome: URL {
        let configured = ProcessInfo.processInfo.environment[claudeConfigDirEnvVar]
        if let configured, !configured.isEmpty { return URL(fileURLWithPath: configured) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
    }

    /// Codex's home, deferring to `CODEX_HOME` on the same grounds.
    static var codexHome: URL {
        let configured = ProcessInfo.processInfo.environment[codexHomeEnvVar]
        if let configured, !configured.isEmpty { return URL(fileURLWithPath: configured) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
    }

    /// Log tree of a home, per vendor.
    static func dataDir(vendor: String, home: URL) -> URL {
        switch vendor {
        case ProviderID.codex: return home.appendingPathComponent(codexLogsSubdirectory)
        default: return home.appendingPathComponent(claudeLogsSubdirectory)
        }
    }

    /// The home a log tree belongs to, for the one configuration that names
    /// the tree rather than the home: `claudeDataDir` / `codexDataDir` are
    /// what every install written before accounts carries.
    static func home(ofDataDir dataDir: URL) -> URL {
        dataDir.deletingLastPathComponent()
    }
}
