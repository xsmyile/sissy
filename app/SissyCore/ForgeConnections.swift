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
    /// The bare host, no scheme and no path: `github.com`, `gitlab.example.com`.
    let host: String

    var id: String { "\(kind.rawValue):\(host)" }

    /// The API root every request for this connection hangs off.
    ///
    /// Composed rather than stored: a host is what the user gave and a root is
    /// what this build knows to do with it, so a reader that learns a second
    /// endpoint shape does not have to migrate a file.
    var root: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        return components.url
    }

    static func gitHub(host: String = "github.com") -> Self {
        Self(kind: .gitHub, host: host)
    }

    /// A host out of whatever was typed or pasted.
    ///
    /// Someone copying it out of a browser brings a scheme, a path and a
    /// trailing slash with it, and a connection keyed by
    /// `https://gitlab.example.com/` is one no reader can reach and no row can
    /// be removed by name. Lowercased because a host is case-insensitive and
    /// the id is not.
    static func host(from typed: String) -> String {
        var value = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where value.hasPrefix(scheme) {
            value = String(value.dropFirst(scheme.count))
        }
        if let slash = value.firstIndex(of: "/") {
            value = String(value[value.startIndex..<slash])
        }
        return value
    }
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

    private struct Contents: Codable {
        var connections: [ForgeConnection] = []
    }

    /// Every connection, in a stable order so two reads agree and the panel's
    /// rows do not swap places between polls.
    func load() -> [ForgeConnection] {
        guard let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(Contents.self, from: data)
        else { return [] }
        return decoded.connections.sorted { $0.id < $1.id }
    }

    /// Records a connection, replacing one on the same host. Connecting the
    /// same host again is a re-connection rather than a second row: the token
    /// behind it has just been replaced too.
    func remember(_ connection: ForgeConnection) throws {
        var connections = load().filter { $0.id != connection.id }
        connections.append(connection)
        try save(connections)
    }

    /// Drops one. A connection that was not there is not a failure.
    func forget(id: String) throws {
        let connections = load()
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
    static let keychainService = "com.radonforge.sissy.forge-token"

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
