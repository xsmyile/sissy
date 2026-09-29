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
    static let keychainService = SissyPaths.keychainService("claude-web")
    /// Where a session waits until Sissy knows whose it is.
    ///
    /// Sessions are filed under the Anthropic account uuid they belong to,
    /// which is the same key `ClaudeAccountStore` files a CLI credential
    /// under — measured, both vendors' endpoints name an account with one id.
    /// A cookie is opaque, though, so only claude.ai can say which account a
    /// freshly imported one is for, and that answer can be unavailable exactly
    /// when the import happens.
    ///
    /// So this is the holding key, and it has two occupants: the item an
    /// install imported before sessions were keyed at all, and an import whose
    /// identifying request did not come back. `ClaudeWebSessionAdoption` keys
    /// whatever it finds here, which is what makes one pass answer for both
    /// rather than a migration answering for one of them.
    static let unkeyedAccount = "claude-web"

    /// The session, under the same suppression a read of the CLI's item gets.
    ///
    /// Silent in the ordinary case, because Sissy wrote this item. After a
    /// re-signing it is not, and then a scheduled read has to answer
    /// `.interactionRequired` rather than interrupt — the same rule, for the
    /// same reason, as the item next door.
    static func load(
        account: String,
        allowingInteraction: Bool
    ) -> ClaudeCredentialsLookup {
        items.load(account: account, allowingInteraction: allowingInteraction, decoding: decode)
    }

    /// Files `session`, replacing whatever was there.
    static func save(_ session: String, account: String) throws {
        let normalized = normalize(session)
        guard !normalized.isEmpty, let data = normalized.data(using: .utf8) else {
            throw ClaudeWebSessionStoreError.empty
        }
        let status = items.save(data, account: account)
        guard status == errSecSuccess else { throw ClaudeWebSessionStoreError.keychain(status) }
    }

    /// Forgets the session. An item that was not there is not a failure.
    static func delete(account: String) throws {
        let status = items.delete(account: account)
        guard status == errSecSuccess else { throw ClaudeWebSessionStoreError.keychain(status) }
    }

    /// Every account a session is filed under, sorted so two calls agree, and
    /// read without a dialog: see `SissyKeychainItems.accounts()`.
    static func storedAccounts() -> [String] { items.accounts() }

    private static let items = SissyKeychainItems(
        service: keychainService, listing: "the stored claude.ai sessions")

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
