import AppKit
import Foundation

/// Bootstraps the menubar app and leaves runtime ownership to dedicated
/// coordinators: `SissyModel` owns app state and the metering engine,
/// `StatusItemController` the status item, `UsagePanelController` the panel.
/// The only window is the SwiftUI `Settings` scene, which opens itself.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: SissyModel

    private var statusController: StatusItemController?
    private var panelController: UsagePanelController?
    private var isTerminating = false
    private var repliedToTerminate = false

    /// What a reopen does when no window is up: opens the usage panel.
    /// Wired in `applicationDidFinishLaunching` beside the status item's own
    /// click, and left nil in the test host, which builds neither.
    var onReopen: (() -> Void)?

    /// The launch run of `HTTPStoragePurge`, held here so the delete has an
    /// owner and stays off the main thread, at utility priority because
    /// nothing waits on it.
    ///
    /// Its order against the engine's `start()` does not matter: `SissyHTTP`
    /// keeps no disk cache and no cookie jar, so nothing the engine sends can
    /// write into the trees the purge is deleting.
    private var storagePurge: Task<Void, Never>?

    /// How long quitting waits for the engine to shut down.
    ///
    /// What the wait buys is each reader's final offset flush — without it the
    /// last few seconds of progress are re-parsed at next launch, which dedup
    /// absorbs, so nothing is lost either way. What the bound buys is that a
    /// teardown which will not finish cannot leave a menu bar app that refuses
    /// to quit: `ClaudeCredentials` can be parked behind a keychain dialog
    /// nobody answered, and the process is exiting regardless.
    ///
    /// The same budget bounds `CodexRenewal.fileBeforeQuitting`, which runs
    /// beside the teardown. That wait is not about offsets: a Codex renewal
    /// the keychain has not taken yet holds the only copy of a rotated refresh
    /// token, and a quit that drops it reads as an ended link at next launch.
    private static let teardownBudget: Duration = .seconds(2)

    override init() {
        self.model = SissyModel()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The test host must not start the user's engine or retire login items.
        guard NSClassFromString("XCTestCase") == nil else { return }
        storagePurge = Task.detached(priority: .utility) {
            HTTPStoragePurge.run(in: .user())
        }
        model.start()

        let statusController = StatusItemController(model: model)
        self.statusController = statusController

        let panelController = UsagePanelController(model: model)
        self.panelController = panelController
        statusController.onPrimaryClick = { [weak statusController, weak panelController] in
            guard let button = statusController?.statusButton else { return }
            panelController?.toggle(relativeTo: button)
        }
        onReopen = { [weak statusController, weak panelController] in
            guard let button = statusController?.statusButton else { return }
            panelController?.show(relativeTo: button)
        }

        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // A turn late on purpose: a closing window is still listed and
                // still visible while `willClose` is being delivered, so
                // reading the window list now would keep the Dock icon.
                Task { @MainActor in self?.syncActivationPolicy() }
            }
        }
    }

    /// Keeps the Dock icon in step with whether the app currently has a real
    /// window, rather than leaving it absent for the process's whole life.
    ///
    /// `LSUIElement` keeps Sissy out of the Dock, which is right for a menubar
    /// app — but an accessory app is missing from ⌘-Tab too, so once another
    /// window covers the Settings window there is no way back to it beyond the
    /// panel's gear. Promoting to `.regular` while a window is up and dropping
    /// back when it goes is what `setActivationPolicy` is for.
    ///
    /// `canBecomeMain` is the discriminator: the usage panel's popover and the
    /// status item's own window are borderless and cannot, so neither puts an
    /// icon in the Dock.
    ///
    /// The promotion is activated explicitly, and that is not redundant with
    /// the window having just become key. AppKit installs the menu bar on
    /// activation, and this runs a turn *after* the window took focus — so the
    /// app is already frontmost when the policy flips and there is no
    /// activation left for the menu bar to be hung off. Observed 2026-09-18 on
    /// the dev build: the Dock icon appeared and the menu bar drew `Sissy`,
    /// while clicking it opened nothing at all; activating another app and
    /// coming back installed the menu, and a relaunch brought the dead menu
    /// back. It is intermittent because it depends on whether the app still
    /// held activation when the window opened, which is why it survived every
    /// reading of this function.
    ///
    /// The guard above is what keeps this from stealing focus: the activation
    /// only ever runs on the transition into `.regular`, never on the
    /// notifications that find the policy already correct.
    private func syncActivationPolicy() {
        let hasWindow = NSApp.windows.contains { window in
            window.isVisible && window.canBecomeMain
        }
        let desired: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != desired else { return }
        NSApp.setActivationPolicy(desired)
        if desired == .regular {
            NSApp.activate()
        }
    }

    /// Opening Sissy while it already runs opens the panel.
    ///
    /// LaunchServices delivers a double-click in Applications, a Spotlight
    /// hit or `open -a Sissy` to the running instance as a reopen, which went
    /// unanswered before this, so a relaunch read as an app that would not
    /// start while it was counting.
    ///
    /// The panel is anchored to the status item, so this reaches only an item
    /// in the menu bar. One switched off in the menu bar's settings has no
    /// window and `UsagePanelController.show(relativeTo:)` declines it; one
    /// behind the notch opens the panel under an item nobody can see.
    ///
    /// A window already up is left to AppKit, whose own reopen brings it
    /// forward: that is Settings or the login window, and the panel would
    /// only open over it.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        guard !flag else { return true }
        onReopen?()
        return false
    }

    /// Lets the engine shut down and the Codex renewals file what they hold
    /// before the process goes, both bounded by `teardownBudget`.
    /// `.terminateLater` is what buys the await: quitting is the only thing
    /// that ends a run, so it is the only chance the readers get to write
    /// their offsets.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateNow }
        isTerminating = true
        Task { @MainActor in
            async let renewalsFiled = CodexRenewal.shared.fileBeforeQuitting(
                within: Self.teardownBudget)
            await model.stop()
            _ = await renewalsFiled
            replyToTerminate()
        }
        Task { @MainActor in
            try? await Task.sleep(for: Self.teardownBudget)
            replyToTerminate()
        }
        return .terminateLater
    }

    /// Whichever of the two racing tasks arrives first releases the quit. Both
    /// run on the main actor, so the flag needs no other guard.
    private func replyToTerminate() {
        guard !repliedToTerminate else { return }
        repliedToTerminate = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    /// Closing the settings window must not take the menubar app with it, which
    /// is the whole of what this answers: handing activation back is
    /// `syncActivationPolicy`'s, and it needs no help.
    ///
    /// It used to yield activation to the first regular app in
    /// `NSWorkspace.runningApplications`, which cannot do either half of what
    /// it was there for. `yieldActivation` "will not deactivate the current
    /// app, nor will it activate the other app" — the target has to claim it by
    /// calling `activate`, which an app that was never told will never do — and
    /// the order of that array is documented as unspecified, so the app it
    /// named was not the one the user came from. Both quoted from the
    /// MacOSX27.0 SDK headers. Measured 2026-09-18 on macOS 27 against a
    /// harness of this shape, with Orca active before the window opened: the
    /// yield named Finder, and focus went back to Orca regardless, by the next
    /// sample 300 ms after the drop to `.accessory`. Deactivating explicitly
    /// measured the same, and so did doing nothing at all — AppKit gives up
    /// activation on its own for an app left with no window, a second or so
    /// later.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
