import WebKit
import XCTest

@testable import Sissy

/// What the login window does when WebKit kills the process drawing its page.
///
/// No load error follows a killed content process: the view goes white, and
/// before this the window stayed that way with no way forward but closing it.
@MainActor
final class VendorLoginContentProcessTests: XCTestCase {
    /// A web view that is not one of the window's popups answers as its
    /// page. Reported once however many times WebKit says so, because the
    /// expectation fails on a second fulfilment.
    func testAKilledPageEndsTheSignInOnce() async throws {
        let ended = expectation(description: "the sign-in ended")
        var failure: VendorLoginWindow.PageFailure?
        let login = VendorLoginWindow(vendor: try Self.vendor())
        login.present(
            onCredential: { _ in },
            onFailure: { reported in
                failure = reported
                ended.fulfill()
            },
            onCancel: {})
        addTeardownBlock { @MainActor in login.finish() }
        let page = WKWebView()

        login.webViewWebContentProcessDidTerminate(page)
        login.webViewWebContentProcessDidTerminate(page)

        await fulfillment(of: [ended], timeout: Self.timeout)
        await Task.yield()
        XCTAssertEqual(failure, .terminated)
    }

    private static func vendor() throws -> VendorLoginWindow.Vendor {
        VendorLoginWindow.Vendor(
            title: "Test login",
            logName: "test",
            startURL: try XCTUnwrap(URL(string: "about:blank")),
            isInternal: { _ in false },
            session: nil,
            code: nil,
            declined: nil)
    }

    private static let timeout: TimeInterval = 5
}
