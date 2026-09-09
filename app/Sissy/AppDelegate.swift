import AppKit
import Foundation

/// Bootstraps the menubar app and leaves runtime ownership to dedicated
/// coordinators. `SissyModel` owns app state and server actions,
/// `StatusItemController` owns the native menu, and `WindowCoordinator` owns
/// Pair/About windows.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: SissyModel
    let windowCoordinator: WindowCoordinator

    private var mascotNotifier: MascotNotifier?
    private var statusController: StatusItemController?
    private var panelController: UsagePanelController?

    override init() {
        let model = SissyModel()
        self.model = model
        self.windowCoordinator = WindowCoordinator(model: model)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()

        let statusController = StatusItemController(
            model: model,
            windowCoordinator: windowCoordinator
        )
        self.statusController = statusController

        let panelController = UsagePanelController(
            model: model,
            onPairDevice: { [weak self] in self?.windowCoordinator.openPairingWindow() },
            onShowMenu: { [weak statusController] in statusController?.showMenu() }
        )
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        windowCoordinator.applicationShouldTerminateAfterLastWindowClosed()
    }
}
