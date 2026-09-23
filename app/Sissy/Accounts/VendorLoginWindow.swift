import AppKit
import SwiftUI
import WebKit

/// The one window Sissy opens, and the only thing it can do is link an
/// account.
///
/// It is a deliberate exception to "three surfaces and none of them is a
/// window": a credential cannot be obtained without the vendor's own login,
/// and both vendors refuse anything that is not a real browser — claude.ai
/// answers 403, and `auth.openai.com` puts a Cloudflare challenge in front of
/// the form (measured 2026-09-16 and 2026-09-17). What keeps the exception
/// from growing into a browser is that there is nothing to browse with. One
/// window, one starting URL, no address bar, no tabs, no history controls.
///
/// **One window for both vendors, because the difference is one line.** Claude
/// signs in and leaves a cookie in the jar; Codex signs in and is redirected
/// to a URL carrying an authorization code. Everything else — the guardrail,
/// the reachability, the question afterwards, the failure — is the same
/// window, and two copies of it would be two places for that guardrail to
/// drift.
///
/// Link clicks that leave the vendor's own hosts — terms, privacy, help — are
/// handed to the default browser rather than followed here, which is what
/// "confined to the vendor" means in practice: there is no way to reach
/// another site by hand. Redirects are followed, because a sign-in is a
/// redirect chain the vendor owns and a host allowlist would be a guess: the
/// login pages cannot be read from outside, so which identity providers they
/// offer is unknown, and a wrong list is a window that dead-ends on the one
/// account the user came to add.
///
/// **A page that asks for a second window gets this one.** Identity
/// providers sign in through `window.open` or a link aimed at a new tab, and a
/// web view with no UI delegate drops that request without a word: a button
/// that does nothing, on the one account the user came to add. So the popup is
/// loaded in place, under the same rules as any other navigation here, and a
/// popup this window cannot follow (one with nothing to load, or a page that
/// closes itself because it expected an opener) ends the sign-in with a
/// sentence saying so rather than a blank page. Whether a given provider then
/// completes is the provider's to decide and has to be measured per provider.
///
/// The cookie jar is non-persistent, so it exists for the life of the window
/// and no longer. That is what makes a second link a fresh login rather than a
/// silent re-link of the account already there.
///
/// **The whole link happens here, not only its first step.** The window stays
/// up past the credential, because what follows can need the user: an account
/// with more than one organisation or workspace has to be asked which, and a
/// credential the vendor will not answer for has to say so somewhere the
/// person who just typed a code is looking. Closing on the credential and
/// finishing in Settings put the rest of the flow on a surface they had no
/// reason to open.
///
/// **It stays reachable.** Sissy is `LSUIElement`, so it has no Dock icon and
/// no ⌘-Tab entry, and an email-code login *requires* leaving the window to go
/// and read the code. A window that only goes behind is a window that is gone:
/// measured 2026-09-16 on the dev build, that is exactly what happened. So it
/// floats above other apps, which is also what lets a code be copied from a
/// mail window into it, and the activation policy goes to `.regular` while it
/// is up so the Dock and ⌘-Tab can bring it back.
///
/// **The way back down is not this window's to take.** Dropping to
/// `.accessory` on close hands activation to whatever app is behind, which is
/// what should happen when this was the only window and not when Settings is
/// still open: the login opens from a row in Settings, so closing it sent the
/// window the user came from behind another app — still open, no longer in
/// front, and with the Dock icon back a moment later because the window list
/// says it should be. Observed 2026-09-18 on the dev build.
/// `AppDelegate.syncActivationPolicy` already asks that question against every
/// window the app has, which this one cannot see, so the demotion is left to
/// it. The promotion stays here because it has to happen before the activation
/// it is for.
/// The one question a link cannot answer for itself, in the vendor's own
/// vocabulary: an organisation for Claude, a workspace for Codex.
struct VendorLoginQuestion {
    let title: String
    let caption: String
    let options: [Option]

    struct Option: Identifiable {
        let id: String
        let label: String
    }
}

@MainActor
final class VendorLoginWindow: NSObject {
    /// What this window signs into, and how it recognises that it has.
    ///
    /// Exactly one of `session` and `code` answers for a vendor: a cookie the
    /// jar receives, or a redirect the page attempts. Both are closures rather
    /// than cases because what they recognise is the vendor's business and the
    /// window's job is only to notice it.
    struct Vendor: Sendable {
        let title: String
        /// How the log names this vendor's sign-in.
        let logName: String
        let startURL: URL
        /// Whether a host is part of this vendor's own sign-in.
        let isInternal: @Sendable (String) -> Bool
        /// The credential a cookie jar has come to carry, if this vendor ends
        /// its sign-in that way.
        let session: (@Sendable ([HTTPCookie]) -> String?)?
        /// The credential a navigation carries, if this vendor ends its
        /// sign-in with a redirect.
        let code: (@Sendable (URL) -> String?)?
        /// Why a navigation ends the sign-in without a credential, if this
        /// vendor ends it with a redirect: the same redirect carrying an error
        /// where the code would be.
        let declined: (@Sendable (URL) -> String?)?
    }

    /// Why the page itself ended the sign-in, as the caller words it.
    enum PageFailure: Equatable {
        /// The vendor's redirect said no, in its own OAuth error code.
        case declined(String)
        /// A page of the sign-in did not load.
        case unreachable
        /// The sign-in needed a second window, which this one cannot give.
        case needsSecondWindow
    }

    /// What a request for a new window becomes, in a window that has only
    /// the one.
    enum PopupRoute: Equatable {
        /// Load the request in this window's web view.
        case load
        /// A link off the vendor's own hosts, handed to the default browser
        /// as the navigation delegate hands every other one.
        case openInBrowser(URL)
        /// Nothing this window can load: the opener meant to write into the
        /// window it asked for, and there is none.
        case cannotFollow
    }

    nonisolated private static let webSchemes: Set<String> = ["http", "https"]

    /// The script message a page posts when it closes itself with no opener
    /// to hand its result to.
    nonisolated static let orphanedCloseMessage = "sissyOrphanedClose"

    /// Wraps `window.close` so a page with no opener says so before closing.
    ///
    /// A popup loaded in place posts its result to `window.opener` and then
    /// closes itself. WebKit honours that close only on a window a script
    /// opened or one with a single history entry, and this web view is
    /// neither by the time a popup reaches it, so `webViewDidClose` alone
    /// would leave the user on a page that stopped without a word.
    nonisolated private static let orphanedCloseScript = """
        (() => {
            const close = window.close.bind(window);
            window.close = function () {
                if (window.opener === null) {
                    window.webkit.messageHandlers.\(orphanedCloseMessage).postMessage(null);
                }
                return close();
            };
        })();
        """

    /// WebKit's code for a load it abandoned because the navigation delegate
    /// cancelled it, which is every redirect this window takes a code from.
    nonisolated static let frameLoadInterruptedByPolicyChange = 102
    nonisolated private static let webKitErrorDomain = "WebKitErrorDomain"

    private static let contentSize = NSSize(width: 520, height: 680)
    private static let promptSize = NSSize(width: 420, height: 260)

    private let vendor: Vendor
    private var window: NSWindow?
    private var webView: WKWebView?
    private var cookieStore: WKHTTPCookieStore?
    /// Called with the credential the login produced. The window stays up:
    /// what the caller does next may need this window again.
    private var onCredential: ((String) -> Void)?
    /// Called once when the window goes away without the flow completing.
    private var onCancel: (() -> Void)?
    /// Called when the page ends the sign-in before any credential, so the
    /// caller can say why and offer the login again.
    private var onFailure: ((PageFailure) -> Void)?
    private var finished = false
    /// Whether a popup has been loaded in place. Only then does a page
    /// closing itself with no opener mean a sign-in that cannot finish.
    private var popupLoadedInPlace = false

    init(vendor: Vendor) {
        self.vendor = vendor
    }

    /// Whether the window is still up. A controller whose window has closed
    /// is spent: its callbacks are consumed, and the next link needs a new one.
    var isOpen: Bool { window != nil }

    /// Opens the window. Called once per controller.
    func present(
        onCredential: @escaping (String) -> Void,
        onFailure: @escaping (PageFailure) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onCredential = onCredential
        self.onFailure = onFailure
        self.onCancel = onCancel

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Self.watchOrphanedClose(in: configuration.userContentController, handler: self)
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        web.uiDelegate = self
        webView = web

        if vendor.session != nil {
            let store = configuration.websiteDataStore.httpCookieStore
            store.add(self)
            cookieStore = store
        }

        let panel = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        panel.title = vendor.title
        panel.contentView = web
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.level = .floating
        panel.center()
        window = panel

        web.load(URLRequest(url: vendor.startURL))
        NSApp.setActivationPolicy(.regular)
        bringToFront()
        sissyLog("sissy: opened the \(vendor.logName) login")
    }

    /// Asks the question the link could not answer, in the window the
    /// credential was just obtained in.
    func ask(_ question: VendorLoginQuestion, onPick: @escaping (String) -> Void) {
        sissyLog(
            "sissy: the \(vendor.logName) login is asking which of \(question.options.count) to link")
        swap(
            to: VendorLinkQuestionView(
                question: question,
                onPick: { [weak self] choice in
                    self?.working()
                    onPick(choice)
                },
                onCancel: { [weak self] in self?.close() }),
            size: Self.promptSize)
    }

    /// Says what went wrong, here rather than on a surface nobody opened, and
    /// offers the only thing that can help: the login again.
    func report(_ message: String, onRetry: @escaping () -> Void) {
        swap(
            to: VendorLinkFailureView(
                message: message,
                onRetry: { [weak self] in
                    self?.close()
                    onRetry()
                },
                onCancel: { [weak self] in self?.close() }),
            size: Self.promptSize)
    }

    /// Says what the link did when it is worth saying, and closes as a
    /// completed link on Done, or on the window's own close button.
    func inform(title: String, message: String, onDone: @escaping () -> Void) {
        finished = true
        swap(
            to: VendorLinkNoticeView(
                title: title,
                message: message,
                onDone: { [weak self] in
                    self?.close()
                    onDone()
                }),
            size: Self.promptSize)
    }

    /// Says the credential is in hand while the caller resolves it.
    func working() {
        swap(to: VendorLinkProgressView(), size: Self.promptSize)
    }

    /// Takes the window down on a link that completed. `onCancel` is consumed
    /// first, so the close this causes is not reported as one.
    func finish() {
        finished = true
        sissyLog("sissy: the \(vendor.logName) login completed")
        close()
    }

    /// Brings the open window forward. The control that opens it is the only
    /// way back to a window that has gone behind, so a second press has to
    /// mean "show me the one I already have".
    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Closes the window, which is reported to the caller as a cancel unless
    /// `finish()` came first. The window's own Cancel and Retry come through
    /// here, and they are cancels: marking them finished left the caller
    /// holding a controller whose window was gone, which the next link then
    /// re-presented with nothing listening for its credential.
    private func close() {
        window?.close()
    }

    private func swap(to content: some View, size: NSSize) {
        releaseWeb()
        guard let window else { return }
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        let fitted = NSHostingController(rootView: content).sizeThatFits(
            in: NSSize(width: size.width, height: .greatestFiniteMagnitude))
        window.contentView = host
        window.setContentSize(NSSize(width: size.width, height: max(size.height, fitted.height)))
        window.center()
        bringToFront()
    }

    /// Drops the web view and its cookie jar as soon as the login is over.
    ///
    /// The credential is in the caller's hands by then, so a live jar holding
    /// a second copy of it buys nothing and keeps a vendor session in memory
    /// for the length of a question.
    private func releaseWeb() {
        cookieStore?.remove(self)
        cookieStore = nil
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        if let contentController = webView?.configuration.userContentController {
            Self.stopWatchingOrphanedClose(in: contentController)
        }
        webView?.stopLoading()
        webView = nil
    }

    /// Hands the credential over exactly once. The copies that follow a
    /// successful login — further cookies, a retried redirect — have nothing
    /// left to deliver.
    private func deliver(_ credential: String) {
        guard let pending = onCredential else { return }
        onCredential = nil
        onFailure = nil
        sissyLog("sissy: the \(vendor.logName) login produced a credential")
        working()
        pending(credential)
    }

    /// Hands a page failure over once, and only while no credential has been:
    /// after one, the web view is gone and the flow is the caller's.
    private func fail(_ failure: PageFailure) {
        guard onCredential != nil, let pending = onFailure else { return }
        onCredential = nil
        onFailure = nil
        sissyLog("sissy: the \(vendor.logName) login page ended the sign-in")
        pending(failure)
    }

    /// What a load error means for the sign-in, and nil for the errors a
    /// navigation this window cancelled reports on its way out: the code
    /// redirect, the decline and every link handed to the default browser.
    nonisolated static func pageFailure(for error: Error) -> PageFailure? {
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain, failure.code == NSURLErrorCancelled { return nil }
        if failure.domain == webKitErrorDomain,
            failure.code == frameLoadInterruptedByPolicyChange
        {
            return nil
        }
        return .unreachable
    }

    /// Installs the orphaned-close watch on a web view's content controller.
    ///
    /// The controller holds `handler` strongly, so the watch has to be taken
    /// down with `stopWatchingOrphanedClose(in:)` for the handler to go.
    static func watchOrphanedClose(
        in contentController: WKUserContentController, handler: WKScriptMessageHandler
    ) {
        contentController.addUserScript(
            WKUserScript(
                source: orphanedCloseScript, injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
        contentController.add(handler, name: orphanedCloseMessage)
    }

    /// Takes down what `watchOrphanedClose(in:handler:)` installed.
    static func stopWatchingOrphanedClose(in contentController: WKUserContentController) {
        contentController.removeScriptMessageHandler(forName: orphanedCloseMessage)
        contentController.removeAllUserScripts()
    }

    /// Where a request for a new window goes. A link aimed at a new tab obeys
    /// the confinement rule a link aimed at this one does; anything else with
    /// a web address is loaded in place, because a sign-in's popup belongs to
    /// a provider whose hosts cannot be listed in advance.
    nonisolated static func popupRoute(
        for url: URL?, linkActivated: Bool, isInternal: (String) -> Bool
    ) -> PopupRoute {
        guard let url, let scheme = url.scheme?.lowercased() else { return .cannotFollow }
        guard webSchemes.contains(scheme), let host = url.host() else {
            return linkActivated ? .openInBrowser(url) : .cannotFollow
        }
        if linkActivated, !isInternal(host) { return .openInBrowser(url) }
        return .load
    }
}

extension VendorLoginWindow: WKHTTPCookieStoreObserver {
    /// Fires for every cookie the site sets, so the hand-off is consumed
    /// rather than guarded.
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in
            guard onCredential != nil, let session = vendor.session else { return }
            let cookies = await cookieStore.allCookies()
            guard let found = session(cookies) else { return }
            deliver(found)
        }
    }
}

extension VendorLoginWindow: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }
        // The redirect that carries a code is cancelled rather than followed:
        // nothing is listening on the loopback port it names, and the code is
        // already in the URL. That is what keeps Sissy from binding a port for
        // the length of a login.
        //
        // Handed over on the next turn rather than here, because taking the
        // credential swaps the window's content and drops the web view — and
        // this is that web view's own delegate callback, which has still to
        // return a policy to it.
        if let code = vendor.code?(url) {
            Task { @MainActor [weak self] in self?.deliver(code) }
            return .cancel
        }
        if let reason = vendor.declined?(url) {
            Task { @MainActor [weak self] in self?.fail(.declined(reason)) }
            return .cancel
        }
        guard navigationAction.navigationType == .linkActivated,
            let host = url.host(),
            !vendor.isInternal(host)
        else { return .allow }
        NSWorkspace.shared.open(url)
        return .cancel
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        guard let failure = Self.pageFailure(for: error) else { return }
        Task { @MainActor [weak self] in self?.fail(failure) }
    }

    func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error
    ) {
        guard let failure = Self.pageFailure(for: error) else { return }
        Task { @MainActor [weak self] in self?.fail(failure) }
    }
}

extension VendorLoginWindow: WKUIDelegate {
    /// Answers every request for a new window with this one, and never hands
    /// WebKit a second web view: there is no second window to put it in.
    ///
    /// The failure is handed over on the next turn for the reason the
    /// navigation delegate's are: reporting it drops the web view whose own
    /// callback this is.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let route = Self.popupRoute(
            for: navigationAction.request.url,
            linkActivated: navigationAction.navigationType == .linkActivated,
            isInternal: vendor.isInternal)
        switch route {
        case .load:
            sissyLog("sissy: the \(vendor.logName) login opened a popup, loaded in place")
            popupLoadedInPlace = true
            webView.load(navigationAction.request)
        case .openInBrowser(let url):
            NSWorkspace.shared.open(url)
        case .cannotFollow:
            sissyLog("sissy: the \(vendor.logName) login asked for a window it cannot have")
            Task { @MainActor [weak self] in self?.fail(.needsSecondWindow) }
        }
        return nil
    }

    /// A page that closes its own window is a popup that has finished and
    /// expected an opener to hand its result to. Loaded in place, it has
    /// none, so the sign-in cannot complete from here. WebKit seldom lets
    /// this web view close, which is why the orphaned-close watch exists.
    func webViewDidClose(_ webView: WKWebView) {
        Task { @MainActor [weak self] in self?.fail(.needsSecondWindow) }
    }
}

extension VendorLoginWindow: WKScriptMessageHandler {
    /// A page closed itself with no opener. After a popup was loaded in
    /// place that is the popup finishing into a window that is not there, so
    /// the sign-in ends with the sentence `webViewDidClose` would have given.
    /// Before one, it is a page of the vendor's own and says nothing.
    ///
    /// The message body is the page's and is never read.
    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.orphanedCloseMessage, popupLoadedInPlace else { return }
        sissyLog("sissy: the \(vendor.logName) login popup closed with no window to report to")
        Task { @MainActor [weak self] in self?.fail(.needsSecondWindow) }
    }
}

extension VendorLoginWindow: NSWindowDelegate {
    /// Takes the window's own state down and nothing else: the activation
    /// policy belongs to `AppDelegate.syncActivationPolicy`, which sees the
    /// rest of the app's windows and this does not.
    ///
    /// Synchronous, because a Retry closes this window and starts the next
    /// link on the same turn: the caller has to have heard the cancel before
    /// it decides whether a login is still open.
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            releaseWeb()
            window?.delegate = nil
            window = nil
            let cancelled = onCancel
            onCredential = nil
            onFailure = nil
            onCancel = nil
            guard !finished else { return }
            sissyLog("sissy: the \(vendor.logName) login was closed before it completed")
            cancelled?()
        }
    }
}

extension VendorLoginWindow.Vendor {
    /// claude.ai's login, which ends in a `sessionKey` cookie.
    static var claude: Self {
        Self(
            title: "Add Claude account",
            logName: "claude.ai",
            startURL: URL(string: "https://claude.ai/login")!,
            isInternal: { isHost($0, in: "claude.ai") },
            session: { cookies in
                cookies.first {
                    $0.name == ClaudeWebSessionStore.cookieName
                        && isHost($0.domain, in: "claude.ai")
                        && !$0.value.isEmpty
                }?.value
            },
            code: nil,
            declined: nil)
    }

    /// OpenAI's login, which ends in a redirect to the CLI's loopback address
    /// carrying an authorization code.
    static func codex(flow: CodexOAuth.Flow) -> Self {
        Self(
            title: "Add Codex account",
            logName: "OpenAI",
            startURL: flow.url,
            isInternal: { host in
                isHost(host, in: "openai.com") || isHost(host, in: "chatgpt.com")
            },
            session: nil,
            code: { flow.code(fromRedirect: $0) },
            declined: { flow.declined(fromRedirect: $0) })
    }

    /// A host that is the vendor's or a subdomain of it, and nothing that
    /// merely ends in those characters. One spelling of the rule, because two
    /// is how they come to disagree: this was `hasSuffix(host)` on the Claude
    /// cookie, which a host called `notclaude.ai` satisfies.
    private static func isHost(_ host: String, in domain: String) -> Bool {
        host == domain || host.hasSuffix(".\(domain)")
    }
}

/// The one question a link cannot answer for itself, asked in the window the
/// credential was obtained in.
private struct VendorLinkQuestionView: View {
    let question: VendorLoginQuestion
    let onPick: (String) -> Void
    let onCancel: () -> Void

    /// Nothing is selected to begin with, so linking is a choice someone made
    /// rather than the first row happening to be selected — which is the whole
    /// reason the question is asked instead of derived.
    @State private var picked: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question.title)
                .font(.headline)
            Text(question.caption)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("", selection: Binding(get: { picked ?? "" }, set: { picked = $0 })) {
                ForEach(question.options) { option in
                    Text(option.label).tag(option.id)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(ClaudeAccountLinkCopy.cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(ClaudeAccountLinkCopy.link) {
                    guard let picked else { return }
                    onPick(picked)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked == nil)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct VendorLinkProgressView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(ClaudeAccountLinkCopy.working)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What the link did, when the user was not asked and could not tell.
private struct VendorLinkNoticeView: View {
    let title: String
    let message: String
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(ClaudeAccountLinkCopy.done, action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct VendorLinkFailureView: View {
    let message: String
    let onRetry: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ClaudeAccountLinkCopy.failureTitle)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(ClaudeAccountLinkCopy.cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(ClaudeAccountLinkCopy.retry, action: onRetry)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
