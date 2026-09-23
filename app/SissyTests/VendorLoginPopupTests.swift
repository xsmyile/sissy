import WebKit
import XCTest

@testable import Sissy

/// What the login window does with a page that asks for a second window.
///
/// An identity provider's sign-in often opens one, through `window.open` or a
/// link aimed at a new tab. A web view with no UI delegate drops that request
/// without a word, which is a button that does nothing on the one account the
/// user came to add. The window has no second window to give, so a popup is
/// loaded in place, a link off the vendor's hosts still goes to the default
/// browser, and a popup with nothing to load is said to be a dead end.
@MainActor
final class VendorLoginPopupTests: XCTestCase {
    private static let isInternal: (String) -> Bool = { $0 == "claude.ai" }

    private func route(_ url: String?, linkActivated: Bool) -> VendorLoginWindow.PopupRoute {
        VendorLoginWindow.popupRoute(
            for: url.flatMap(URL.init(string:)), linkActivated: linkActivated,
            isInternal: Self.isInternal)
    }

    func testAScriptedPopupToAnIdentityProviderLoadsInPlace() {
        XCTAssertEqual(
            route("https://appleid.apple.com/auth/authorize?client_id=x", linkActivated: false),
            .load)
    }

    func testANewTabLinkOnTheVendorsOwnHostLoadsInPlace() {
        XCTAssertEqual(route("https://claude.ai/login/help", linkActivated: true), .load)
    }

    /// The confinement rule the navigation delegate already holds, reached by
    /// a link aimed at a new tab rather than at this one.
    func testANewTabLinkOffTheVendorsHostsGoesToTheDefaultBrowser() throws {
        let url = try XCTUnwrap(URL(string: "https://www.anthropic.com/legal/privacy"))

        XCTAssertEqual(route(url.absoluteString, linkActivated: true), .openInBrowser(url))
    }

    func testAPopupWithNoAddressCannotBeFollowed() {
        XCTAssertEqual(route(nil, linkActivated: false), .cannotFollow)
    }

    /// The shape a popup sign-in takes when the opener writes into the window
    /// after opening it, which needs the window to exist.
    func testABlankPopupCannotBeFollowed() {
        XCTAssertEqual(route("about:blank", linkActivated: false), .cannotFollow)
    }

    /// A popup loaded in place has no opener to hand its result to, and
    /// WebKit ignores its `close()` on a web view Sissy opened and a redirect
    /// chain has since walked, so the watch is what hears it.
    func testAPageThatClosesItselfWithNoOpenerIsHeard() async {
        let heard = expectation(description: "the orphaned close is reported")
        let recorder = OrphanedCloseRecorder { heard.fulfill() }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let contentController = configuration.userContentController
        VendorLoginWindow.watchOrphanedClose(in: contentController, handler: recorder)
        let web = WKWebView(frame: .zero, configuration: configuration)
        let page = Self.selfClosingPage
        web.loadHTMLString(page, baseURL: nil)

        await fulfillment(of: [heard], timeout: Self.pageTimeout)

        VendorLoginWindow.stopWatchingOrphanedClose(in: contentController)
    }

    private static let selfClosingPage = "<html><body><script>window.close()</script></body></html>"
    private static let pageTimeout: TimeInterval = 10
}

/// Hears the login window's orphaned-close message and nothing else.
@MainActor
private final class OrphanedCloseRecorder: NSObject, WKScriptMessageHandler {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard message.name == VendorLoginWindow.orphanedCloseMessage else { return }
        onClose()
    }
}
