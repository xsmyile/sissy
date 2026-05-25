import AppKit
import Foundation

/// Bootstraps the menubar app and leaves runtime ownership to dedicated
/// coordinators. `SissyModel` owns app state and server actions,
/// `StatusItemController` owns the native menu, and `WindowCoordinator` owns
/// Pair/About windows.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let model: SissyModel
    let windowCoordinator: WindowCoordinator

    private var mascotNotifier: MascotNotifier?
    private var statusController: StatusItemController?

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

        let notifier = MascotNotifier(
            model: model,
            statusButtonProvider: { [weak statusController] in statusController?.statusButton },
            menuIsOpenProvider: { [weak statusController] in statusController?.isMenuOpen ?? false }
        )
        notifier.start()
        mascotNotifier = notifier
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        windowCoordinator.applicationShouldTerminateAfterLastWindowClosed()
    }
}
