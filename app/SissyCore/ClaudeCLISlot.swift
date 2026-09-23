import Foundation

/// The parts of a Claude Code credential blob Sissy reads, merges and keeps.
///
/// The blob is not only the account. Measured 2026-09-23 on a Mac with plugin
/// MCP servers signed in, `~/.claude/.credentials.json` carried two top-level
/// keys, `claudeAiOauth` and `mcpOAuth`, and the keychain items carry the same
/// shape. Only `claudeAiOauth` is the account: it is what gets archived, what
/// a switch puts back, and what decides whether a slot holds a credential at
/// all. Every other key belongs to the CLI as it is now and is carried over
/// untouched, because a switch that wrote a whole archived blob rolled every
/// MCP login back to the day that blob was filed.
enum ClaudeCredentialBlob {
    static let oauthKey = "claudeAiOauth"
    private static let tokenKey = "accessToken"
    private static let expiryKey = "expiresAt"
    private static let refreshExpiryKey = "refreshTokenExpiresAt"

    /// The top-level JSON object, or nil for bytes that are not one.
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The account half, or nil when the blob holds no usable one. Usable
    /// means an access token that is not empty: the one field every reader of
    /// the blob needs, and the same test for every place it can be kept.
    static func oauth(in data: Data) -> [String: Any]? {
        guard let oauth = object(data)?[oauthKey] as? [String: Any],
            let token = oauth[tokenKey] as? String, !token.isEmpty
        else { return nil }
        return oauth
    }

    /// The access token and its expiry, which is what the limits probe spends
    /// and what the registry identifies. One parse for both, so the two can
    /// never disagree about whether a blob holds a credential.
    static func credentials(in data: Data) -> ClaudeCredentials? {
        guard let oauth = oauth(in: data), let token = oauth[tokenKey] as? String else {
            return nil
        }
        return ClaudeCredentials(accessToken: token, expiresAt: date(oauth[expiryKey]))
    }

    /// When the refresh token dies, where the CLI records it.
    ///
    /// An access token that has expired is the ordinary state of an archive:
    /// the CLI renews it with the refresh token the moment it runs. A refresh
    /// token that has expired is not, because nothing can renew it and the
    /// CLI answers a switch to it with a request for `/login`.
    static func refreshExpiresAt(in data: Data) -> Date? {
        guard let oauth = oauth(in: data) else { return nil }
        if let text = oauth[refreshExpiryKey] as? String {
            return ISO8601DateFormatter().date(from: text)
        }
        return date(oauth[refreshExpiryKey])
    }

    /// Whether an archived credential can still sign the CLI in.
    static func refreshHasExpired(_ data: Data, now: Date) -> Bool {
        guard let expiry = refreshExpiresAt(in: data) else { return false }
        return expiry <= now
    }

    /// The account half alone, as a blob of its own: what the archive keeps.
    static func accountOnly(_ data: Data) -> Data? {
        guard let oauth = oauth(in: data) else { return nil }
        return serialize([oauthKey: oauth])
    }

    /// Whether two blobs name the same credential, whatever else they carry.
    static func sameAccountCredential(_ lhs: Data, _ rhs: Data) -> Bool {
        guard let left = oauth(in: lhs), let right = oauth(in: rhs) else { return false }
        return NSDictionary(dictionary: left).isEqual(to: right)
    }

    /// The account half of `account` written into `current`, every other key
    /// of `current` kept as it is. Nil `current` is a slot with nothing in it,
    /// which takes the account half alone.
    static func merging(account: Data, into current: Data?) -> Data? {
        guard let oauth = oauth(in: account) else { return nil }
        var root: [String: Any] = [:]
        if let current {
            guard let existing = object(current) else { return nil }
            root = existing
        }
        root[oauthKey] = oauth
        return serialize(root)
    }

    private static func serialize(_ root: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Claude Code writes its dates in milliseconds. The bound is the one
    /// `ClaudeCredentialsStore` applies, so no two readers of one field can
    /// disagree about its unit.
    private static func date(_ raw: Any?) -> Date? {
        guard let seconds = (raw as? Double) ?? (raw as? NSNumber)?.doubleValue else { return nil }
        let scaled = seconds > ClaudeCredentialsStore.secondsUpperBound ? seconds / 1000 : seconds
        return Date(timeIntervalSince1970: scaled)
    }
}

/// Every place Claude Code keeps one config home's credential, and the one of
/// them the CLI is actually using.
///
/// One type for both readers of that credential, the account registry and the
/// limits probe, because they used to read it in two different orders and
/// that is how a row came to carry one account's name over another's limits.
/// Measured 2026-09-23 against Claude Code 2.1.280: after a `claude /login`
/// as a second account, the unscoped `Claude Code-credentials` item held the
/// new account while `Claude Code-credentials-8a380954` (the scoped name for
/// `~/.claude`) and `~/.claude/.credentials.json` both kept the previous one.
/// The registry, reading the keychain, named the new account; the probe,
/// reading the file first, fetched the old account's windows and credits and
/// put them under that name.
///
/// So the order is the CLI's own on macOS: the keychain first, and the file
/// only when no keychain item holds a credential. Within the keychain the
/// name `ClaudeKeychainCLI.claudeService(for:)` gives leads, and for the
/// default home that is the unscoped item — the one that 2.1.280's `/login`
/// wrote at 09:20:38Z while leaving the scoped one alone, and the one the CLI
/// went on running as. The scoped name is read only when the unscoped one
/// holds nothing. A blob that carries no usable `claudeAiOauth` counts as
/// holding nothing, wherever it sits: a file left with only `mcpOAuth` in it
/// used to stop the lookup at an unreadable file with the live keychain item
/// behind it.
///
/// A place that cannot be read is not a place that is empty, so a failed
/// lookup throws rather than falling through: reading past it would answer
/// for a credential the CLI may not be using, and a switch would overwrite a
/// name it never saw.
struct ClaudeCLISlot: Sendable {
    /// One place the credential can be kept.
    enum Name: Hashable, Sendable {
        case keychain(String)
        case file
    }

    /// Every name, in the order the CLI reads them. Computed on each call,
    /// because the service name depends on whether the home is the default
    /// one, and a comparison made once at launch went on answering for a
    /// directory that did not exist yet.
    var names: @Sendable () -> [Name]
    /// The bytes at one name, nil where there are none.
    var read: @Sendable (Name) throws -> Data?
    var write: @Sendable (Name, Data) throws -> Void
    /// Takes away what a failed switch created where there had been nothing.
    var remove: @Sendable (Name) throws -> Void

    /// Reads and writes nothing. What a test gets unless it asks for the real
    /// keychain, so a suite can never read the machine's own credential.
    static let inert = Self(
        names: { [] }, read: { _ in nil }, write: { _, _ in }, remove: { _ in })

    /// The name the CLI is reading its credential from, and those bytes, or
    /// nil when no name holds one.
    func current() throws -> (name: Name, data: Data)? {
        for name in names() {
            guard let data = try read(name), ClaudeCredentialBlob.oauth(in: data) != nil else {
                continue
            }
            return (name, data)
        }
        return nil
    }

    /// The slots of the config home Sissy meters.
    ///
    /// Taken from the resolved home rather than assumed to be the default
    /// one: a `claudeDataDir` pointed elsewhere is metered from that home, and
    /// its credential is filed under that home's own service name.
    static func live(home: ProviderHome) -> Self {
        let mirror = home.claudeCredentialsURL
        let directory = home.home
        return Self(
            names: {
                let primary = ClaudeKeychainCLI.claudeService(for: directory)
                let siblings = ClaudeKeychainCLI.siblingClaudeServices(for: directory)
                return ([primary] + siblings).map(Name.keychain) + [.file]
            },
            read: { name in
                switch name {
                case .keychain(let service):
                    do {
                        return try ClaudeKeychainCLI.read(
                            service: service, account: ClaudeKeychainCLI.claudeLoginName())
                    } catch ClaudeKeychainCLI.Failure.noItem {
                        return nil
                    }
                case .file:
                    guard FileManager.default.fileExists(atPath: mirror.path) else { return nil }
                    return try Data(contentsOf: mirror)
                }
            },
            write: { name, data in
                switch name {
                case .keychain(let service):
                    try ClaudeKeychainCLI.write(
                        data, service: service, account: ClaudeKeychainCLI.claudeLoginName())
                case .file:
                    try data.write(to: mirror, options: .atomic)
                }
            },
            remove: { name in
                switch name {
                case .keychain(let service):
                    try ClaudeKeychainCLI.delete(
                        service: service, account: ClaudeKeychainCLI.claudeLoginName())
                case .file:
                    try FileManager.default.removeItem(at: mirror)
                }
            })
    }
}

/// Claude Code's credential for the home Sissy reads, as the limits probe
/// spends it.
///
/// Read through `ClaudeCLISlot.current()`, the same lookup the account
/// registry identifies, so the limits and credits on a row come off the bytes
/// the name on it was resolved from. Sissy never refreshes this token and
/// never writes it here: Anthropic's refresh tokens rotate on use, so spending
/// one would sign the user out of their own terminal.
enum ClaudeCodeCredentials {
    static func load(slot: ClaudeCLISlot) -> ClaudeCredentialsLookup {
        do {
            guard let found = try slot.current() else { return .absent }
            guard let parsed = ClaudeCredentialBlob.credentials(in: found.data) else {
                return .unreadable(OSStatus(errSecDecode))
            }
            return .found(parsed)
        } catch ClaudeKeychainCLI.Failure.tool(let status) {
            return .unreadable(OSStatus(status))
        } catch {
            return .unreadable(OSStatus(errSecIO))
        }
    }
}
