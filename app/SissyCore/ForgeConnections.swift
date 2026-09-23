import Foundation
import Security

/// One forge Sissy holds a token for.
///
/// Keyed by the kind and the host rather than by the account, because the host
/// is what decides which reader asks and which API root it asks: `github.com`
/// and a GitHub Enterprise are two connections, and so are two self-hosted
/// GitLabs. **Who the token belongs to is deliberately not here** — it is read
/// from the vendor on every poll and lives on `ForgeActivityReading`, because a
/// login recorded once is a claim that survives the token being replaced.
///
/// There is no enabled flag. Adding a connection is the switch and removing it
/// is the off — which is what keeps the module inside the rule that a module
/// which is off must not exist as far as the network is concerned, without
/// asking the user to arm the same thing twice.
struct ForgeConnection: Sendable, Codable, Equatable, Identifiable {
    let kind: ForgeKind
    /// The bare host, no scheme, no port and no path: `github.com`,
    /// `gitlab.example.com`.
    let host: String
    /// The port the instance answers on, nil for the scheme's own. A
    /// self-hosted forge on `8443` is the case it exists for.
    let port: Int?
    /// The path the instance is served under, with a leading slash and no
    /// trailing one, nil for an instance at the root of its host.
    let basePath: String?

    init(kind: ForgeKind, host: String, port: Int? = nil, basePath: String? = nil) {
        self.kind = kind
        self.host = host
        self.port = port
        self.basePath = basePath
    }

    /// The host with its port and path, which is how the connection is named
    /// wherever the user reads it. For a connection with neither it is the
    /// host alone, so a file written before either existed keeps its ids.
    var address: String {
        host + (port.map { ":\($0)" } ?? "") + (basePath ?? "")
    }

    var id: String { "\(kind.rawValue):\(address)" }

    /// Whether this is the vendor's own hosted instance, which is the one
    /// case that answers on an API host of its own.
    var isVendorHosted: Bool {
        host == kind.defaultHost && port == nil && basePath == nil
    }

    /// The API root every request for this connection hangs off.
    ///
    /// Composed rather than stored: a host is what the user gave and a root is
    /// what this build knows to do with it, so a reader that learns a second
    /// endpoint shape does not have to migrate a file.
    var root: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = host
        components.port = port
        components.path = basePath ?? ""
        return components.url
    }

    static func gitHub(host: String = GitHubActivityFeed.dotComHost) -> Self {
        Self(kind: .gitHub, host: host)
    }

    static let scheme = "https"
    private static let insecureScheme = "http"
    private static let knownSchemes = [scheme, insecureScheme]
    private static let schemeSeparator = "://"
    private static let validPorts = 1...65_535
    private static let maximumHostLength = 253
    private static let maximumLabelLength = 63
    private static let hostCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
    private static let pathCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    /// A connection out of whatever was typed or pasted into the two fields,
    /// or the reason it cannot be one.
    ///
    /// Someone copying a host out of a browser brings a scheme, a path and a
    /// trailing slash with it, and those are taken off: the path of a page the
    /// user was looking at is not where the API lives, so a sub-path install
    /// is named in a field of its own. What is **refused** rather than
    /// guessed at is anything that cannot reach the API or would send the
    /// token somewhere the user did not name: a `user@` prefix, a query, a
    /// fragment, any scheme but `https`, and a port out of range. `http` is
    /// refused with a reason of its own rather than quietly upgraded: the root
    /// is always `https`, so a plain-http instance used to be probed on the
    /// wrong scheme and reported as unreachable, and a token is not sent in
    /// the clear to find out. Each used to be accepted, filed with its token, and then read as
    /// "answered something Sissy could not read" on every poll without a
    /// request ever being made. Lowercased because a host is case-insensitive
    /// and the id is not; the path keeps its case, because a path does not.
    static func parse(kind: ForgeKind, host typed: String, path typedPath: String = "")
        -> Result<Self, ForgeAddressProblem>
    {
        var value = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return .failure(.empty) }
        if let separator = value.range(of: schemeSeparator) {
            let scheme = String(value[value.startIndex..<separator.lowerBound])
            if scheme == insecureScheme { return .failure(.insecureScheme) }
            guard scheme == Self.scheme else { return .failure(.scheme) }
            value = String(value[separator.upperBound...])
        }
        if value.contains("?") { return .failure(.query) }
        if value.contains("#") { return .failure(.fragment) }
        let authority = value.prefix { $0 != "/" }
        if authority.contains("@") { return .failure(.credentials) }
        let bare = String(authority.hasSuffix(":") ? authority.dropLast() : authority)
        if knownSchemes.contains(bare) || value.contains(schemeSeparator) {
            return .failure(.scheme)
        }
        var host = String(authority)
        var port: Int?
        if let colon = authority.lastIndex(of: ":") {
            host = String(authority[authority.startIndex..<colon])
            let digits = authority[authority.index(after: colon)...]
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                let number = Int(digits), validPorts.contains(number)
            else { return .failure(.port) }
            port = number == defaultPort ? nil : number
        }
        guard isHostName(host) else { return .failure(host.isEmpty ? .empty : .host) }
        return basePath(from: typedPath).map { path in
            Self(kind: kind, host: host, port: port, basePath: path)
        }
    }

    /// The port `https` answers on when none is named, which is the same
    /// connection as naming none and must not become a second id for it.
    private static let defaultPort = 443

    private static func isHostName(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= maximumHostLength else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= maximumLabelLength
                && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.unicodeScalars.allSatisfy(hostCharacters.contains)
        }
    }

    /// The sub-path an instance is served under, nil for none. Slashes either
    /// side are the user's to leave off or put on, and a segment that could
    /// climb out of the path or smuggle a query in is refused.
    private static func basePath(from typed: String) -> Result<String?, ForgeAddressProblem> {
        let value = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains("?") { return .failure(.query) }
        if value.contains("#") { return .failure(.fragment) }
        let segments = value.split(separator: "/")
        guard !segments.isEmpty else { return .success(nil) }
        let valid = segments.allSatisfy { segment in
            segment != "." && segment != ".."
                && segment.unicodeScalars.allSatisfy(pathCharacters.contains)
        }
        guard valid else { return .failure(.path) }
        return .success("/" + segments.joined(separator: "/"))
    }
}

/// Why what was typed cannot name a forge, one case per thing the user would
/// change. Worded by `ForgeConnectCopy.addressProblem`.
enum ForgeAddressProblem: Error, Sendable, Equatable, CaseIterable {
    /// Nothing was typed.
    case empty
    /// A scheme other than `https`, or one typed wrong.
    case scheme
    /// `http`, which would send the token in the clear.
    case insecureScheme
    /// A `user@` or `user:password@` in front of the host.
    case credentials
    /// A `?` and whatever follows it.
    case query
    /// A `#` and whatever follows it.
    case fragment
    /// A port that is not a number from 1 to 65535.
    case port
    /// A host with characters no host name can carry.
    case host
    /// A base path with characters a path segment cannot carry.
    case path
}

/// The connections, in a file of Sissy's own beside the tokens they describe.
///
/// Its own file rather than a corner of `server.json` for the reason
/// `CodexAccountIndex` is: it is written from a Settings control while the
/// engine is running, and a config the engine also rewrites would race it.
///
/// It holds no secret, so a build whose keychain grant has lapsed can still
/// list what is connected — which is what lets a row say "not read" under the
/// host it belongs to instead of vanishing.
struct ForgeConnectionIndex: Sendable {
    let url: URL

    static let fileName = "forge-connections.json"

    static func defaultURL(in parent: URL) -> URL {
        parent.appendingPathComponent(fileName)
    }

    /// What an index that would not read is renamed to, with a timestamp
    /// after it so a second one never replaces the first.
    static let setAsidePrefix = "forge-connections.unreadable-"

    private struct Contents: Codable {
        var connections: [ForgeConnection] = []
    }

    /// Why the index would not answer. `reason` is the error's domain and
    /// code and never the file's bytes.
    enum LoadError: Error, Equatable {
        /// The file is there and the read itself failed, which says nothing
        /// about what is in it.
        case unreadable(reason: String)
        /// The file read and does not decode, which is the one case its
        /// contents are known to be bad.
        case undecodable(reason: String)
    }

    /// Every connection, in a stable order so two reads agree and the panel's
    /// rows do not swap places between polls. Empty when there is no file yet.
    ///
    /// Throws for a file that is there and will not read, which used to come
    /// back as an empty list: every connection left Settings and the panel,
    /// and the next `remember` wrote over the file with the one new host, so
    /// the tokens behind the rest stayed in the keychain with nothing to name
    /// them. Every write here follows a load that succeeded, so a file this
    /// refuses is never overwritten. An empty file is refused too: `save`
    /// writes atomically and never leaves one. The rule
    /// `ClaudeAccountStore.loadIndex` is on, for the same reason.
    func load() throws -> [ForgeConnection] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            throw LoadError.unreadable(reason: Self.reason(error))
        }
        do {
            return try JSONDecoder().decode(Contents.self, from: data).connections
                .sorted { $0.id < $1.id }
        } catch {
            throw LoadError.undecodable(reason: "\(data.count) bytes, \(Self.reason(error))")
        }
    }

    /// Every connection, with an index that does not decode moved out of the
    /// way first.
    ///
    /// Moved rather than deleted: it is the only list of which tokens belong
    /// to which host, and a person can still read it. Once it is aside the
    /// tokens it named surface in Settings as tokens without a connection, and
    /// a new connection starts a fresh file instead of writing over the old
    /// one. **Only a file that read and did not decode is moved**: one whose
    /// read failed may be a sound index behind a lock or a permission, and
    /// moving it would offer every token it names for removal. That, and a
    /// file that could not be moved, throw, which is the answer under which
    /// nothing may be written.
    func loadSettingAside(now: Date = Date()) throws -> [ForgeConnection] {
        do {
            return try load()
        } catch let unreadable as LoadError {
            guard case .undecodable = unreadable else { throw unreadable }
            let aside = url.deletingLastPathComponent()
                .appendingPathComponent("\(Self.setAsidePrefix)\(Int(now.timeIntervalSince1970)).json")
            do {
                try FileManager.default.moveItem(at: url, to: aside)
            } catch {
                sissyLog(
                    "sissy: the forge connection index would not decode (\(unreadable)) and could "
                        + "not be moved (\(Self.reason(error)))")
                throw unreadable
            }
            sissyLog(
                "sissy: the forge connection index would not decode (\(unreadable)); kept it as "
                    + aside.lastPathComponent)
            return []
        }
    }

    /// Whether an index has ever been set aside beside this one. Read off the
    /// directory rather than remembered, so Settings keeps saying so across a
    /// relaunch until the file is dealt with.
    func hasSetAside() -> Bool {
        let parent = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        return names.contains { $0.hasPrefix(Self.setAsidePrefix) }
    }

    /// The connections a token is filed under that the index does not name,
    /// which is what an interrupted connect or disconnect, or an index set
    /// aside, leaves behind. Pure, so the reconciliation can be held without a
    /// keychain.
    static func orphans(stored: [String], connected: [ForgeConnection]) -> [String] {
        let named = Set(connected.map(\.id))
        return stored.filter { !named.contains($0) }.sorted()
    }

    /// Records a connection, replacing one on the same host. Connecting the
    /// same host again is a re-connection rather than a second row: the token
    /// behind it has just been replaced too.
    func remember(_ connection: ForgeConnection) throws {
        var connections = try load().filter { $0.id != connection.id }
        connections.append(connection)
        try save(connections)
    }

    /// Drops one. A connection that was not there is not a failure.
    func forget(id: String) throws {
        let connections = try load()
        let kept = connections.filter { $0.id != id }
        guard kept.count != connections.count else { return }
        try save(kept)
    }

    private func save(_ connections: [ForgeConnection]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let contents = Contents(connections: connections.sorted { $0.id < $1.id })
        try encoder.encode(contents).write(to: url, options: .atomic)
    }

    private static func reason(_ error: Error) -> String {
        let bridged = error as NSError
        return "\(bridged.domain) \(bridged.code)"
    }
}

/// What the Forge tab lists, read in one pass so a token is never called an
/// orphan against a different reading of the index than the list beside it.
struct ForgeIndexState: Sendable, Equatable {
    var connections: [ForgeConnection] = []
    /// Tokens filed under a connection the index does not name. Empty while
    /// the index cannot be read, since nothing can be told apart from it.
    var orphanedTokens: [String] = []
    /// An index that did not decode has been set aside beside this one.
    var setAside = false
    /// The index is there and would not be read, so nothing is listed and
    /// nothing may be written until it can.
    var unreadable = false
}

/// The index held against the tokens filed for it.
///
/// It is what gives a token nothing names a way out of the keychain: an
/// interrupted connect or disconnect, or an index set aside, leaves one, and
/// before this was listed no surface said the keychain still held it. The
/// token effects are closures so the rules can be held without a keychain.
struct ForgeTokenReconciler: Sendable {
    let index: ForgeConnectionIndex
    let storedTokens: @Sendable () -> [String]
    let deleteToken: @Sendable (String) throws -> Void

    /// One load of the index, setting aside one that does not decode, and one
    /// listing of the tokens against it.
    func state() -> ForgeIndexState {
        let connections: [ForgeConnection]
        do {
            connections = try index.loadSettingAside()
        } catch {
            return ForgeIndexState(setAside: index.hasSetAside(), unreadable: true)
        }
        return ForgeIndexState(
            connections: connections,
            orphanedTokens: ForgeConnectionIndex.orphans(stored: storedTokens(), connected: connections),
            setAside: index.hasSetAside())
    }

    /// Deletes a token no connection names, answering whether it did.
    ///
    /// Re-read rather than taken from the list the user clicked in: one the
    /// index has come to name since is left alone, because removing it is a
    /// disconnect, and so is every token while the index cannot be read.
    /// `sparing` names the connects in flight, whose token is saved before
    /// their connection is recorded and reads as an orphan in between.
    func removeOrphan(id: String, sparing inFlight: Set<String> = []) throws -> Bool {
        guard !inFlight.contains(id), state().orphanedTokens.contains(id) else { return false }
        try deleteToken(id)
        return true
    }
}

/// Files a forge connection, but only for a token the forge accepts.
///
/// **The token is read with before it is kept.** A connect used to file
/// whatever it was handed and dismiss the sheet as if it had worked, so a typo
/// in a host sent a token, often a write-scoped one, to whatever answered at
/// that name on every poll, and a refused token was only discovered on the row
/// afterwards. The probe asks the forge who the token belongs to, which is one
/// small request and the same question every poll starts with, and nothing is
/// written unless it answers.
///
/// The effects are closures so the order can be held without a keychain or a
/// network: the index, then the probe, then the token, then the index again,
/// and a token whose index write failed is taken back out rather than left for
/// nothing to name.
struct ForgeConnector: Sendable {
    /// The connections the index names now, which says whether this connect
    /// replaces one. Throws for an index that will not read.
    let recorded: @Sendable () throws -> [ForgeConnection]
    let probe: @Sendable (ForgeConnection, String) async throws -> String
    let saveToken: @Sendable (String, String) throws -> Void
    let deleteToken: @Sendable (String) throws -> Void
    let remember: @Sendable (ForgeConnection) throws -> Void

    /// What an attempt came to.
    enum Outcome: Sendable, Equatable {
        /// Filed, and the forge answered as this login.
        case connected(login: String)
        /// The forge did not accept the token or could not be asked, so
        /// nothing was written.
        case refused(ForgeReadFailure)
        /// The forge answered and a local write failed, so nothing is
        /// connected.
        case notFiled
        /// The index would not read, so nothing was asked or written.
        case indexUnreadable
    }

    /// Probes, then files. A connection the index already names is a
    /// replacement: a failed index write then leaves the new token in place,
    /// because deleting it would leave that row with no token at all. An
    /// index that will not read cannot say which this is, so nothing is
    /// probed and nothing written.
    func connect(_ connection: ForgeConnection, token: String) async -> Outcome {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notFiled }
        let replacing: Bool
        do {
            replacing = try recorded().contains { $0.id == connection.id }
        } catch {
            sissyLog("sissy: did not connect \(connection.id), the forge connection index would not read")
            return .indexUnreadable
        }
        let login: String
        do {
            login = try await probe(connection, trimmed)
        } catch {
            return .refused(error as? ForgeReadFailure ?? .unreachable)
        }
        do {
            try saveToken(trimmed, connection.id)
        } catch {
            sissyLog("sissy: could not file the token for \(connection.id) (\(error))")
            return .notFiled
        }
        do {
            try remember(connection)
        } catch {
            sissyLog("sissy: could not record the forge connection \(connection.id) (\(error))")
            guard !replacing else { return .notFiled }
            do {
                try deleteToken(connection.id)
            } catch {
                sissyLog("sissy: the forge token for \(connection.id) outlived a failed connect (\(error))")
            }
            return .notFiled
        }
        return .connected(login: login)
    }
}

/// A forge token, in a keychain item Sissy owns.
///
/// Sissy's own item rather than a reference to the CLI's, for the reason
/// `CodexAccountStore`'s exists: an item this process created is on its own ACL
/// and reads with no dialog, and a token copied in once cannot be rewritten
/// under Sissy by a CLI that refreshes it. Sissy never writes back to `gh`'s or
/// `glab`'s own storage and never renews a forge token — a forge token has no
/// refresh grant to spend, so there is nothing to own on that side.
///
/// The value is the token and nothing else. It is never logged, never put on a
/// frame, and never reaches the diagnostics report or the export; it leaves
/// this type as an `Authorization` or `PRIVATE-TOKEN` header and nowhere else.
enum ForgeTokenStore {
    /// A literal rather than anything derived from a forge id, so renaming a
    /// kind cannot orphan a token the user connected.
    static let keychainService = SissyPaths.keychainService("forge-token")

    /// Files a token under a connection, replacing whatever was there.
    ///
    /// Add-then-update rather than delete-then-add, so a delete that succeeds
    /// followed by an add that fails cannot leave the user with no token and no
    /// way to tell that from a host they never connected.
    static func save(_ token: String, connection id: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            throw ForgeTokenStoreError.empty
        }
        var attributes = identity(connection: id)
        attributes[kSecValueData as String] = data
        let added = SecItemAdd(attributes as CFDictionary, nil)
        if added == errSecSuccess { return }
        guard added == errSecDuplicateItem else { throw ForgeTokenStoreError.keychain(added) }
        let updated = SecItemUpdate(
            identity(connection: id) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        guard updated == errSecSuccess else { throw ForgeTokenStoreError.keychain(updated) }
    }

    /// The token, under the same suppression every scheduled read in this app
    /// takes: silent in the ordinary case, and refusing rather than
    /// interrupting once a re-signing has cost the grant.
    ///
    /// **The outcome travels rather than an optional**, because the two ways
    /// there is no token are different facts and only one of them is the user's
    /// to fix. An item that is not there means nothing was ever connected;
    /// a keychain that would not answer this read means the grant has gone
    /// stale — which happens on every re-signed build — and folding the second
    /// into the first is the mistake `ClaudeCredentialsStore.classify` exists
    /// to prevent: nobody was asked, nobody refused, and a reader that reports
    /// "no token" for it stops polling an account that is perfectly fine.
    static func load(connection id: String, allowingInteraction: Bool = false)
        -> CredentialLookup<String>
    {
        var query = ClaudeCredentialsStore.makeQuery(
            service: keychainService, allowingInteraction: allowingInteraction)
        query[kSecAttrAccount as String] = id
        let result = ClaudeCredentialsStore.copyMatching(
            query, allowingInteraction: allowingInteraction)
        return ClaudeCredentialsStore.classify(
            result.status, data: result.data, allowingInteraction: allowingInteraction,
            decoding: { data in
                guard let token = String(data: data, encoding: .utf8), !token.isEmpty else {
                    return nil
                }
                return token
            })
    }

    /// Forgets one connection's token. An item that was not there is not a
    /// failure: the caller asked for it gone and it is gone.
    static func delete(connection id: String) throws {
        let status = SecItemDelete(identity(connection: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ForgeTokenStoreError.keychain(status)
        }
    }

    /// Every connection a token is filed under.
    ///
    /// Attributes only and never the data, so asking which tokens exist costs
    /// no ACL check and cannot raise a dialog — the same reason
    /// `CodexAccountStore.storedAccounts` is built this way.
    static func storedConnections() -> [String] {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                sissyLog("sissy: could not list the connected forges (OSStatus \(status))")
            }
            return []
        }
        guard let attributes = items as? [[String: Any]] else { return [] }
        return attributes.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
        ]
    }

    /// What the item is, with neither a value nor a read on it. Shared by every
    /// operation so an add, an update and a delete cannot drift into addressing
    /// different items.
    private static func identity(connection id: String) -> [String: Any] {
        var query = baseQuery()
        query[kSecAttrAccount as String] = id
        return query
    }
}

enum ForgeTokenStoreError: Error, Equatable {
    /// A token with nothing in it, or one that named no connection. Its own
    /// case because it is the caller's to fix and names no status code.
    case empty
    case keychain(OSStatus)
}
