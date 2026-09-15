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

    /// The home a vendor uses when nobody has said otherwise.
    static func home(vendor: String) -> URL {
        vendor == ProviderID.codex ? codexHome : claudeHome
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
    /// Every account Sissy meters for one vendor, resolved to the paths each
    /// is read from.
    ///
    /// Found, not configured. A second account is a second config home and a
    /// home is something `AccountDiscovery` can look for, so there is nothing
    /// to add and nothing to keep in step — which is the whole point: the
    /// common case is one home, and it must not carry a control it never
    /// needs. Two things still outrank the scan, in order: an `accounts` list
    /// someone wrote into `server.json` by hand, and a `claudeDataDir` /
    /// `codexDataDir` pointed somewhere other than the default, because a user
    /// who named a tree meant that tree.
    func resolvedAccounts(vendor: String) -> [ResolvedAccount] {
        let configured = (accounts ?? []).filter { $0.vendor == vendor }
        if !configured.isEmpty {
            return configured.map { account in
                let home = Self.expandTilde(account.home)
                return ResolvedAccount(
                    key: ProviderKey(vendor: vendor, account: account.id),
                    label: account.label,
                    home: home,
                    dataDir: AccountDefaults.dataDir(vendor: vendor, home: home)
                )
            }
        }
        let legacy = legacyAccount(vendor: vendor)
        guard legacy.home == AccountDefaults.home(vendor: vendor) else { return [legacy] }
        let homes = AccountDiscovery.homes(vendor: vendor)
        guard !homes.isEmpty else { return [legacy] }
        return homes.map { home in
            let isDefault = home == AccountDefaults.home(vendor: vendor)
            return ResolvedAccount(
                key: ProviderKey(
                    vendor: vendor,
                    account: isDefault ? nil : AccountDiscovery.key(vendor: vendor, home: home)),
                label: nil,
                home: home,
                dataDir: AccountDefaults.dataDir(vendor: vendor, home: home)
            )
        }
    }

    /// The account every install had before there was more than one.
    ///
    /// Its key carries no account, which is what keeps `usage-state.json` and
    /// the archive directory it has been writing since 0.1.0 exactly where
    /// they are. The home comes from the configured log tree rather than from
    /// the environment, because a user who pointed `claudeDataDir` somewhere
    /// else meant it.
    private func legacyAccount(vendor: String) -> ResolvedAccount {
        let dataDir = vendor == ProviderID.codex ? resolvedCodexDataDir : resolvedClaudeDataDir
        return ResolvedAccount(
            key: ProviderKey(vendor: vendor),
            label: nil,
            home: AccountDefaults.home(ofDataDir: dataDir),
            dataDir: dataDir
        )
    }
}

/// The accounts on this Mac, found rather than configured.
///
/// Both CLIs keep an account's whole state under one directory, so a second
/// account is a second directory — and a directory is something Sissy can
/// look for. Asking the user to point at one was the wrong shape twice over:
/// it put a folder picker in front of a question about accounts, and it made
/// the overwhelmingly common case — one account, one directory — carry a
/// control it never needs.
///
/// The scan is the home directory's own entries, one level, no recursion. A
/// candidate counts only when it holds something a CLI wrote: a profile
/// naming an account, or a log tree. That is what keeps a stray backup
/// directory from becoming a row nobody can explain.
enum AccountDiscovery {
    /// Prefix of the directories each vendor keeps its homes under. Claude
    /// Code's default is `~/.claude` and a second home is conventionally
    /// `~/.claude-<name>`; Codex's is `~/.codex`.
    private static func prefix(vendor: String) -> String {
        vendor == ProviderID.codex ? ".codex" : ".claude"
    }

    /// Every config home of `vendor` on this Mac, the default one first and
    /// the rest in the order the filesystem lists them — which is stable, so a
    /// row does not move between launches.
    static func homes(vendor: String, in parent: URL? = nil) -> [URL] {
        let root = parent ?? URL(fileURLWithPath: NSHomeDirectory())
        let defaultHome = defaultHome(vendor: vendor, in: root)
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let found =
            entries
            .filter { $0.lastPathComponent.hasPrefix(prefix(vendor: vendor)) }
            .filter { $0 != defaultHome }
            .filter { holdsAnAccount(vendor: vendor, home: $0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard holdsAnAccount(vendor: vendor, home: defaultHome) else { return found }
        return [defaultHome] + found
    }

    /// The home the vendor uses when nobody has said otherwise, relative to
    /// the directory being scanned.
    ///
    /// Parent-relative rather than absolute so the scan answers for the tree
    /// it was given and nothing else — an absolute default leaks the real
    /// `~/.claude` into every scan of anywhere else, which is what a test of
    /// this caught before a user could.
    private static func defaultHome(vendor: String, in root: URL) -> URL {
        guard root.standardizedFileURL.path == NSHomeDirectory() else {
            return root.appendingPathComponent(prefix(vendor: vendor))
        }
        return AccountDefaults.home(vendor: vendor)
    }

    /// Whether a directory is a config home a CLI has actually used.
    ///
    /// A log tree or a profile naming an account, either one. Both tests are
    /// needed: a home signed in this morning has no logs yet, and a home whose
    /// profile a build cannot parse still has the days it recorded.
    static func holdsAnAccount(vendor: String, home: URL) -> Bool {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: home.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return false }
        if manager.fileExists(atPath: AccountDefaults.dataDir(vendor: vendor, home: home).path) {
            return true
        }
        return namesAnAccount(vendor: vendor, home: home)
    }

    private static func namesAnAccount(vendor: String, home: URL) -> Bool {
        let account = ResolvedAccount(
            key: ProviderKey(vendor: vendor), label: nil, home: home,
            dataDir: AccountDefaults.dataDir(vendor: vendor, home: home))
        guard vendor != ProviderID.codex else {
            return FileManager.default.fileExists(atPath: account.codexAuthURL.path)
        }
        guard let data = try? Data(contentsOf: account.claudeProfileURL) else { return false }
        return ClaudeProfileSource.read(data) == .absent ? false : true
    }

    /// A key for a home, derived from its directory name so it is stable
    /// across launches without anything being written down: the key names the
    /// snapshot file and the archive directory, and a key that moved would
    /// strand both.
    static func key(vendor: String, home: URL) -> String? {
        let name = home.lastPathComponent
        let marker = prefix(vendor: vendor) + "-"
        let stripped =
            name.hasPrefix(marker) ? String(name.dropFirst(marker.count)) : name
        let slug = String(
            stripped.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(32))
        return slug.isEmpty ? nil : slug
    }
}
