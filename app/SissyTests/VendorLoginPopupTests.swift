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

    /// A popup's completion writes to its opener before it closes. With no
    /// opener that write throws and the close never runs, so the error is
    /// what reports, and the close after it adds nothing. The sentinel is a
    /// later script of the same page, posted after both, so a second report
    /// would have arrived before it.
    func testAPopupThatPostsToAMissingOpenerIsHeardOnce() async {
        let heard = expectation(description: "the orphaned completion is reported")
        let pageDone = expectation(description: "the page ran to its last script")
        let recorder = OrphanedCloseRecorder { heard.fulfill() }
        let sentinel = PageDoneRecorder { _ in pageDone.fulfill() }
        let (web, contentController) = Self.poppedUpWebView(recorder: recorder, sentinel: sentinel)
        web.loadHTMLString(Self.openerCompletionPage, baseURL: Self.popupOrigin)

        await fulfillment(of: [heard, pageDone], timeout: Self.pageTimeout, enforceOrder: true)

        Self.tearDown(contentController)
    }

    /// A completion written from inside an async function throws into a
    /// rejected promise rather than an error event, and is heard all the
    /// same.
    func testAPopupThatPostsToAMissingOpenerFromAnAsyncFunctionIsHeard() async {
        let heard = expectation(description: "the orphaned completion is reported")
        let recorder = OrphanedCloseRecorder { heard.fulfill() }
        let sentinel = PageDoneRecorder { _ in }
        let (web, contentController) = Self.poppedUpWebView(recorder: recorder, sentinel: sentinel)
        web.loadHTMLString(Self.asyncOpenerCompletionPage, baseURL: Self.popupOrigin)

        await fulfillment(of: [heard], timeout: Self.pageTimeout)

        Self.tearDown(contentController)
    }

    /// A page with no opener that fails on some other null is not a
    /// completion that lost its opener, even when the property it read
    /// starts with the word.
    func testAnUnrelatedNullErrorOnAPopupIsNotHeard() async {
        let heard = expectation(description: "no orphaned completion is reported")
        heard.isInverted = true
        let pageDone = expectation(description: "the page ran to its last script")
        let recorder = OrphanedCloseRecorder { heard.fulfill() }
        let sentinel = PageDoneRecorder { _ in pageDone.fulfill() }
        let (web, contentController) = Self.poppedUpWebView(recorder: recorder, sentinel: sentinel)
        web.loadHTMLString(Self.unrelatedNullErrorPage, baseURL: Self.popupOrigin)

        await fulfillment(of: [pageDone], timeout: Self.pageTimeout)
        await fulfillment(of: [heard], timeout: .zero)

        Self.tearDown(contentController)
    }

    /// A provider that completes by redirect when it finds no opener is not
    /// a dead end, and has to see the null opener any browser would give it.
    func testAPopupThatChecksForAnOpenerAndRedirectsIsNotHeard() async {
        let heard = expectation(description: "no orphaned completion is reported")
        heard.isInverted = true
        let pageDone = expectation(description: "the page ran to its last script")
        var sawNullOpener: Bool?
        let recorder = OrphanedCloseRecorder { heard.fulfill() }
        let sentinel = PageDoneRecorder { body in
            sawNullOpener = body as? Bool
            pageDone.fulfill()
        }
        let (web, contentController) = Self.poppedUpWebView(recorder: recorder, sentinel: sentinel)
        web.loadHTMLString(Self.openerCheckingPage, baseURL: Self.popupOrigin)

        await fulfillment(of: [pageDone], timeout: Self.pageTimeout)
        await fulfillment(of: [heard], timeout: .zero)

        XCTAssertEqual(sawNullOpener, true)
        Self.tearDown(contentController)
    }

    /// The matcher is WebKit's own wording, so the test reads it off WebKit
    /// rather than off the constant.
    func testWebKitsNullOpenerErrorCarriesTheMatchedWords() async throws {
        let web = WKWebView(frame: .zero)
        web.loadHTMLString("<html></html>", baseURL: nil)
        let message =
            try await web.callAsyncJavaScript(
                Self.nullOpenerErrorProbe, contentWorld: .page) as? String

        let text = try XCTUnwrap(message)
        XCTAssertTrue(text.contains(VendorLoginWindow.nullObjectMessage), text)
        XCTAssertTrue(text.contains(VendorLoginWindow.openerMarker), text)
    }

    private static func poppedUpWebView(
        recorder: OrphanedCloseRecorder, sentinel: PageDoneRecorder
    ) -> (WKWebView, WKUserContentController) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let contentController = configuration.userContentController
        VendorLoginWindow.watchOrphanedClose(in: contentController, handler: recorder)
        VendorLoginWindow.watchOpenerlessPopup(in: contentController)
        contentController.add(sentinel, name: PageDoneRecorder.message)
        return (WKWebView(frame: .zero, configuration: configuration), contentController)
    }

    private static func tearDown(_ contentController: WKUserContentController) {
        contentController.removeScriptMessageHandler(forName: PageDoneRecorder.message)
        VendorLoginWindow.stopWatchingOrphanedClose(in: contentController)
    }

    private static let selfClosingPage = "<html><body><script>window.close()</script></body></html>"
    private static let openerCompletionPage = """
        <html><body>
        <script>window.opener.postMessage({ code: "x" }, "*"); window.close();</script>
        <script>window.webkit.messageHandlers.\(PageDoneRecorder.message).postMessage(null);</script>
        </body></html>
        """
    private static let asyncOpenerCompletionPage = """
        <html><body>
        <script>
        (async () => { await null; window.opener.postMessage({ code: "x" }, "*"); window.close(); })();
        </script>
        </body></html>
        """
    private static let unrelatedNullErrorPage = """
        <html><body>
        <script>const config = null; config.openerMode;</script>
        <script>window.webkit.messageHandlers.\(PageDoneRecorder.message).postMessage(null);</script>
        </body></html>
        """
    private static let openerCheckingPage = """
        <html><body>
        <script>if (window.opener && !window.opener.closed) { window.opener.postMessage("x", "*"); }</script>
        <script>
        window.webkit.messageHandlers.\(PageDoneRecorder.message).postMessage(window.opener === null);
        </script>
        </body></html>
        """
    private static let nullOpenerErrorProbe = """
        try { window.opener.postMessage(1, "*"); return null; } catch (error) { return error.message; }
        """
    /// A popup is a page of an identity provider's origin. With no base URL
    /// the origin is opaque, and WebKit hands the page's own error listener
    /// `Script error.` in place of the error, as it does for any script from
    /// another origin.
    private static let popupOrigin = URL(string: "https://idp.example")
    private static let pageTimeout: TimeInterval = 10
}

/// Hears the test page's own last script, which says the page has finished
/// and hands over what it saw.
@MainActor
private final class PageDoneRecorder: NSObject, WKScriptMessageHandler {
    static let message = "sissyTestPageDone"
    private let onDone: (Any) -> Void

    init(onDone: @escaping (Any) -> Void) {
        self.onDone = onDone
    }

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.message else { return }
        onDone(message.body)
    }
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
