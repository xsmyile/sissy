import AppKit
import Foundation

/// Bootstraps the menubar app and leaves runtime ownership to dedicated
/// coordinators: `SissyModel` owns app state and server actions,
/// `StatusItemController` the native menu, `UsagePanelController` the popover.
/// The only window is the SwiftUI `Settings` scene, which opens itself.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: SissyModel

    private var mascotNotifier: MascotNotifier?
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

        // Both surfaces anchor to the same status button, so a mood pop-up
        // while either is open would fight it for the anchor.
        let notifier = MascotNotifier(
            model: model,
            statusButtonProvider: { [weak statusController] in statusController?.statusButton },
            menuIsOpenProvider: { [weak statusController, weak panelController] in
                (statusController?.isMenuOpen ?? false) || (panelController?.isOpen ?? false)
            }
        )
        notifier.start()
        mascotNotifier = notifier
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
