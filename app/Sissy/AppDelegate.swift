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

    override init() {
        self.model = SissyModel()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()

        let statusController = StatusItemController(model: model)
        self.statusController = statusController

        let panelController = UsagePanelController(model: model)
        self.panelController = panelController
        statusController.onPrimaryClick = { [weak statusController, weak panelController] in
            guard let button = statusController?.statusButton else { return }
            panelController?.toggle(relativeTo: button)
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
    private func syncActivationPolicy() {
        let hasWindow = NSApp.windows.contains { window in
            window.isVisible && window.canBecomeMain
        }
        let desired: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != desired else { return }
        NSApp.setActivationPolicy(desired)
    }

    /// Closing the settings window must not take the menubar app with it, and
    /// an accessory app that keeps activation after its last window closes
    /// leaves the previous app without focus.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let nextApp = NSWorkspace.shared.runningApplications.first { app in
            app != .current && app.activationPolicy == .regular && !app.isTerminated
        }
        if let nextApp {
            NSApp.yieldActivation(to: nextApp)
        } else {
            NSApp.deactivate()
        }
        return false
    }
}
