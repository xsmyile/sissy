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
    /// Three places in one order, the same one `CodexBar` resolves in
    /// (`ClaudeConfigPaths.accountConfigURL`): the home's own `.config.json`
    /// where the CLI has migrated to it, then `<home>/.claude.json` for a home
    /// `CLAUDE_CONFIG_DIR` names, and `$HOME/.claude.json` for the default
    /// home — where the CLI keeps the profile *beside* the config directory
    /// rather than inside it. Measured against 2.1.272, which creates
    /// `<home>/.claude.json` on first run under a home it was given.
    var claudeProfileURL: URL {
        let profile = home.appendingPathComponent(AccountDefaults.claudeProfileName)
        if FileManager.default.fileExists(atPath: profile.path) { return profile }
        guard home == AccountDefaults.claudeHome else {
            return home.appendingPathComponent(AccountDefaults.claudeLegacyProfileName)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(AccountDefaults.claudeLegacyProfileName)
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
    /// Newer layout: a config home the CLI has migrated keeps its profile
    /// here, and it wins where both exist. Same order `CodexBar` resolves in
    /// (`ClaudeConfigPaths.accountConfigURL`), so the two tools cannot read
    /// one machine differently.
    static let claudeProfileName = ".config.json"
    static let claudeLegacyProfileName = ".claude.json"
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

extension ServerConfig {
    /// This config with one more account of `vendor`.
    ///
    /// A vendor with no entry in the list is not a vendor with no account: it
    /// is one whose single account is implied by `claudeDataDir` /
    /// `codexDataDir`. So the first addition writes that implied account down
    /// before appending the new one — otherwise adding a second account would
    /// silently replace the first, taking its snapshot and its archive out of
    /// the reading with it.
    func addingAccount(vendor: String, home: URL, label: String?) -> ServerConfig {
        var updated = self
        var list = accounts ?? []
        if !list.contains(where: { $0.vendor == vendor }) {
            let implied = resolvedAccounts(vendor: vendor)
            list += implied.map {
                AccountConfig(
                    id: $0.key.account ?? "", vendor: vendor, label: $0.label,
                    home: $0.home.path)
            }
        }
        let taken = Set(list.filter { $0.vendor == vendor }.map(\.id))
        list.append(
            AccountConfig(
                id: Self.accountID(label: label, home: home, taken: taken),
                vendor: vendor,
                label: label,
                home: home.path
            ))
        updated.accounts = list
        return updated
    }

    /// This config without that account.
    ///
    /// Its snapshot and its recorded days are deliberately left on disk: the
    /// days it counted happened, and the archive is the one thing Sissy keeps
    /// — removing an account is saying "stop reading this", not "forget what
    /// was read". Settings' delete button is where the data goes.
    func removingAccount(id: String, vendor: String) -> ServerConfig {
        var updated = self
        updated.accounts = (accounts ?? []).filter { !($0.vendor == vendor && $0.id == id) }
        return updated
    }

    /// A key for a new account: readable, stable, and unique within its
    /// vendor, because it names that account's snapshot file and its directory
    /// in the archive.
    private static func accountID(label: String?, home: URL, taken: Set<String>) -> String {
        let named = label.flatMap { $0.isEmpty ? nil : $0 }
        let source = named ?? home.lastPathComponent
        let slug = source.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        var candidate = String(String(slug).split(separator: "-").joined(separator: "-").prefix(32))
        if candidate.isEmpty { candidate = "account" }
        guard taken.contains(candidate) else { return candidate }
        var suffix = 2
        while taken.contains("\(candidate)-\(suffix)") { suffix += 1 }
        return "\(candidate)-\(suffix)"
    }
}
