import Foundation
import Security

/// The claude.ai session Sissy imported, in a keychain item Sissy owns.
///
/// Reading Claude Code's own item is not a permission anyone grants once. The
/// CLI rewrites that item on every token refresh and its ACL goes with it, so
/// an Allow lasts a token cycle — measured 2026-09-13, three rewrites of an
/// item created in April, 73 and 26 minutes apart, with no Sissy build in
/// between. A user watching their limits therefore meets a system dialog on
/// the order of hourly, and a permission asked for hourly is not one that was
/// granted.
///
/// The session comes from Claude.app's own cookie store, which is read exactly
/// once — on the click that switches this source on — and never again. What
/// every poll afterwards reads is this item, which Sissy created, Sissy is on
/// the ACL of, and nothing but Sissy ever rewrites. That moves the ceiling
/// from a token cycle to a re-signing. Sissy never logs in, never refreshes
/// and never revokes a session; the only write on this path is an import the
/// user asked for.
///
/// The value is a whole claude.ai session rather than a read-only usage token.
/// It is never logged, never put on the frame, and never reaches the
/// diagnostics report or the export — it leaves this type only as a `Cookie`
/// header, and only to claude.ai.
enum ClaudeWebSessionStore {
    /// Service the item is filed under. A literal rather than a provider id:
    /// renaming a provider must not orphan a credential the user imported.
    static let keychainService = "com.radonforge.sissy.claude-web"
    /// Which session, for an install that holds more than one. One account
    /// today; the parameter is what stops #130 from having to rewrite this.
    static let defaultAccount = "claude-web"

    /// Prefix claude.ai's session cookie carries, kept so a paste can be
    /// recognised as a session before it is spent on a request.
    static let sessionPrefix = "sk-ant-sid"

    /// Whether a session is filed, asked without decrypting one.
    ///
    /// The query returns attributes and deliberately not data: the keychain
    /// authorizes a *read of the secret*, so asking whether the item exists
    /// costs no ACL check and cannot raise a dialog. That is what lets
    /// Settings say "a session is set" on a re-signed build, where actually
    /// reading it would prompt.
    static func isPresent(account: String = defaultAccount) -> Bool {
        var query = identity(account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// The session, under the same suppression a read of the CLI's item gets.
    ///
    /// Silent in the ordinary case, because Sissy wrote this item. After a
    /// re-signing it is not, and then a scheduled read has to answer
    /// `.interactionRequired` rather than interrupt — the same rule, for the
    /// same reason, as the item next door.
    static func load(
        account: String = defaultAccount,
        allowingInteraction: Bool
    ) -> ClaudeCredentialsLookup {
        var query = ClaudeCredentialsStore.makeQuery(
            service: keychainService, allowingInteraction: allowingInteraction)
        query[kSecAttrAccount as String] = account
        let result = ClaudeCredentialsStore.copyMatching(
            query, allowingInteraction: allowingInteraction)
        return ClaudeCredentialsStore.classify(
            result.status,
            data: result.data,
            allowingInteraction: allowingInteraction,
            decode: decode
        )
    }

    /// Files `session`, replacing whatever was there.
    ///
    /// Add-then-update rather than delete-then-add: a delete that succeeds
    /// followed by an add that fails would leave the user with no session and
    /// no way to tell that from one they never imported.
    static func save(_ session: String, account: String = defaultAccount) throws {
        let normalized = normalize(session)
        guard !normalized.isEmpty, let data = normalized.data(using: .utf8) else {
            throw ClaudeWebSessionStoreError.empty
        }
        var attributes = identity(account: account)
        attributes[kSecValueData as String] = data
        let added = SecItemAdd(attributes as CFDictionary, nil)
        if added == errSecSuccess { return }
        guard added == errSecDuplicateItem else {
            throw ClaudeWebSessionStoreError.keychain(added)
        }
        let updated = SecItemUpdate(
            identity(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        guard updated == errSecSuccess else {
            throw ClaudeWebSessionStoreError.keychain(updated)
        }
    }

    /// Forgets the session. An item that was not there is not a failure: the
    /// caller asked for it gone and it is gone.
    static func delete(account: String = defaultAccount) throws {
        let status = SecItemDelete(identity(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ClaudeWebSessionStoreError.keychain(status)
        }
    }

    /// What the item is, with neither a value nor a read on it. Shared by
    /// every operation so an add, an update and a delete cannot drift into
    /// addressing different items.
    private static func identity(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
    }

    /// A session as it is worth storing.
    ///
    /// One copied out of a browser's inspector arrives with whitespace around
    /// it, and one copied out of a header arrives as `sessionKey=…`. Both name
    /// the same session, and rejecting either would be a puzzle rather than an
    /// error.
    static func normalize(_ session: String) -> String {
        var trimmed = session.trimmingCharacters(in: .whitespacesAndNewlines)
        if let separator = trimmed.range(of: "\(cookieName)="), separator.lowerBound == trimmed.startIndex {
            trimmed = String(trimmed[separator.upperBound...])
        }
        if let semicolon = trimmed.firstIndex(of: ";") {
            trimmed = String(trimmed[..<semicolon])
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a paste looks like a claude.ai session at all.
    ///
    /// A shape check, not a validity check — only the endpoint can say whether
    /// a session works. It exists so the obvious mis-paste, an API key or a
    /// whole shell line, is named before it is sent anywhere.
    static func looksLikeSession(_ session: String) -> Bool {
        let normalized = normalize(session)
        return normalized.hasPrefix(sessionPrefix)
            && normalized.count > sessionPrefix.count
            && !normalized.contains(where: \.isWhitespace)
    }

    /// Name of the cookie claude.ai authenticates with.
    static let cookieName = "sessionKey"

    private static func decode(_ data: Data) -> ClaudeCredentials? {
        guard let session = String(data: data, encoding: .utf8) else { return nil }
        let normalized = normalize(session)
        guard !normalized.isEmpty else { return nil }
        return ClaudeCredentials(accessToken: normalized, expiresAt: nil)
    }
}

enum ClaudeWebSessionStoreError: Error, Equatable {
    /// An import or paste with nothing in it. Distinct from a keychain failure
    /// because it is the user's to fix and names no status code.
    case empty
    case keychain(OSStatus)
}
