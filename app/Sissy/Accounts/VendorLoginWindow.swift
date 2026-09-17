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
        let startURL: URL
        /// Whether a host is part of this vendor's own sign-in.
        let isInternal: @Sendable (String) -> Bool
        /// The credential a cookie jar has come to carry, if this vendor ends
        /// its sign-in that way.
        let session: (@Sendable ([HTTPCookie]) -> String?)?
        /// The credential a navigation carries, if this vendor ends its
        /// sign-in with a redirect.
        let code: (@Sendable (URL) -> String?)?
    }

    /// The one question a link cannot answer for itself, in the vendor's own
    /// vocabulary: an organisation for Claude, a workspace for Codex.
    struct Question {
        let title: String
        let caption: String
        let options: [Option]

        struct Option: Identifiable {
            let id: String
            let label: String
        }
    }

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
    private var finished = false

    init(vendor: Vendor) {
        self.vendor = vendor
    }

    /// Opens the window, or brings the one already open to the front.
    ///
    /// Re-presenting rather than refusing is the point: the control that opens
    /// this is the only way back to a window that has gone behind, so a second
    /// press has to mean "show me the one I already have".
    func present(onCredential: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        guard window == nil else {
            front()
            return
        }
        self.onCredential = onCredential
        self.onCancel = onCancel

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
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
        front()
    }

    /// Asks the question the link could not answer, in the window the
    /// credential was just obtained in.
    func ask(_ question: Question, onPick: @escaping (String) -> Void) {
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

    /// Says the credential is in hand while the caller resolves it.
    func working() {
        swap(to: VendorLinkProgressView(), size: Self.promptSize)
    }

    /// Takes the window down on a link that completed. `onCancel` is consumed
    /// first, so the close this causes is not reported as one.
    func finish() {
        finished = true
        close()
    }

    private func front() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func close() {
        finished = true
        window?.close()
    }

    private func swap(to content: some View, size: NSSize) {
        releaseWeb()
        guard let window else { return }
        window.contentView = NSHostingView(rootView: content)
        window.setContentSize(size)
        window.center()
        front()
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
        webView?.stopLoading()
        webView = nil
    }

    /// Hands the credential over exactly once. The copies that follow a
    /// successful login — further cookies, a retried redirect — have nothing
    /// left to deliver.
    private func deliver(_ credential: String) {
        guard let pending = onCredential else { return }
        onCredential = nil
        working()
        pending(credential)
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
        if let code = vendor.code?(url) {
            deliver(code)
            return .cancel
        }
        guard navigationAction.navigationType == .linkActivated,
            let host = url.host(),
            !vendor.isInternal(host)
        else { return .allow }
        NSWorkspace.shared.open(url)
        return .cancel
    }
}

extension VendorLoginWindow: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            releaseWeb()
            window?.delegate = nil
            window = nil
            NSApp.setActivationPolicy(.accessory)
            let cancelled = onCancel
            onCredential = nil
            onCancel = nil
            guard !finished else { return }
            cancelled?()
        }
    }
}

extension VendorLoginWindow.Vendor {
    /// claude.ai's login, which ends in a `sessionKey` cookie.
    static var claude: Self {
        Self(
            title: "Add Claude account",
            startURL: URL(string: "https://claude.ai/login")!,
            isInternal: { isHost($0, in: "claude.ai") },
            session: { cookies in
                cookies.first {
                    $0.name == ClaudeWebSessionStore.cookieName
                        && isHost($0.domain, in: "claude.ai")
                        && !$0.value.isEmpty
                }?.value
            },
            code: nil)
    }

    /// OpenAI's login, which ends in a redirect to the CLI's loopback address
    /// carrying an authorization code.
    static func codex(flow: CodexOAuth.Flow) -> Self {
        Self(
            title: "Add Codex account",
            startURL: flow.url,
            isInternal: { host in
                isHost(host, in: "openai.com") || isHost(host, in: "chatgpt.com")
            },
            session: nil,
            code: { flow.code(fromRedirect: $0) })
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
    let question: VendorLoginWindow.Question
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
