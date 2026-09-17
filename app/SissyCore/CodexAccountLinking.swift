import Foundation

/// The question a link could not answer for itself, as a surface draws it.
///
/// Carries the identity and the choices and never the credential: the
/// credential is the engine's until the question is answered, because a secret
/// that reaches a view is a secret that reaches a frame, a log, or an export.
struct CodexLinkChoice: Sendable, Equatable {
    let identity: CodexAccountIdentity
    let workspaces: [CodexWorkspace]
}

/// Turns a Codex credential into a linked account.
///
/// One question, and only OpenAI can answer it: which of this login's
/// workspaces the usage should be read for. The identity needs no request at
/// all — the id_token names the login, the address and the plan, which is the
/// same parse `auth.json` already gets.
///
/// Nothing is filed until the question is settled, for the reason the Claude
/// link does not file half of one: an account stored without an answer is one
/// every poll would guess at.
enum CodexAccountLinking {
    private static let accountsURL = URL(string: "https://chatgpt.com/backend-api/accounts")!
    private static let requestTimeout: TimeInterval = 15

    /// What one credential turned out to need.
    enum Outcome: Sendable, Equatable {
        /// The ordinary case: one workspace, or none the vendor would name, so
        /// there is nothing to ask.
        case linked(CodexAccountLink)
        /// The login holds several. Which one this credential meters is the
        /// user's to say, and it is held until they do.
        case choice(CodexLinkChoice)
    }

    /// Why a link could not be made. A credential that names no login is the
    /// only fatal one: everything else about an account can be filled in
    /// later, and a row keyed by nothing cannot.
    enum Failure: Error, Equatable {
        case unidentified
        case interrupted
    }

    static func resolve(
        credential: CodexCredential,
        workspaces fetch: @Sendable (CodexCredential) async throws -> [CodexWorkspace] =
            fetchWorkspaces
    ) async throws -> Outcome {
        guard let id = credential.userId else { throw Failure.unidentified }
        let identity = CodexAccountIdentity(
            id: id, email: credential.email, plan: credential.plan)
        // A workspace list Sissy could not read costs the row a name, never
        // the login: the credential already names the workspace OpenAI itself
        // defaults it to, which is the vendor's own answer rather than a
        // position in a list that may come back in another order tomorrow.
        let found = (try? await fetch(credential)) ?? []
        guard found.count > 1 else {
            return .linked(CodexAccountLink(identity: identity, workspace: found.first))
        }
        return .choice(CodexLinkChoice(identity: identity, workspaces: found))
    }

    /// The workspaces a credential can read, as OpenAI lists them.
    static func fetchWorkspaces(_ credential: CodexCredential) async throws -> [CodexWorkspace] {
        var request = URLRequest(url: accountsURL, timeoutInterval: requestTimeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageRequestError.malformedPayload
        }
        guard http.statusCode == 200 else { throw UsageRequestError.badStatus(http.statusCode) }
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageRequestError.malformedPayload
        }
        return workspaces(in: body)
    }

    /// One reply's worth of workspaces. Pure, so which ones a payload yields is
    /// testable without a token: an entry with no id is no workspace, and one
    /// with no name takes its id, which is at least addressable.
    static func workspaces(in body: [String: Any]) -> [CodexWorkspace] {
        let items = (body["items"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        return items.compactMap { item in
            guard let id = UsageReaderShared.sanitizedDisplayText(item["id"] as? String) else {
                return nil
            }
            return CodexWorkspace(
                id: id,
                name: UsageReaderShared.sanitizedDisplayText(item["name"] as? String) ?? id,
                structure: UsageReaderShared.sanitizedDisplayText(item["structure"] as? String)
            )
        }
    }
}
