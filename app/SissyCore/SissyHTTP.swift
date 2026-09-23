import Foundation

/// The one HTTP session every reader in Sissy sends through, and the only one
/// that may be used.
///
/// The process-wide default session keeps a disk cache and a cookie jar under
/// the bundle id, and Sissy's requests carry credentials in their headers.
/// Measured 2026-09-23 on a release install that had sent everything through
/// it: `Cache.db` held 15 requests carrying a forge's `PRIVATE-TOKEN`, 6
/// carrying a claude.ai `sessionKey` and 7 carrying a bearer token, and
/// neither Disconnect nor Unlink reached that file. So this session is
/// ephemeral and stores nothing: no cache, no cookie jar, no credential
/// store. `HTTPStoragePurge` removes what the default session left behind.
/// `SissyHTTPTests` fails the build's suite if a source sends through the
/// default one again.
///
/// A redirect is followed, because a vendor moving an endpoint is ordinary,
/// but a redirect off the origin the request was addressed to loses every
/// credential header on the way, which is what a forge behind an SSO proxy
/// would otherwise hand to the proxy, and a redirect off the origin of a
/// request with a body is not followed at all.
enum SissyHTTP {
    /// The idle bound for any request that sets no timeout of its own. Every
    /// reader sets one, at most this long.
    static let requestTimeout: TimeInterval = 30

    /// The bound on a whole transfer, retries and redirects included. Sized
    /// for the LiteLLM catalog, the one reply that is not a few kilobytes.
    static let resourceTimeout: TimeInterval = 120

    /// Headers that carry a credential or name the account one is for,
    /// lowercased: the bearer token, the claude.ai session, GitLab's personal
    /// access token and the ChatGPT workspace a Codex reading is asked for.
    static let credentialHeaders: Set<String> = [
        "authorization", "cookie", "private-token", "chatgpt-account-id",
    ]

    static let session: URLSession = URLSession(
        configuration: configuration(), delegate: RedirectGuard(), delegateQueue: nil)

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return configuration
    }

    /// Methods whose redirect carries nothing but the URL and the headers.
    static let bodilessMethods: Set<String> = ["GET", "HEAD"]

    /// The request a redirect is followed with: `request` whole when it stays
    /// on the origin of `original`, and without any of `credentialHeaders`
    /// when it does not. An unknown original counts as another origin.
    ///
    /// A request with a body is not followed off its origin at all, `nil`
    /// handing the redirect itself back to the caller: a `307` or `308`
    /// resends the body, and the body of an OAuth token exchange is the
    /// authorization code or the refresh token, which no header strip reaches.
    /// The method decides as well as the body, because a POST's body can sit
    /// in a stream the request does not expose.
    static func redirected(_ request: URLRequest, from original: URLRequest?) -> URLRequest? {
        if sameOrigin(original?.url, request.url) { return request }
        if carriesABody(original) || carriesABody(request) { return nil }
        var stripped = request
        for field in (request.allHTTPHeaderFields ?? [:]).keys
        where credentialHeaders.contains(field.lowercased()) {
            stripped.setValue(nil, forHTTPHeaderField: field)
        }
        return stripped
    }

    /// Whether two URLs name one origin. Either one unknown answers `false`.
    static func sameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let from = lhs.flatMap(Origin.init), let to = rhs.flatMap(Origin.init) else {
            return false
        }
        return from == to
    }

    private static func carriesABody(_ request: URLRequest?) -> Bool {
        guard let request else { return false }
        let method = (request.httpMethod ?? "GET").uppercased()
        return !bodilessMethods.contains(method) || request.httpBody != nil
            || request.httpBodyStream != nil
    }

    /// Scheme, host and port, the triple a browser calls an origin, with the
    /// scheme's default port filled in so `:443` names the same one.
    private struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int

        private static let defaultPorts = ["https": 443, "http": 80]

        init?(_ url: URL) {
            guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased(),
                let port = url.port ?? Self.defaultPorts[scheme]
            else { return nil }
            self.scheme = scheme
            self.host = host
            self.port = port
        }
    }

    /// The session's delegate, which answers every redirect through
    /// `redirected(_:from:)` against the task's own original request, and
    /// refuses the ones that answers `nil` for.
    final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
        ) async -> URLRequest? {
            SissyHTTP.redirected(request, from: task.originalRequest)
        }
    }
}
