import AppKit
import WebKit

/// The one window Sissy opens, and the only thing it can do is sign in to
/// claude.ai.
///
/// It is a deliberate exception to "three surfaces and none of them is a
/// window": a session cannot be obtained without the vendor's own login, and
/// the alternative — asking the user to paste a cookie out of a browser's
/// inspector — is worse in every way that matters. What keeps the exception
/// from growing into a browser is that there is nothing to browse with. One
/// window, one starting URL, no address bar, no tabs, no history controls, and
/// it closes itself the moment the session cookie appears.
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
/// and no longer. That is what makes a second `Add account…` a fresh login
/// rather than a silent re-link of the account that is already there, and it
/// keeps a claude.ai session off this Mac except in the keychain item Sissy
/// files it in.
@MainActor
final class ClaudeWebLoginWindow: NSObject {
    static let loginURL = URL(string: "https://claude.ai/login")!
    private static let host = "claude.ai"
    private static let contentSize = NSSize(width: 520, height: 680)
    private static let title = "Add Claude account"

    private var window: NSWindow?
    private var webView: WKWebView?
    private var cookieStore: WKHTTPCookieStore?
    /// Called once, with the session, or with nil when the window was closed
    /// before one appeared. Nil is a cancellation rather than a failure.
    private var finish: ((String?) -> Void)?

    /// Opens the window, or brings the one already open to the front.
    ///
    /// One at a time: two logins would race for the same keychain item and the
    /// second would file its session under whichever account answered last.
    func present(onFinish: @escaping (String?) -> Void) {
        guard window == nil else {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            return
        }
        finish = onFinish

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
        panel.center()
        window = panel

        web.load(URLRequest(url: Self.loginURL))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Hands the session over and takes the window down, once.
    ///
    /// The observer fires for every cookie the site sets, so this is reached
    /// repeatedly on a successful login; `finish` is consumed rather than
    /// checked so the second arrival has nothing to deliver.
    private func complete(with session: String?) {
        guard let pending = finish else { return }
        finish = nil
        cookieStore?.remove(self)
        cookieStore = nil
        webView?.navigationDelegate = nil
        webView = nil
        if let open = window {
            window = nil
            open.delegate = nil
            open.close()
        }
        pending(session)
    }
}

extension ClaudeWebLoginWindow: WKHTTPCookieStoreObserver {
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in
            let cookies = await cookieStore.allCookies()
            guard
                let session = cookies.first(where: {
                    $0.name == ClaudeWebSessionStore.cookieName
                        && $0.domain.hasSuffix(Self.host)
                        && !$0.value.isEmpty
                })
            else { return }
            complete(with: session.value)
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
        Task { @MainActor in complete(with: nil) }
    }
}
