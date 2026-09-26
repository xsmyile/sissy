import WebKit
import XCTest

@testable import Sissy

/// What the login window does with a page that asks for a second window.
///
/// An identity provider's sign-in often opens one, through `window.open` or a
/// link aimed at a new tab, and hands its result back to the page through
/// `window.opener`. So a popup is a web view of its own over the page, in the
/// same window, and a link off the vendor's hosts still goes to the default
/// browser.
@MainActor
final class VendorLoginPopupTests: XCTestCase {
    private static let isInternal: (String) -> Bool = { $0 == "claude.ai" }

    private func route(_ url: String?, linkActivated: Bool) -> VendorLoginWindow.PopupRoute {
        VendorLoginWindow.popupRoute(
            for: url.flatMap(URL.init(string:)), linkActivated: linkActivated,
            isInternal: Self.isInternal)
    }

    func testAScriptedPopupToAnIdentityProviderOpensOverThePage() {
        XCTAssertEqual(
            route("https://accounts.google.com/o/oauth2/v2/auth?display=popup", linkActivated: false),
            .open)
    }

    func testANewTabLinkOnTheVendorsOwnHostOpensOverThePage() {
        XCTAssertEqual(route("https://claude.ai/login/help", linkActivated: true), .open)
    }

    /// The confinement rule the navigation delegate already holds, reached by
    /// a link aimed at a new tab rather than at this one.
    func testANewTabLinkOffTheVendorsHostsGoesToTheDefaultBrowser() throws {
        let url = try XCTUnwrap(URL(string: "https://www.anthropic.com/legal/privacy"))

        XCTAssertEqual(route(url.absoluteString, linkActivated: true), .openInBrowser(url))
    }

    func testALinkToAnAddressThatIsNotAWebPageGoesToTheDefaultBrowser() throws {
        let url = try XCTUnwrap(URL(string: "mailto:support@example.com"))

        XCTAssertEqual(route(url.absoluteString, linkActivated: true), .openInBrowser(url))
    }

    /// The shape a popup sign-in takes when the page opens the window first
    /// and writes into it or sends it somewhere afterwards.
    func testABlankPopupOpensOverThePage() {
        XCTAssertEqual(route("about:blank", linkActivated: false), .open)
        XCTAssertEqual(route(nil, linkActivated: false), .open)
    }

    /// The whole reason a popup is a web view of its own: the page that
    /// opened it is its opener, and what the popup posts there arrives.
    func testAPopupHandsItsResultToThePageThatOpenedIt() async {
        let arrived = expectation(description: "the popup's result reaches the page")
        var result: String?
        let harness = PopupHarness { body in
            result = body as? String
            arrived.fulfill()
        }
        harness.page.loadHTMLString(Self.openingPage(popupScript: Self.postingScript), baseURL: Self.origin)

        await fulfillment(of: [arrived], timeout: Self.pageTimeout)

        XCTAssertEqual(result, Self.popupResult)
        XCTAssertEqual(harness.popups.open.count, 1)
        harness.tearDown()
    }

    /// A popup that has finished closes itself, and the page is what is left.
    func testAPopupThatClosesItselfLeavesThePage() async {
        let closed = expectation(description: "the popup closed")
        let harness = PopupHarness { _ in }
        harness.onClose = { closed.fulfill() }
        harness.page.loadHTMLString(
            Self.openingPage(popupScript: Self.postingScript + Self.closingScript), baseURL: Self.origin)

        await fulfillment(of: [closed], timeout: Self.pageTimeout)

        XCTAssertTrue(harness.popups.open.isEmpty)
        XCTAssertEqual(harness.popups.view.subviews, [harness.page])
        harness.tearDown()
    }

    func testDismissingAWebViewThatIsNotAPopupLeavesThePage() {
        let harness = PopupHarness { _ in }

        XCTAssertFalse(harness.popups.dismiss(harness.page))
        XCTAssertEqual(harness.popups.view.subviews, [harness.page])
        harness.tearDown()
    }

    /// A page that opens a blank popup and writes the popup's script into
    /// it, which runs as the popup and posts to `window.opener`. The page
    /// relays whatever reaches it to the test.
    private static func openingPage(popupScript: String) -> String {
        """
        <html><body><script>
        window.addEventListener("message", (event) => {
            window.webkit.messageHandlers.\(PopupHarness.message).postMessage(event.data);
        });
        const popup = window.open("", "sissyTestPopup");
        popup.document.write("<script>\(popupScript)<\\/script>");
        popup.document.close();
        </script></body></html>
        """
    }

    private static let popupResult = "signed in"
    private static let postingScript = "window.opener.postMessage('\(popupResult)', '*');"
    private static let closingScript = "window.close();"
    private static let origin = URL(string: "https://claude.ai")
    private static let pageTimeout: TimeInterval = 10
}

/// A page and its popups, answered the way the login window answers them.
@MainActor
private final class PopupHarness: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    static let message = "sissyTestPopupResult"

    let page: WKWebView
    let popups: VendorLoginPopups
    var onClose: () -> Void = {}
    private let onResult: (Any) -> Void

    init(onResult: @escaping (Any) -> Void) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        page = WKWebView(frame: .zero, configuration: configuration)
        popups = VendorLoginPopups(page: page)
        self.onResult = onResult
        super.init()
        page.uiDelegate = self
        page.navigationDelegate = self
        configuration.userContentController.add(self, name: Self.message)
    }

    func tearDown() {
        popups.dismissAll()
        page.configuration.userContentController.removeScriptMessageHandler(forName: Self.message)
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        popups.present(configuration: configuration, delegate: self)
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard popups.dismiss(webView) else { return }
        onClose()
    }

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.message else { return }
        onResult(message.body)
    }
}
