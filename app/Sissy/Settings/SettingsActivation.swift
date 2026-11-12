import AppKit

/// Opens the `Settings` window from a surface that does not activate the app,
/// activating Sissy first and showing the window only once it is active.
///
/// The usage panel is a non-activating popover, so the app in front stays in
/// front while it is open. A window shown from there is created inside an
/// inactive app, and the activation that `AppDelegate` asks for afterwards
/// makes it the key window without posting `didBecomeKey` to it, so its title
/// bar and its controls keep drawing as inactive, grey switches included, for
/// as long as it stays open. Measured on macOS 27 against the dev build on
/// 2026-11-12: opened first, `NSApp.isActive`, the key window and the window
/// order all reported it active and key while it drew inactive; opened after
/// `didBecomeActive`, it received `didBecomeKey` and drew active.
///
/// The wait is bounded: an activation macOS declines must not leave the gear
/// doing nothing.
@MainActor
enum SettingsActivation {
    /// How long the window waits for an activation macOS may decline.
    private static let activationBudget: Duration = .milliseconds(500)

    /// True from the request until the window is asked for, so that
    /// `AppDelegate` does not demote the app back to `.accessory` in the
    /// moment before the window exists.
    private(set) static var isOpening = false

    /// Runs a turn after an open has finished, so the activation policy is
    /// settled again even when no window came of it: a window that did open
    /// settles it on its own, and one that did not would otherwise leave the
    /// app `.regular`, with a Dock icon and nothing behind it.
    static var onFinished: (@MainActor () -> Void)?

    private static var activationObserver: (any NSObjectProtocol)?
    private static var budgetTask: Task<Void, Never>?

    /// Shows the window through `present` right away when Sissy is already
    /// active and in front, and otherwise after it has become so.
    ///
    /// Both are asked because either alone misleads: a key popover reports
    /// the app active while another app stays in front, and the frontmost
    /// app is still Sissy for a moment after its last window has closed.
    ///
    /// A second request while one is waiting replaces it, which loses
    /// nothing because every caller presents the same scene.
    static func open(_ present: @escaping @MainActor () -> Void) {
        finish(nil)
        guard !(NSApp.isActive && NSWorkspace.shared.frontmostApplication == .current) else {
            present()
            return
        }
        isOpening = true
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { finish(present) }
        }
        budgetTask = Task { @MainActor in
            try? await Task.sleep(for: activationBudget)
            guard !Task.isCancelled else { return }
            finish(present)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    private static func finish(_ present: (@MainActor () -> Void)?) {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        budgetTask?.cancel()
        budgetTask = nil
        guard isOpening else { return }
        isOpening = false
        present?()
        Task { @MainActor in onFinished?() }
    }
}
