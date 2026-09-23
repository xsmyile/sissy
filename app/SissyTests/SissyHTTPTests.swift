import XCTest

@testable import Sissy

/// What the one session every reader sends through has to keep off the disk,
/// and what it has to keep off a host the request was not addressed to.
///
/// Measured 2026-09-23 on a release install that had sent everything through
/// the process-wide default session: its `Cache.db` held 15 requests carrying
/// a forge's `PRIVATE-TOKEN`, 6 carrying a claude.ai `sessionKey` and 7
/// carrying a bearer token, and nothing Sissy did on unlink reached that file.
final class SissyHTTPTests: XCTestCase {
    private static let sourceDirectories = ["Sissy", "SissyCore"]
    private static let forbiddenCall = "URLSession" + ".shared"

    private var appRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    func testNoSourceSendsThroughTheDefaultSession() throws {
        var offenders: [String] = []
        var scanned = 0
        for directory in Self.sourceDirectories {
            let root = appRoot.appendingPathComponent(directory)
            let walker = try XCTUnwrap(FileManager.default.enumerator(atPath: root.path))
            for case let relative as String in walker where relative.hasSuffix(".swift") {
                scanned += 1
                let text = try String(
                    contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
                if text.contains(Self.forbiddenCall) { offenders.append("\(directory)/\(relative)") }
            }
        }
        XCTAssertGreaterThan(scanned, 0, "the walk read no source, so it proves nothing")
        XCTAssertEqual(offenders, [], "these send through a session that persists cache and cookies")
    }

    func testTheSessionKeepsNothingOnDisk() {
        let configuration = SissyHTTP.session.configuration
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testTheSessionBoundsEveryRequest() {
        let configuration = SissyHTTP.session.configuration
        XCTAssertEqual(configuration.timeoutIntervalForRequest, SissyHTTP.requestTimeout)
        XCTAssertEqual(configuration.timeoutIntervalForResource, SissyHTTP.resourceTimeout)
    }

    func testACrossOriginRedirectLosesItsCredentials() throws {
        let original = try XCTUnwrap(URL(string: "https://gitlab.example.com/api/v4/user"))
        let target = try XCTUnwrap(URL(string: "https://sso.example.net/login"))
        let followed = try XCTUnwrap(
            SissyHTTP.redirected(Self.credentialed(target), from: URLRequest(url: original)))
        for header in ["Authorization", "Cookie", "PRIVATE-TOKEN", "ChatGPT-Account-Id"] {
            XCTAssertNil(followed.value(forHTTPHeaderField: header), "\(header) reached another host")
        }
        XCTAssertEqual(followed.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testASameOriginRedirectKeepsItsCredentials() throws {
        let original = try XCTUnwrap(URL(string: "https://gitlab.example.com/api/v4/user"))
        let target = try XCTUnwrap(URL(string: "https://GITLAB.example.com:443/api/v4/users/1"))
        let followed = try XCTUnwrap(
            SissyHTTP.redirected(Self.credentialed(target), from: URLRequest(url: original)))
        XCTAssertEqual(followed.value(forHTTPHeaderField: "PRIVATE-TOKEN"), "token")
        XCTAssertEqual(followed.value(forHTTPHeaderField: "Authorization"), "Bearer token")
    }

    func testADowngradeToPlainHTTPLosesItsCredentials() throws {
        let original = try XCTUnwrap(URL(string: "https://gitlab.example.com/api/v4/user"))
        let target = try XCTUnwrap(URL(string: "http://gitlab.example.com/api/v4/user"))
        let followed = try XCTUnwrap(
            SissyHTTP.redirected(Self.credentialed(target), from: URLRequest(url: original)))
        XCTAssertNil(followed.value(forHTTPHeaderField: "Authorization"))
    }

    func testAnotherPortIsAnotherOrigin() throws {
        let original = try XCTUnwrap(URL(string: "https://gitlab.example.com/api/v4/user"))
        let target = try XCTUnwrap(URL(string: "https://gitlab.example.com:8443/api/v4/user"))
        let followed = try XCTUnwrap(
            SissyHTTP.redirected(Self.credentialed(target), from: URLRequest(url: original)))
        XCTAssertNil(followed.value(forHTTPHeaderField: "Cookie"))
    }

    func testTheSessionsDelegateStripsARedirectOffTheTasksOwnOrigin() async throws {
        let original = try XCTUnwrap(URL(string: "https://api.github.com/graphql"))
        let target = try XCTUnwrap(URL(string: "https://proxy.example.net/graphql"))
        let task = SissyHTTP.session.dataTask(with: original)
        defer { task.cancel() }
        let response = try XCTUnwrap(
            HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil))
        let delegate = try XCTUnwrap(SissyHTTP.session.delegate as? SissyHTTP.RedirectGuard)
        let followed = await delegate.urlSession(
            SissyHTTP.session, task: task, willPerformHTTPRedirection: response,
            newRequest: Self.credentialed(target))
        let request = try XCTUnwrap(followed)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.url, target)
    }

    func testACrossOriginRedirectOfARequestWithABodyIsRefused() throws {
        let original = try XCTUnwrap(URL(string: "https://auth.openai.com/oauth/token"))
        let target = try XCTUnwrap(URL(string: "https://elsewhere.example.net/oauth/token"))
        var posted = URLRequest(url: original)
        posted.httpMethod = "POST"
        posted.httpBody = Data("grant_type=refresh_token&refresh_token=value".utf8)
        var forwarded = URLRequest(url: target)
        forwarded.httpMethod = "POST"
        forwarded.httpBody = posted.httpBody
        XCTAssertNil(SissyHTTP.redirected(forwarded, from: posted))
    }

    func testACrossOriginRedirectOfAPostIsRefusedEvenWhenTheBodyWasDropped() throws {
        let original = try XCTUnwrap(URL(string: "https://api.github.com/graphql"))
        let target = try XCTUnwrap(URL(string: "https://proxy.example.net/graphql"))
        var posted = URLRequest(url: original)
        posted.httpMethod = "POST"
        XCTAssertNil(SissyHTTP.redirected(URLRequest(url: target), from: posted))
    }

    func testASameOriginRedirectOfAPostIsFollowed() throws {
        let original = try XCTUnwrap(URL(string: "https://auth.openai.com/oauth/token"))
        let target = try XCTUnwrap(URL(string: "https://auth.openai.com/v2/oauth/token"))
        var posted = URLRequest(url: original)
        posted.httpMethod = "POST"
        posted.httpBody = Data("grant_type=authorization_code".utf8)
        var forwarded = URLRequest(url: target)
        forwarded.httpMethod = "POST"
        forwarded.httpBody = posted.httpBody
        XCTAssertEqual(SissyHTTP.redirected(forwarded, from: posted)?.url, target)
    }

    func testTheSessionsDelegateRefusesAPostRedirectedOffItsOrigin() async throws {
        let original = try XCTUnwrap(URL(string: "https://auth.openai.com/oauth/token"))
        let target = try XCTUnwrap(URL(string: "https://elsewhere.example.net/oauth/token"))
        var posted = URLRequest(url: original)
        posted.httpMethod = "POST"
        posted.httpBody = Data("code=value".utf8)
        let task = SissyHTTP.session.dataTask(with: posted)
        defer { task.cancel() }
        let response = try XCTUnwrap(
            HTTPURLResponse(url: original, statusCode: 307, httpVersion: nil, headerFields: nil))
        let delegate = try XCTUnwrap(SissyHTTP.session.delegate as? SissyHTTP.RedirectGuard)
        var forwarded = URLRequest(url: target)
        forwarded.httpMethod = "POST"
        forwarded.httpBody = posted.httpBody
        let followed = await delegate.urlSession(
            SissyHTTP.session, task: task, willPerformHTTPRedirection: response, newRequest: forwarded)
        XCTAssertNil(followed)
    }

    private static func reply(_ status: Int, from url: String, location: String? = nil) throws
        -> HTTPURLResponse
    {
        try XCTUnwrap(
            HTTPURLResponse(
                url: XCTUnwrap(URL(string: url)), statusCode: status, httpVersion: nil,
                headerFields: location.map { ["Location": $0] }))
    }

    /// A refusal from the host a credentialed request was redirected to is a
    /// refusal of the stripped copy, and says nothing about the credential.
    func testARefusalFromAnotherOriginIsNotAnAnswerToTheCredential() throws {
        let request = Self.credentialed(try XCTUnwrap(URL(string: "https://claude.ai/api/usage")))
        for status in [401, 403] {
            XCTAssertEqual(
                SissyHTTP.leftItsOrigin(
                    try Self.reply(status, from: "https://sso.example.net/login"),
                    answering: request),
                SissyHTTP.LeftItsOrigin(status: status))
        }
    }

    func testARefusalFromTheOriginItselfIsTheVendorsAnswer() throws {
        let request = Self.credentialed(try XCTUnwrap(URL(string: "https://claude.ai/api/usage")))
        XCTAssertNil(
            SissyHTTP.leftItsOrigin(
                try Self.reply(401, from: "https://claude.ai/api/usage"), answering: request))
    }

    /// A request carrying no credential lost nothing on the way, so wherever
    /// it was answered from is its answer.
    func testAnUncredentialedRequestMayBeAnsweredFromAnotherOrigin() throws {
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://raw.example.com/a.json")))
        XCTAssertNil(
            SissyHTTP.leftItsOrigin(
                try Self.reply(200, from: "https://cdn.example.net/a.json"), answering: request))
    }

    /// The redirect the session would not follow reaches the caller as the
    /// `3xx` itself, which is no more the vendor's verdict than a refusal
    /// from the other host would be.
    func testARedirectOffTheOriginThatWasNotFollowedIsReported() throws {
        var posted = URLRequest(url: try XCTUnwrap(URL(string: "https://auth.openai.com/oauth/token")))
        posted.httpMethod = "POST"
        XCTAssertEqual(
            SissyHTTP.leftItsOrigin(
                try Self.reply(
                    307, from: "https://auth.openai.com/oauth/token",
                    location: "https://elsewhere.example.net/oauth/token"),
                answering: posted),
            SissyHTTP.LeftItsOrigin(status: 307))
    }

    func testARedirectOnTheOriginIsNotADeparture() throws {
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://auth.openai.com/oauth/token")))
        XCTAssertNil(
            SissyHTTP.leftItsOrigin(
                try Self.reply(302, from: "https://auth.openai.com/oauth/token", location: "/v2/token"),
                answering: request))
    }

    /// End to end through a session carrying the real delegate: a
    /// credentialed request redirected off its origin and refused there
    /// throws rather than handing the caller a `401` it would read as the
    /// vendor's.
    func testAnAuthenticatedRequestRefusedAfterARedirectOffItsOriginThrows() async throws {
        let configuration = SissyHTTP.configuration()
        configuration.protocolClasses = [OffOriginStub.self]
        let session = URLSession(
            configuration: configuration, delegate: SissyHTTP.RedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let request = Self.credentialed(try XCTUnwrap(URL(string: OffOriginStub.origin)))
        do {
            _ = try await SissyHTTP.data(for: request, through: session)
            XCTFail("a refusal from another origin reached the caller as the vendor's")
        } catch let departure as SissyHTTP.LeftItsOrigin {
            XCTAssertEqual(departure, SissyHTTP.LeftItsOrigin(status: OffOriginStub.refusal))
        }
    }

    private static func credentialed(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer token", forHTTPHeaderField: "Authorization")
        request.setValue("sessionKey=value", forHTTPHeaderField: "Cookie")
        request.setValue("token", forHTTPHeaderField: "PRIVATE-TOKEN")
        request.setValue("workspace", forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

/// A vendor that sends every request to another host, which refuses it.
private final class OffOriginStub: URLProtocol, @unchecked Sendable {
    static let origin = "https://vendor.example.com/api/usage"
    static let elsewhere = "https://sso.example.net/login"
    static let refusal = 401
    private static let redirect = 302

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let target = URL(string: Self.elsewhere) else { return }
        let onTarget = SissyHTTP.sameOrigin(url, target)
        guard
            let answer = HTTPURLResponse(
                url: url, statusCode: onTarget ? Self.refusal : Self.redirect, httpVersion: nil,
                headerFields: onTarget ? nil : ["Location": Self.elsewhere])
        else { return }
        if onTarget {
            client?.urlProtocol(self, didReceive: answer, cacheStoragePolicy: .notAllowed)
        } else {
            var next = request
            next.url = target
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: answer)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
