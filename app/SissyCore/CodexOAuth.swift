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
        return try await exchange(body, send: send)
    }

    /// Renews a credential Sissy owns.
    ///
    /// Only ever the item in `CodexAccountStore`: a refresh token is redeemed
    /// once, so spending the CLI's would leave the terminal holding one OpenAI
    /// has already retired. `CodexCredential.refreshToken` is nil for every
    /// credential read from `auth.json`, which is what makes that a property
    /// of the value rather than a rule each caller has to remember.
    static func refresh(
        _ credential: CodexCredential,
        send: @Sendable (URLRequest) async throws -> (Data, URLResponse) = perform
    ) async throws -> CodexCredential {
        guard let refreshToken = credential.refreshToken else { throw Failure.refused }
        let renewed = try await exchange(
            [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": clientID,
                "scope": scope,
            ],
            send: send)
        // OpenAI may answer without re-issuing the parts it did not rotate, and
        // the workspace is the user's choice rather than the vendor's — so what
        // the reply does not carry is taken from the credential being renewed.
        return CodexCredential(
            accessToken: renewed.accessToken,
            refreshToken: renewed.refreshToken ?? refreshToken,
            idToken: renewed.idToken ?? credential.idToken,
            accountId: renewed.accountId ?? credential.accountId,
            userId: renewed.userId ?? credential.userId,
            email: renewed.email ?? credential.email,
            plan: renewed.plan ?? credential.plan,
            expiresAt: renewed.expiresAt
        )
    }

    /// One call to the token endpoint, read through the same parser
    /// `auth.json` is: the reply carries the same three tokens under the same
    /// names, so it is handed over as that shape rather than parsed twice.
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
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure.refused
        }
        guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let bundle = try? JSONSerialization.data(withJSONObject: ["tokens": reply]),
            let credential = CodexAuthSource.credential(bundle, renewable: true),
            credential.userId != nil
        else { throw Failure.unidentified }
        return credential
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
