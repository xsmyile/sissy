import Foundation

/// One OpenAI workspace, as `backend-api/accounts` names it.
///
/// A login can hold several — a personal account and a business one on the
/// same address — and they are metered separately, so which one a credential
/// is read for is a question with a real answer rather than a detail.
struct CodexWorkspace: Sendable, Codable, Equatable, Identifiable {
    /// The `ChatGPT-Account-Id` the usage question is asked with.
    let id: String
    let name: String
    /// What the vendor calls this shape of account (`personal`, `workspace`).
    /// Raw rather than a label, the division every vendor token here takes.
    let structure: String?
}

/// Who a linked Codex account belongs to.
///
/// Read off the id_token rather than asked for over the wire: the claims name
/// the login, the address and the plan, and they are the same claims the CLI's
/// own file is read for. The id is `chatgpt_user_id`, which is the key
/// everything about this account is filed under — stable across a refresh,
/// where the tokens are not.
struct CodexAccountIdentity: Sendable, Codable, Equatable {
    let id: String
    let email: String?
    let plan: String?
}

/// What Sissy knows about a linked Codex account, beside its credential.
///
/// The credential is a secret and lives in the keychain; this is the part that
/// is not, and it exists because neither answer is derivable when it is
/// needed. The identity, because a row labelled with a raw `user-…` id names
/// nobody. The workspace, because an account holding two is metered twice and
/// membership order is the server's — a reader deriving it per poll is free to
/// derive it differently on the next one.
struct CodexAccountLink: Sendable, Codable, Equatable {
    let identity: CodexAccountIdentity
    /// The workspace this account is read for, chosen when it was linked.
    /// Absent for a login that held exactly one, where nobody was asked and
    /// the credential's own default is the only answer there is.
    let workspace: CodexWorkspace?
}

/// One account Sissy holds a Codex credential for, as a surface lists it.
///
/// Built from the stored credentials rather than from the links, for the
/// reason `ClaudeWebAccount` is: a credential is filed first and named second,
/// so one with no entry is a state the ordinary path produces — and it is
/// polling OpenAI either way. Listing the links would leave it running with no
/// row and no way to stop it.
struct CodexLinkedAccount: Sendable, Equatable, Identifiable {
    let id: String
    let link: CodexAccountLink?

    static func list(stored: [String], links: [String: CodexAccountLink]) -> [Self] {
        stored.map { Self(id: $0, link: links[$0]) }
    }
}
