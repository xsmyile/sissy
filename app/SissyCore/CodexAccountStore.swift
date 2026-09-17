import Foundation
import Security

/// A linked Codex account's OAuth credential, in a keychain item Sissy owns.
///
/// The CLI keeps exactly one account in `~/.codex/auth.json` — whichever one
/// it is signed in as — so watching a second is not something that file can be
/// asked. CodexBar answers it with a `CODEX_HOME` per account, which is a
/// directory the CLI never writes to unless the user exports the variable, so
/// the extra accounts are the ones they are not working in. This is the other
/// answer: the account *is* the credential, so Sissy holds one per account and
/// asks OpenAI the same question with each.
///
/// Sissy's own item rather than a copy of the CLI's, for the reason the
/// claude.ai session store next door exists: an item this process created is on
/// its own ACL and reads with no dialog, right up until Sissy is re-signed,
/// where a background read answers `.needsAuthorization` rather than
/// interrupting. And it is the *only* copy Sissy may renew — a refresh token is
/// one-time, so redeeming the CLI's would strand the terminal.
///
/// The value is whole, tokens included. It is never logged, never put on a
/// frame, and never reaches the diagnostics report or the export; it leaves
/// this type as an `Authorization` header to OpenAI and nowhere else.
enum CodexAccountStore {
    /// Service the items are filed under. A literal rather than a provider id,
    /// so renaming a provider cannot orphan a credential the user linked.
    static let keychainService = "com.radonforge.sissy.codex-oauth"

    /// Files a credential under the login it belongs to, replacing whatever
    /// was there.
    ///
    /// Add-then-update rather than delete-then-add, so a delete that succeeds
    /// followed by an add that fails cannot leave the user with no credential
    /// and no way to tell that from an account they never linked.
    static func save(_ credential: CodexCredential, account: String) throws {
        guard !account.isEmpty, let data = encode(credential) else {
            throw CodexAccountStoreError.empty
        }
        var attributes = identity(account: account)
        attributes[kSecValueData as String] = data
        let added = SecItemAdd(attributes as CFDictionary, nil)
        if added == errSecSuccess { return }
        guard added == errSecDuplicateItem else {
            throw CodexAccountStoreError.keychain(added)
        }
        let updated = SecItemUpdate(
            identity(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        guard updated == errSecSuccess else {
            throw CodexAccountStoreError.keychain(updated)
        }
    }

    /// The credential, under the same suppression a read of the CLI's own item
    /// gets — silent in the ordinary case, and refusing rather than
    /// interrupting once a re-signing has cost the grant.
    static func load(account: String, allowingInteraction: Bool) -> CodexCredentialReading {
        var query = ClaudeCredentialsStore.makeQuery(
            service: keychainService, allowingInteraction: allowingInteraction)
        query[kSecAttrAccount as String] = account
        let result = ClaudeCredentialsStore.copyMatching(
            query, allowingInteraction: allowingInteraction)
        let outcome = ClaudeCredentialsStore.classify(
            result.status,
            data: result.data,
            allowingInteraction: allowingInteraction,
            decoding: { CodexAuthSource.credential($0, renewable: true) }
        )
        return Self.reading(outcome)
    }

    /// The keychain's own outcomes in this reader's vocabulary.
    ///
    /// `unreachable` and `timedOut` cannot arise here — the first is a Claude
    /// config home's hashed service name and the second is the blocking
    /// lookup's budget, which this read does not take — and they are answered
    /// exhaustively rather than defaulted so a case added later has to be
    /// decided here.
    static func reading(_ outcome: CredentialLookup<CodexCredential>) -> CodexCredentialReading {
        switch outcome {
        case .found(let credential): return .found(credential)
        case .absent: return .missing
        case .denied: return .refused
        case .interactionRequired: return .needsAuthorization
        case .unreadable(let status): return .unreadable("keychain status \(status)")
        case .unreachable, .timedOut: return .unreadable("the keychain did not answer")
        }
    }

    /// The credential a reader should poll with, renewed if it is spent.
    ///
    /// Renewal belongs to the store because ownership does: this item is the
    /// only Codex credential Sissy may redeem a refresh token for, and the
    /// renewal has to be filed the moment it lands — OpenAI rotates the
    /// refresh token, so a renewal that is used and not saved leaves the item
    /// holding one that has already been spent.
    ///
    /// A renewal the vendor refuses is the end of this link: the account says
    /// so on its row rather than polling with a token that can only ever be
    /// answered 401.
    static func supply(account: String, allowingInteraction: Bool) async -> CodexCredentialReading {
        let reading = load(account: account, allowingInteraction: allowingInteraction)
        guard case .found(let credential) = reading, credential.isExpired() else { return reading }
        do {
            let renewed = try await CodexOAuth.refresh(credential)
            try save(renewed, account: account)
            return .found(renewed)
        } catch let error as CodexAccountStoreError {
            // Renewed and not filed: the item still holds the spent token, so
            // this reading is used and the next poll renews again rather than
            // reporting an account that is working as gone.
            sissyLog("sissy: a renewed Codex credential could not be filed (\(error))")
            return reading
        } catch {
            return .expired
        }
    }

    /// Forgets one account's credential. An item that was not there is not a
    /// failure: the caller asked for it gone and it is gone.
    static func delete(account: String) throws {
        let status = SecItemDelete(identity(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CodexAccountStoreError.keychain(status)
        }
    }

    /// Every account a credential is filed under, sorted so two calls agree.
    ///
    /// Attributes only and never the data, so asking which accounts exist
    /// costs no ACL check and cannot raise a dialog — which is what lets the
    /// engine decide how many readers to build before any of them has read
    /// anything, and on a build whose grant has lapsed.
    static func storedAccounts() -> [String] {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                sissyLog("sissy: could not list the linked Codex accounts (OSStatus \(status))")
            }
            return []
        }
        guard let attributes = items as? [[String: Any]] else { return [] }
        return attributes.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    /// The credential as `auth.json` spells it, so the item and the CLI's file
    /// are read by one parser rather than two that can disagree about which
    /// claim names the account.
    static func encode(_ credential: CodexCredential) -> Data? {
        var tokens: [String: Any] = ["access_token": credential.accessToken]
        tokens["refresh_token"] = credential.refreshToken
        tokens["id_token"] = credential.idToken
        tokens["account_id"] = credential.accountId
        return try? JSONSerialization.data(withJSONObject: ["tokens": tokens])
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
        ]
    }

    /// What the item is, with neither a value nor a read on it. Shared by
    /// every operation so an add, an update and a delete cannot drift into
    /// addressing different items.
    private static func identity(account: String) -> [String: Any] {
        var query = baseQuery()
        query[kSecAttrAccount as String] = account
        return query
    }
}

enum CodexAccountStoreError: Error, Equatable {
    /// A credential with nothing in it, or one that named no account. Its own
    /// case because it is the caller's to fix and names no status code.
    case empty
    case keychain(OSStatus)
}
