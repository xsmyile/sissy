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
/// **A page that asks for a second window gets one, inside this one.**
/// Identity providers sign in through `window.open` or a link aimed at a new
/// tab, and a web view with no UI delegate drops that request without a word:
/// a button that does nothing, on the one account the user came to add. The
/// popup is a web view of its own, made from the configuration WebKit hands
/// over, drawn over the page in this window until it closes itself, and held
/// to the same rules as any other navigation here (`VendorLoginPopups`). It
/// has to be its own web view because the page that opened it is still
/// listening: claude.ai's Google sign-in hands its result to `window.opener`,
/// and loading the popup in place, which this window did through 0.2.7,
/// navigated away from the page holding that callback, so the sign-in could
/// only end in a sentence saying it could not finish. Whether a given provider
/// then completes is the provider's to decide and has to be measured per
/// provider.
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
    }

    /// What a request for a new window becomes, in a window that has only
    /// the one.
    enum PopupRoute: Equatable {
        /// A popup over the page, in this window.
        case open
        /// A link off the vendor's own hosts, handed to the default browser
        /// as the navigation delegate hands every other one.
        case openInBrowser(URL)
    }

    nonisolated private static let webSchemes: Set<String> = ["http", "https"]

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
    /// The page and the popups it has opened over it, while the web view is up.
    private var popups: VendorLoginPopups?
    /// Reads the jar whenever the page's address changes, for as long as a
    /// vendor that signs in with a cookie has its web view up.
    private var addressObservation: NSKeyValueObservation?
    /// Where the last read of the jar found no credential, and what the jar
    /// held there, by name and domain alone. Logged if the window then closes
    /// without one, which is the one trace a sign-in that landed on the
    /// vendor's own app and never linked leaves behind.
    private var lastEmptyLook: String?

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
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        web.uiDelegate = self
        webView = web
        let popups = VendorLoginPopups(page: web)
        self.popups = popups

        if vendor.session != nil {
            let store = configuration.websiteDataStore.httpCookieStore
            store.add(self)
            cookieStore = store
            addressObservation = web.observe(\.url) { [weak self] _, _ in
                Task { @MainActor in self?.lookForSession() }
            }
        }

        let panel = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        panel.title = vendor.title
        panel.contentView = popups.view
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
        window.contentView = host
        window.setContentSize(
            NSSize(
                width: size.width,
                height: Self.promptHeight(of: content, width: size.width, minimum: size.height)))
        window.center()
        bringToFront()
    }

    /// How tall a prompt's window has to be for its content at `width`, and
    /// never shorter than `minimum`.
    ///
    /// Measured against a height of zero, which a prompt answers with the
    /// least its content needs. Every prompt fills its window with
    /// `.frame(maxHeight: .infinity)`, so an unbounded proposal is answered
    /// with the proposal itself: `.greatestFiniteMagnitude`, which AppKit
    /// clamps to the screen, and every prompt was drawn as tall as the
    /// display.
    static func promptHeight(of content: some View, width: CGFloat, minimum: CGFloat) -> CGFloat {
        let fitted = NSHostingController(rootView: content).sizeThatFits(
            in: NSSize(width: width, height: 0))
        return max(minimum, fitted.height)
    }

    /// Drops the web view and its cookie jar as soon as the login is over.
    ///
    /// The credential is in the caller's hands by then, so a live jar holding
    /// a second copy of it buys nothing and keeps a vendor session in memory
    /// for the length of a question.
    private func releaseWeb() {
        addressObservation = nil
        cookieStore?.remove(self)
        cookieStore = nil
        popups?.dismissAll()
        popups = nil
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.stopLoading()
        webView = nil
    }

    /// Reads the jar for the credential this vendor's sign-in ends in.
    ///
    /// `cookiesDidChange` is not enough on its own: WebKit can lose that
    /// registration on a non-persistent store and never make it again
    /// (WebKit bug 305331), and a sign-in whose cookie had landed then sat on
    /// the vendor's own app with nothing delivered. So every finished
    /// navigation and every change of address reads the jar as well — the
    /// latter because claude.ai's app moves to its first route without
    /// loading a page.
    private func lookForSession() {
        guard onCredential != nil, let session = vendor.session, let cookieStore else { return }
        Task { @MainActor in
            let cookies = await cookieStore.allCookies()
            guard onCredential != nil else { return }
            guard let found = session(cookies) else {
                lastEmptyLook =
                    "\(Self.pageSummary(webView?.url)) holding \(Self.jarSummary(cookies))"
                return
            }
            deliver(found)
        }
    }

    /// The cookies of a jar by name and domain, never by value: the value of
    /// the one being looked for is a whole vendor session.
    nonisolated static func jarSummary(_ cookies: [HTTPCookie]) -> String {
        let entries = Set(cookies.map { "\($0.name)@\($0.domain)" }).sorted()
        return entries.isEmpty ? "no cookies" : entries.joined(separator: ", ")
    }

    /// A page by its host and the first step of its path, which is where in
    /// a sign-in or an app it is. Nothing past that, and never the query,
    /// which is where a sign-in carries its codes.
    nonisolated static func pageSummary(_ url: URL?) -> String {
        guard let url, let host = url.host() else { return "no page" }
        guard let step = url.pathComponents.dropFirst().first else { return host }
        return "\(host)/\(step)"
    }

    /// Hands the credential over exactly once. The copies that follow a
    /// successful login — further cookies, a retried redirect — have nothing
    /// left to deliver.
    private func deliver(_ credential: String) {
        guard let pending = onCredential else { return }
        onCredential = nil
        onFailure = nil
        lastEmptyLook = nil
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

    /// Where a request for a new window goes. A link aimed at a new tab obeys
    /// the confinement rule a link aimed at this one does; anything else opens
    /// as a popup over the page, because a sign-in's popup belongs to a
    /// provider whose hosts cannot be listed in advance, and one that opens
    /// blank is written into by the page that asked for it.
    nonisolated static func popupRoute(
        for url: URL?, linkActivated: Bool, isInternal: (String) -> Bool
    ) -> PopupRoute {
        guard linkActivated, let url else { return .open }
        guard let scheme = url.scheme?.lowercased(), webSchemes.contains(scheme),
            let host = url.host()
        else { return .openInBrowser(url) }
        return isInternal(host) ? .open : .openInBrowser(url)
    }
}

extension VendorLoginWindow: WKHTTPCookieStoreObserver {
    /// Fires for every cookie the site sets, so the hand-off is consumed
    /// rather than guarded.
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in lookForSession() }
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        lookForSession()
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        failed(webView, with: error)
    }

    func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error
    ) {
        failed(webView, with: error)
    }

    /// A load error ends the sign-in when it is the page's. A popup's is the
    /// popup's alone: it comes down and the page it covered is what the window
    /// shows again, which is where the sign-in can still be finished another
    /// way.
    private func failed(_ webView: WKWebView, with error: Error) {
        guard let failure = Self.pageFailure(for: error) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard popups?.dismiss(webView) != true else {
                sissyLog("sissy: the \(vendor.logName) login popup did not load and was closed")
                return
            }
            fail(failure)
        }
    }
}

extension VendorLoginWindow: WKUIDelegate {
    /// Answers every request for a new window with a popup over the page, or
    /// with the default browser for a link off the vendor's hosts. Never with
    /// a second window: there is only this one.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let route = Self.popupRoute(
            for: navigationAction.request.url,
            linkActivated: navigationAction.navigationType == .linkActivated,
            isInternal: vendor.isInternal)
        switch route {
        case .open:
            guard let popups else { return nil }
            sissyLog("sissy: the \(vendor.logName) login opened a popup")
            return popups.present(configuration: configuration, delegate: self)
        case .openInBrowser(let url):
            NSWorkspace.shared.open(url)
            return nil
        }
    }

    /// A popup that has finished closes itself, and the page under it is what
    /// the window shows again. The page itself closing is ignored, as a
    /// browser ignores it on a tab no script opened.
    func webViewDidClose(_ webView: WKWebView) {
        guard popups?.dismiss(webView) == true else {
            sissyLog("sissy: the \(vendor.logName) login page asked to close itself")
            return
        }
        sissyLog("sissy: the \(vendor.logName) login popup closed")
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
            if let lastEmptyLook {
                sissyLog("sissy: the \(vendor.logName) login last found no session on \(lastEmptyLook)")
            }
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

/// The sign-in popups a login page has opened, drawn over it in the login
/// window, the newest on top.
///
/// Each is a web view of its own, made from the configuration WebKit hands
/// over for it, which is what makes the page its `window.opener` and gives it
/// the page's cookie jar. Its navigations answer to the login window's
/// delegates like the page's own.
@MainActor
final class VendorLoginPopups {
    /// The page and every popup over it, which is what the window shows.
    let view = NSView()
    private(set) var open: [WKWebView] = []

    init(page: WKWebView) {
        Self.fill(view, with: page)
    }

    /// A popup for WebKit to load its request in, over everything open.
    func present(
        configuration: WKWebViewConfiguration,
        delegate: some WKNavigationDelegate & WKUIDelegate
    ) -> WKWebView {
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = delegate
        popup.uiDelegate = delegate
        Self.fill(view, with: popup)
        open.append(popup)
        return popup
    }

    /// Takes a popup down, and says whether it was one of these.
    func dismiss(_ popup: WKWebView) -> Bool {
        guard let index = open.firstIndex(of: popup) else { return false }
        Self.tearDown(open.remove(at: index))
        return true
    }

    func dismissAll() {
        open.forEach(Self.tearDown)
        open.removeAll()
    }

    private static func fill(_ container: NSView, with web: WKWebView) {
        web.frame = container.bounds
        web.autoresizingMask = [.width, .height]
        container.addSubview(web)
    }

    private static func tearDown(_ popup: WKWebView) {
        popup.navigationDelegate = nil
        popup.uiDelegate = nil
        popup.stopLoading()
        popup.removeFromSuperview()
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
