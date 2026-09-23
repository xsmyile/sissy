import Foundation

/// The OAuth credential a Codex account is read with.
///
/// Two places hold one: `~/.codex/auth.json`, which is the CLI's and which
/// Sissy only ever reads, and `CodexAccountStore`, which is Sissy's own
/// keychain item for an account the user linked. The difference is not the
/// shape but the ownership, and ownership is what decides whether the refresh
/// token may be spent — see `CodexOAuth.refresh`.
struct CodexCredential: Sendable, Equatable {
    let accessToken: String
    /// Nil for a credential Sissy must not renew. A refresh redeems a
    /// one-time token, so the copy that holds it is the copy that owns it.
    let refreshToken: String?
    let idToken: String?
    /// Which of the login's workspaces the usage question is asked for, as
    /// OpenAI's `ChatGPT-Account-Id`. A login can hold several and they are
    /// metered separately.
    let accountId: String?
    /// The login this credential belongs to (`user-…`), which is the key a
    /// row, a keychain item and a link are all filed under. Stable across a
    /// refresh, where the tokens are not.
    let userId: String?
    let email: String?
    let plan: String?
    /// When the access token dies. Measured 2026-09-17: ten days from issue,
    /// and the CLI reissues on its own runs — so a credential belonging to an
    /// account nobody is working in expires unless its owner renews it.
    let expiresAt: Date?

    /// Whether the token is spent or so near its end that a poll would be.
    func isExpired(at now: Date = Date(), margin: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= margin
    }
}

/// What one attempt to read a Codex credential found.
///
/// The three absences are three different sentences and none of them is the
/// others: a Mac with no Codex at all, an account signed out of it, and a
/// credential Sissy is not currently allowed to read. Folding them together
/// is what sends a user to sign in somewhere they already are.
enum CodexCredentialReading: Sendable, Equatable {
    case found(CodexCredential)
    /// The file or item is there and holds no tokens — signed out, or driving
    /// the API with a key, which is a Codex with no subscription behind it.
    case signedOut
    /// Nothing filed at all.
    case missing
    /// The item is there and this read was not allowed to ask for it, which
    /// is what a re-signed build meets on Sissy's own keychain item. One user
    /// action recovers it, so it is emphatically not `signedOut`.
    case needsAuthorization
    /// The user was asked and said no.
    case refused
    /// The credential is spent and the token endpoint rejected its renewal:
    /// a refresh token OpenAI has retired, which happens when it has been
    /// redeemed elsewhere or the user revoked the session. Nothing local can
    /// repair it, so the row says so and the account is linked again. A
    /// renewal that merely got no answer is `unreadable`, never this.
    case expired
    /// Present and unparseable, which a half-written file is. Transient by
    /// assumption: the caller keeps its last reading rather than blanking a
    /// row every time the CLI rewrites its tokens.
    case unreadable(String)
}
