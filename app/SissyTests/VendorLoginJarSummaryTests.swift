import XCTest

@testable import Sissy

/// What the login window logs about a sign-in that closed without a session:
/// enough to tell a jar with no session cookie from one whose cookie went
/// unnoticed, and nothing a log must not hold.
final class VendorLoginJarSummaryTests: XCTestCase {
    func testTheJarIsSummarisedByNameAndDomainAndNeverByValue() throws {
        let session = try Self.cookie(name: "sessionKey", value: Self.secret, domain: ".claude.ai")
        let marker = try Self.cookie(name: "lastActiveOrg", value: "org", domain: "claude.ai")

        let summary = VendorLoginWindow.jarSummary([session, marker, session])

        XCTAssertEqual(summary, "lastActiveOrg@claude.ai, sessionKey@.claude.ai")
        XCTAssertFalse(summary.contains(Self.secret))
    }

    func testAnEmptyJarSaysSo() {
        XCTAssertEqual(VendorLoginWindow.jarSummary([]), "no cookies")
    }

    func testAPageIsSummarisedByHostAndItsFirstStepAlone() throws {
        let url = try XCTUnwrap(URL(string: "https://claude.ai/magic-link/abc?code=123#nonce"))

        XCTAssertEqual(VendorLoginWindow.pageSummary(url), "claude.ai/magic-link")
    }

    func testThePageAtTheRootIsItsHost() throws {
        let url = try XCTUnwrap(URL(string: "https://claude.ai/?code=123"))

        XCTAssertEqual(VendorLoginWindow.pageSummary(url), "claude.ai")
    }

    private static func cookie(name: String, value: String, domain: String) throws -> HTTPCookie {
        try XCTUnwrap(
            HTTPCookie(properties: [
                .name: name, .value: value, .domain: domain, .path: "/",
            ]))
    }

    private static let secret = "sk-ant-sid01-not-a-real-session"
}
