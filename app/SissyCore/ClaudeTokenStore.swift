import Foundation
import Security

/// The long-lived Claude token a user handed to Sissy, in a keychain item
/// Sissy owns.
///
/// Reading Claude Code's own item is not a permission anyone grants once. The
/// CLI rewrites that item on every token refresh and its ACL goes with it, so
/// an Allow lasts a token cycle — measured 2026-09-13, three rewrites of an
/// item created in April, 73 and 26 minutes apart, with no Sissy build in
/// between. A user watching their limits therefore meets a system dialog on
/// the order of hourly, and a permission asked for hourly is not one that was
/// granted.
///
/// An item Sissy creates has Sissy on its ACL and nothing but Sissy ever
/// rewrites it, which moves the ceiling from a token cycle to a re-signing.
/// The token comes from `claude setup-token`, the CLI's own way of minting a
/// long-lived credential: Sissy never mints, refreshes or revokes one, and
/// the only write on this path is the user pasting.
///
/// This is the first secret Sissy holds. It is never logged, never put on the
/// frame, and never reaches the diagnostics report or the export — the value
/// leaves this type only as an `Authorization` header.
enum ClaudeTokenStore {
    /// Service the item is filed under. A literal rather than a provider id:
    /// renaming a provider must not orphan a credential the user pasted.
    static let keychainService = "com.radonforge.sissy.claude-token"
    static let keychainAccount = "claude-code"

    /// Prefix `claude setup-token` prints, kept so a paste can be recognised
    /// as a token before it is spent on a request.
    static let tokenPrefix = "sk-ant-"
    private static let bearerPrefix = "Bearer "

    /// Whether a token is filed, asked without decrypting one.
    ///
    /// The query returns attributes and deliberately not data: the file
    /// keychain authorizes a *read of the secret*, so asking whether the item
    /// exists costs no ACL check and cannot raise a dialog. That is what lets
    /// Settings say "a token is set" on a re-signed build, where actually
    /// reading it would prompt.
    static func isPresent() -> Bool {
        var query = identity
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// The token, under the same suppression a read of the CLI's item gets.
    ///
    /// Silent in the ordinary case, because Sissy wrote this item. After a
    /// re-signing it is not, and then a scheduled read has to answer
    /// `.interactionRequired` rather than interrupt — the same rule, for the
    /// same reason, as the item next door.
    static func load(allowingInteraction: Bool) -> ClaudeCredentialsLookup {
        var query = ClaudeCredentialsStore.makeQuery(
            service: keychainService, allowingInteraction: allowingInteraction)
        query[kSecAttrAccount as String] = keychainAccount
        let result = ClaudeCredentialsStore.copyMatching(
            query, allowingInteraction: allowingInteraction)
        return ClaudeCredentialsStore.classify(
            result.status,
            data: result.data,
            allowingInteraction: allowingInteraction,
            decode: decode
        )
    }

    /// Files `token`, replacing whatever was there.
    ///
    /// Add-then-update rather than delete-then-add: a delete that succeeds
    /// followed by an add that fails would leave the user with no token and
    /// no way to tell that from a token they never pasted.
    static func save(_ token: String) throws {
        let normalized = normalize(token)
        guard !normalized.isEmpty else { throw ClaudeTokenStoreError.empty }
        guard let data = normalized.data(using: .utf8) else {
            throw ClaudeTokenStoreError.empty
        }
        var attributes = identity
        attributes[kSecValueData as String] = data
        let added = SecItemAdd(attributes as CFDictionary, nil)
        if added == errSecSuccess { return }
        guard added == errSecDuplicateItem else {
            throw ClaudeTokenStoreError.keychain(added)
        }
        let updated = SecItemUpdate(
            identity as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        guard updated == errSecSuccess else {
            throw ClaudeTokenStoreError.keychain(updated)
        }
    }

    /// Forgets the token. An item that was not there is not a failure: the
    /// caller asked for it gone and it is gone.
    static func delete() throws {
        let status = SecItemDelete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ClaudeTokenStoreError.keychain(status)
        }
    }

    /// What the item is, with neither a value nor a read on it. Shared by
    /// every operation so an add, an update and a delete cannot drift into
    /// addressing different items.
    private static var identity: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    /// A pasted token as it is worth storing.
    ///
    /// A token copied out of a terminal arrives with whitespace around it, and
    /// one copied out of a header arrives with `Bearer ` in front. Both are
    /// the same token, and rejecting either would be a puzzle rather than an
    /// error.
    static func normalize(_ token: String) -> String {
        var trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(bearerPrefix) {
            trimmed = String(trimmed.dropFirst(bearerPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    /// Whether a paste looks like a Claude token at all.
    ///
    /// A shape check, not a validity check — only the endpoint can say
    /// whether a token works. It exists so the obvious mis-paste, an API key
    /// or a whole shell line, is named before it is sent anywhere.
    static func looksLikeToken(_ token: String) -> Bool {
        let normalized = normalize(token)
        return normalized.hasPrefix(tokenPrefix)
            && normalized.count > tokenPrefix.count
            && !normalized.contains(where: \.isWhitespace)
    }

    private static func decode(_ data: Data) -> ClaudeCredentials? {
        guard let token = String(data: data, encoding: .utf8) else { return nil }
        let normalized = normalize(token)
        guard !normalized.isEmpty else { return nil }
        return ClaudeCredentials(accessToken: normalized, expiresAt: nil, origin: .managed)
    }
}

enum ClaudeTokenStoreError: Error, Equatable {
    /// A paste with nothing in it. Distinct from a keychain failure because
    /// it is the user's to fix and names no status code.
    case empty
    case keychain(OSStatus)
}
