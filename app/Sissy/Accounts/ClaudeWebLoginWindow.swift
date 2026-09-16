import AppKit
import SwiftUI
import WebKit

/// The one window Sissy opens, and the only thing it can do is link a Claude
/// account.
///
/// It is a deliberate exception to "three surfaces and none of them is a
/// window": a session cannot be obtained without the vendor's own login, and
/// the alternative — asking the user to paste a cookie out of a browser's
/// inspector — is worse in every way that matters. What keeps the exception
/// from growing into a browser is that there is nothing to browse with. One
/// window, one starting URL, no address bar, no tabs, no history controls.
///
/// Link clicks that leave claude.ai — terms, privacy, help — are handed to the
/// default browser rather than followed here, which is what "confined to
/// claude.ai" means in practice: there is no way to reach another site by
/// hand. Redirects are followed, because a sign-in is a redirect chain the
/// vendor owns and a host allowlist would be a guess: measured 2026-09-16,
/// claude.ai's login page answers 403 to anything but a real browser, so which
/// identity providers it offers cannot be read from here. A wrong list is a
/// window that dead-ends on the one account the user came to add.
///
/// The cookie jar is non-persistent, so it exists for the life of the window
/// and no longer. That is what makes a second link a fresh login rather than a
/// silent re-link of the account already there, and it keeps a claude.ai
/// session off this Mac except in the keychain item Sissy files it in.
///
/// **The whole link happens here, not only its first step.** The window stays
/// up past the cookie, because what follows can need the user: an account with
/// more than one organisation answering the usage question has to be asked
/// which, and a session claude.ai will not answer for has to say so somewhere
/// the person who just typed a code is looking. Closing on the cookie and
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
final class ClaudeWebLoginWindow: NSObject {
    static let loginURL = URL(string: "https://claude.ai/login")!
    private static let host = "claude.ai"
    private static let contentSize = NSSize(width: 520, height: 680)
    private static let promptSize = NSSize(width: 420, height: 260)
    private static let title = "Add Claude account"

    private var window: NSWindow?
    private var webView: WKWebView?
    private var cookieStore: WKHTTPCookieStore?
    /// Called with the session the login produced. The window stays up: what
    /// the caller does next may need this window again.
    private var onSession: ((String) -> Void)?
    /// Called once when the window goes away without the flow completing.
    private var onCancel: (() -> Void)?
    private var finished = false

    /// Opens the window, or brings the one already open to the front.
    ///
    /// Re-presenting rather than refusing is the point: the control that opens
    /// this is the only way back to a window that has gone behind, so a second
    /// press has to mean "show me the one I already have".
    func present(onSession: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        guard window == nil else {
            front()
            return
        }
        self.onSession = onSession
        self.onCancel = onCancel

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        webView = web

        let store = configuration.websiteDataStore.httpCookieStore
        store.add(self)
        cookieStore = store

        let panel = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        panel.title = Self.title
        panel.contentView = web
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.level = .floating
        panel.center()
        window = panel

        web.load(URLRequest(url: Self.loginURL))
        NSApp.setActivationPolicy(.regular)
        front()
    }

    /// Asks which organisation the session should be read for, in the window
    /// the session was just obtained in.
    func ask(_ choice: ClaudeWebLinkChoice, onPick: @escaping (String) -> Void) {
        swap(
            to: ClaudeWebLinkChoiceView(
                choice: choice,
                onPick: { [weak self] organization in
                    self?.working()
                    onPick(organization)
                },
                onCancel: { [weak self] in self?.close() }),
            size: Self.promptSize)
    }

    /// Says what went wrong, here rather than on a surface nobody opened, and
    /// offers the only thing that can help: the login again.
    func report(_ message: String, onRetry: @escaping () -> Void) {
        swap(
            to: ClaudeWebLinkFailureView(
                message: message,
                onRetry: { [weak self] in
                    self?.close()
                    onRetry()
                },
                onCancel: { [weak self] in self?.close() }),
            size: Self.promptSize)
    }

    /// Says the session is in hand while the caller resolves it.
    func working() {
        swap(to: ClaudeWebLinkProgressView(), size: Self.promptSize)
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
    /// The session is in the caller's hands by then, so a live jar holding a
    /// second copy of it buys nothing and keeps a claude.ai session in memory
    /// for the length of a question.
    private func releaseWeb() {
        cookieStore?.remove(self)
        cookieStore = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
    }
}

extension ClaudeWebLoginWindow: WKHTTPCookieStoreObserver {
    /// Fires for every cookie the site sets, so the hand-off is consumed
    /// rather than guarded: the copies that follow a successful login have
    /// nothing left to deliver.
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in
            guard let pending = onSession else { return }
            let cookies = await cookieStore.allCookies()
            guard
                let session = cookies.first(where: {
                    $0.name == ClaudeWebSessionStore.cookieName
                        && $0.domain.hasSuffix(Self.host)
                        && !$0.value.isEmpty
                })
            else { return }
            onSession = nil
            working()
            pending(session.value)
        }
    }
}

extension ClaudeWebLoginWindow: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard navigationAction.navigationType == .linkActivated,
            let url = navigationAction.request.url,
            let host = url.host(),
            host != Self.host, !host.hasSuffix(".\(Self.host)")
        else { return .allow }
        NSWorkspace.shared.open(url)
        return .cancel
    }
}

extension ClaudeWebLoginWindow: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            releaseWeb()
            window?.delegate = nil
            window = nil
            NSApp.setActivationPolicy(.accessory)
            let cancelled = onCancel
            onSession = nil
            onCancel = nil
            guard !finished else { return }
            cancelled?()
        }
    }
}

/// The one question a link cannot answer for itself, asked in the window the
/// session was obtained in.
private struct ClaudeWebLinkChoiceView: View {
    let choice: ClaudeWebLinkChoice
    let onPick: (String) -> Void
    let onCancel: () -> Void

    /// Nothing is selected to begin with, so linking is a choice someone made
    /// rather than the first row happening to be selected — which is the whole
    /// reason the question is asked instead of derived.
    @State private var picked: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ClaudeAccountLinkCopy.chooseLabel)
                .font(.headline)
            Text(ClaudeAccountLinkCopy.chooseCaption(choice.identity.email))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("", selection: Binding(get: { picked ?? "" }, set: { picked = $0 })) {
                ForEach(UsageFormat.organizationChoices(choice.organizations), id: \.id) {
                    organization in
                    Text(organization.label).tag(organization.id)
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

private struct ClaudeWebLinkProgressView: View {
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

private struct ClaudeWebLinkFailureView: View {
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
