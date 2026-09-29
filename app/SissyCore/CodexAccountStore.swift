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
    static let keychainService = SissyPaths.keychainService("codex-oauth")

    /// Files a credential under the login it belongs to, replacing whatever
    /// was there.
    static func save(_ credential: CodexCredential, account: String) throws {
        guard !account.isEmpty, let data = encode(credential) else {
            throw CodexAccountStoreError.empty
        }
        let status = items.save(data, account: account)
        guard status == errSecSuccess else { throw CodexAccountStoreError.keychain(status) }
    }

    /// The credential, under the same suppression a read of the CLI's own item
    /// gets — silent in the ordinary case, and refusing rather than
    /// interrupting once a re-signing has cost the grant.
    static func load(account: String, allowingInteraction: Bool) -> CodexCredentialReading {
        reading(
            items.load(
                account: account, allowingInteraction: allowingInteraction,
                decoding: { CodexAuthSource.credential($0, renewable: true) }))
    }

    /// The keychain's own outcomes in this reader's vocabulary.
    ///
    /// `timedOut` cannot arise here — it is the blocking lookup's budget, and
    /// this read does not take one — and it is answered exhaustively rather
    /// than defaulted so a case added later has to be decided here.
    static func reading(_ outcome: CredentialLookup<CodexCredential>) -> CodexCredentialReading {
        switch outcome {
        case .found(let credential): return .found(credential)
        case .absent: return .missing
        case .denied: return .refused
        case .interactionRequired: return .needsAuthorization
        case .unreadable(let status): return .unreadable("keychain status \(status)")
        case .timedOut: return .unreadable("the keychain did not answer")
        }
    }

    /// Forgets one account's credential. An item that was not there is not a
    /// failure.
    static func delete(account: String) throws {
        let status = items.delete(account: account)
        guard status == errSecSuccess else { throw CodexAccountStoreError.keychain(status) }
    }

    /// Every account a credential is filed under, sorted so two calls agree,
    /// and read without a dialog: see `SissyKeychainItems.accounts()`.
    static func storedAccounts() -> [String] { items.accounts() }

    private static let items = SissyKeychainItems(
        service: keychainService, listing: "the linked Codex accounts")

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
}

enum CodexAccountStoreError: Error, Equatable {
    /// A credential with nothing in it, or one that named no account. Its own
    /// case because it is the caller's to fix and names no status code.
    case empty
    case keychain(OSStatus)
}
