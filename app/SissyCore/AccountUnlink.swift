import Foundation

/// Unlinking one linked account: the credential Sissy holds for it, then the
/// name recorded beside it.
///
/// Both halves used to be `try?`, so an Unlink the keychain refused closed its
/// dialog, left the account linked and said nothing. What either half failed
/// with is now the caller's to show, and the order is what keeps a failure
/// from leaving worse than it found: the name is dropped only once the
/// credential is gone, because a credential with no name still gets a row, and
/// a way to remove it, while a name with no credential gets neither.
enum AccountUnlink {
    enum Failure: Error, Equatable, Sendable {
        /// The keychain would not delete the credential. Nothing changed: the
        /// account is still linked and its reader still polls.
        case credentialKept
        /// The credential is gone and the index would not drop its name, so
        /// the account is unlinked and a stale entry is left in a file.
        case nameKept
    }

    /// A failure and the account it was reported for, which is what lets the
    /// row drop it once it is no longer true. The dialog that started the
    /// Unlink is gone by then, so nothing else would: a link made again or an
    /// account removed some other way left the row reporting a refusal that
    /// no longer described anything.
    struct Report: Equatable, Sendable {
        let account: String
        let failure: Failure

        /// Whether the failure still describes the accounts now listed.
        /// `credentialKept` says the account is still linked, so it stands
        /// while the account is listed; `nameKept` says it was unlinked, so
        /// it stands only while it is not.
        func stands(amongListed listed: Set<String>) -> Bool {
            switch failure {
            case .credentialKept: listed.contains(account)
            case .nameKept: !listed.contains(account)
            }
        }
    }

    /// Runs both halves in order. `what` names the credential in the log,
    /// which is where the underlying error goes: the row has only the case.
    static func run(
        _ what: String,
        removeCredential: () async throws -> Void,
        forgetName: () throws -> Void
    ) async -> Result<Void, Failure> {
        do {
            try await removeCredential()
        } catch {
            sissyLog("sissy: could not delete the linked \(what) from the keychain: \(error)")
            return .failure(.credentialKept)
        }
        do {
            try forgetName()
        } catch {
            sissyLog("sissy: deleted the linked \(what) but could not drop its name: \(error)")
            return .failure(.nameKept)
        }
        return .success(())
    }
}
