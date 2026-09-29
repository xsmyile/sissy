import XCTest

@testable import Sissy

final class UsageRequestErrorTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = SissyHTTP.configuration()
        configuration.protocolClasses = [CannedReply.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    func testA429CarriesTheVendorsWait() async throws {
        do {
            _ = try await UsageRequestError.object(
                answering: try request(CannedReply.rateLimited), through: session)
            XCTFail("a 429 reached the caller as a reading")
        } catch UsageRequestError.rateLimited(let retryAfter) {
            XCTAssertEqual(retryAfter, CannedReply.retryAfter)
        }
    }

    func testABodyThatIsNotJSONIsAMalformedReply() async throws {
        do {
            _ = try await UsageRequestError.object(
                answering: try request(CannedReply.notJSON), through: session)
            XCTFail("a body that is not JSON reached the caller as a reading")
        } catch UsageRequestError.malformedPayload {}
    }

    func testAnotherStatusIsItself() async throws {
        do {
            _ = try await UsageRequestError.object(
                answering: try request(CannedReply.refused), through: session)
            XCTFail("a 401 reached the caller as a reading")
        } catch UsageRequestError.badStatus(let code) {
            XCTAssertEqual(code, 401)
        }
    }

    func testAnObjectIsTheReading() async throws {
        let body = try await UsageRequestError.object(
            answering: try request(CannedReply.object), through: session)
        XCTAssertEqual(body["answer"] as? Int, 42)
    }

    private func request(_ path: String) throws -> URLRequest {
        URLRequest(url: try XCTUnwrap(URL(string: CannedReply.origin + path)))
    }
}

/// A vendor answering each path with one fixed reply.
private final class CannedReply: URLProtocol, @unchecked Sendable {
    static let origin = "https://vendor.example.com"
    static let rateLimited = "/limited"
    static let notJSON = "/html"
    static let refused = "/refused"
    static let object = "/object"
    static let retryAfter: TimeInterval = 600

    private static let replies: [String: (status: Int, headers: [String: String], body: String)] = [
        rateLimited: (429, ["Retry-After": "600"], ""),
        notJSON: (200, [:], "<html>maintenance</html>"),
        refused: (401, [:], "{}"),
        object: (200, [:], #"{"answer":42}"#),
    ]

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let reply = Self.replies[url.path],
            let answer = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)
        else { return }
        client?.urlProtocol(self, didReceive: answer, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
