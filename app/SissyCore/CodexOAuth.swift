import CryptoKit
import Foundation

/// The sign-in that puts a second Codex account on this Mac, and the renewal
/// that keeps it there.
///
/// It is OpenAI's own login in a window, for the reason claude.ai's is: a
/// credential cannot be had without the vendor's page, and measured
/// 2026-09-17 that page answers **403 to anything that is not a real browser**
/// — Cloudflare's challenge, before any form is shown. So a background HTTP
/// flow cannot sign anyone in here, and the webview is not a convenience.
///
/// **It signs in as the Codex CLI, and that is a deliberate trade.** The
/// client id below is the one the `codex` binary ships and every `auth.json`
/// on this machine already carries; OpenAI publishes no other, and the scopes
/// asked for are exactly the ones the CLI asks for. The alternative measured
/// was CodexBar's — run `codex login` against a `CODEX_HOME` of the app's own
/// — which needs the binary on `PATH`, spawns a subprocess to show the same
/// page, and leaves a directory behind. What Sissy does with the result is the
/// difference that matters: the credential goes in Sissy's own keychain item
/// and is never written where a `codex` could pick it up, so linking an
/// account cannot change which account the terminal is on.
enum CodexOAuth {
    /// The public client the Codex CLI authenticates with. Public by
    /// construction — it is in the binary, in the browser's address bar during
    /// a login, and in every `auth.json` this Mac holds.
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    /// Where the CLI's own flow lands. Nothing listens on it here: the window
    /// cancels the navigation and reads the code off the URL, which is what
    /// keeps Sissy from binding a port for the length of a login.
    static let redirectURI = "http://localhost:1455/auth/callback"
    static let scope = "openid profile email offline_access"
    private static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let requestTimeout: TimeInterval = 30
    private static let verifierBytes = 48

    /// One sign-in: the URL to open and the secret that redeems its code.
    ///
    /// A value rather than shared state because two logins must not be able to
    /// redeem each other's code, and because the verifier has to outlive the
    /// page without being reachable from it.
    struct Flow: Sendable {
        let url: URL
        let state: String
        fileprivate let verifier: String

        /// The code this flow's redirect carries, and nil for any other
        /// navigation — which is every navigation until the last one.
        ///
        /// The state is checked here rather than by the caller: it is the
        /// whole of what says the code belongs to this login, and a caller
        /// that forgets is a caller that accepts somebody else's.
        func code(fromRedirect url: URL) -> String? {
            guard url.scheme == "http" || url.scheme == "https",
                url.host == "localhost" || url.host == "127.0.0.1",
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                let items = components.queryItems,
                items.first(where: { $0.name == "state" })?.value == state,
                let code = items.first(where: { $0.name == "code" })?.value,
                !code.isEmpty
            else { return nil }
            return code
        }
    }

    /// Why a sign-in produced no account. Each is a different sentence: a
    /// vendor that refused the code is the user's to retry, and a token that
    /// names no account is one Sissy cannot file.
    enum Failure: Error, Equatable {
        case refused
        case unidentified
        case interrupted
    }

    /// Why a renewal produced no credential, in the two answers a reader can
    /// act on differently.
    enum RenewalFailure: Error, Equatable {
        /// The token endpoint turned the grant down: `invalid_grant` on a 400,
        /// or a 401. The refresh token is retired and nothing local repairs
        /// it, so the link has ended.
        case rejected
        /// Anything else: no network, a 5xx, a 429, a reply that would not
        /// parse. The refresh token may still be good, so the reader keeps its
        /// last reading and the renewal is asked again later. `retryAfter` is
        /// the vendor's own wait where it named one.
        case deferred(retryAfter: TimeInterval?)
    }

    /// A reply from the token endpoint other than 200, kept whole enough to
    /// be classified by the caller that knows what it asked for.
    private struct EndpointRefusal: Error {
        let status: Int
        let error: String?
        let retryAfter: TimeInterval?

        /// Whether this is the endpoint saying the grant itself is no good.
        var rejectsTheGrant: Bool {
            status == unauthorizedStatus
                || (status == badRequestStatus && error == invalidGrant)
        }
    }

    private static let unauthorizedStatus = 401
    private static let badRequestStatus = 400
    private static let rateLimitedStatus = 429
    private static let invalidGrant = "invalid_grant"

    static func begin() -> Flow {
        let verifier = randomToken()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = randomToken()
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            // Both are the CLI's own flags. The first is what puts the
            // `organizations` claim on the id_token, which is how an account
            // that holds more than one workspace can be asked about at all.
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
        ]
        // The fallback is the bare authorize page rather than a crash: a login
        // that starts one step early is recoverable, a trap is not.
        return Flow(url: components?.url ?? authorizeURL, state: state, verifier: verifier)
    }

    /// Redeems the code the window came back with.
    static func redeem(
        code: String,
        flow: Flow,
        send: @Sendable (URLRequest) async throws -> (Data, URLResponse) = perform
    ) async throws -> CodexCredential {
        let body = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": flow.verifier,
        ]
        do {
            let credential = try await exchange(body, send: send)
            guard credential.userId != nil else { throw Failure.unidentified }
            return credential
        } catch is EndpointRefusal {
            throw Failure.refused
        }
    }

    /// Renews a credential Sissy owns.
    ///
    /// Only ever the item in `CodexAccountStore`: a refresh token is redeemed
    /// once, so spending the CLI's would leave the terminal holding one OpenAI
    /// has already retired. `CodexCredential.refreshToken` is nil for every
    /// credential read from `auth.json`, which is what makes that a property
    /// of the value rather than a rule each caller has to remember.
    ///
    /// Throws only `RenewalFailure`, because the one thing a caller decides
    /// from a failed renewal is whether the link has ended.
    ///
    /// The workspace is the credential's, never the reply's. OpenAI's reply
    /// carries no `account_id`, so the parse falls back to the
    /// `chatgpt_account_id` claim, which is the workspace the vendor issued
    /// the token for rather than the one the user picked when linking; taking
    /// it switched every renewed link to the vendor's default under the
    /// chosen workspace's name. What else the reply does not re-issue is
    /// taken from the credential being renewed.
    static func refresh(
        _ credential: CodexCredential,
        send: @Sendable (URLRequest) async throws -> (Data, URLResponse) = perform
    ) async throws -> CodexCredential {
        guard let refreshToken = credential.refreshToken else { throw RenewalFailure.rejected }
        let renewed: CodexCredential
        do {
            renewed = try await exchange(
                [
                    "grant_type": "refresh_token",
                    "refresh_token": refreshToken,
                    "client_id": clientID,
                    "scope": scope,
                ],
                send: send)
        } catch let refusal as EndpointRefusal {
            if refusal.rejectsTheGrant { throw RenewalFailure.rejected }
            throw RenewalFailure.deferred(retryAfter: refusal.retryAfter)
        } catch {
            throw RenewalFailure.deferred(retryAfter: nil)
        }
        return CodexCredential(
            accessToken: renewed.accessToken,
            refreshToken: renewed.refreshToken ?? refreshToken,
            idToken: renewed.idToken ?? credential.idToken,
            accountId: credential.accountId,
            userId: renewed.userId ?? credential.userId,
            email: renewed.email ?? credential.email,
            plan: renewed.plan ?? credential.plan,
            expiresAt: renewed.expiresAt
        )
    }

    /// One call to the token endpoint, read through the same parser
    /// `auth.json` is: the reply carries the same three tokens under the same
    /// names, so it is handed over as that shape rather than parsed twice.
    ///
    /// A status other than 200 is thrown as an `EndpointRefusal` for the
    /// caller to word, because the same 400 is a retry for a sign-in and the
    /// end of a link for a renewal.
    private static func exchange(
        _ body: [String: String],
        send: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> CodexCredential {
        var request = URLRequest(url: tokenURL, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw Failure.refused }
        guard http.statusCode == 200 else {
            throw EndpointRefusal(
                status: http.statusCode,
                error: oauthError(in: data),
                retryAfter: http.statusCode == rateLimitedStatus
                    ? UsageRequestError.backoffSeconds(retryAfter: UsageRequestError.retryAfter(http))
                    : nil)
        }
        guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let bundle = try? JSONSerialization.data(withJSONObject: ["tokens": reply]),
            let credential = CodexAuthSource.credential(bundle, renewable: true)
        else { throw Failure.unidentified }
        return credential
    }

    /// The OAuth `error` a refusal names, in either shape OpenAI answers with:
    /// the RFC 6749 string, or an object carrying it as `code`.
    private static func oauthError(in data: Data) -> String? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = body["error"] as? String { return error }
        return (body["error"] as? [String: Any])?["code"] as? String
    }

    @Sendable private static func perform(_ request: URLRequest) async throws -> (
        Data, URLResponse
    ) {
        try await SissyHTTP.data(for: request)
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: verifierBytes)
        // A verifier that is not random proves nothing, so the fallback is
        // another draw from the system's generator rather than a weaker
        // source: Darwin's v4 UUIDs come from the same CSPRNG, and two of them
        // carry 244 bits between them.
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString + UUID().uuidString
        }
        return Data(bytes).base64URLEncoded
    }
}

extension Data {
    /// base64url without padding, which is what both PKCE and JWTs spell.
    fileprivate var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
