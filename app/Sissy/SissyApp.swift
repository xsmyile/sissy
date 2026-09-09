import SwiftUI

/// LSUIElement (menu-bar-only) app. The dropdown is built in AppKit by
/// `StatusItemController` (`NSStatusItem` + `NSMenu`) so submenus, selection,
/// key equivalents, and dismissal stay native. The only hosted menu row is the
/// non-interactive header.
///
/// The `Settings` scene carries the app's settings window: using the system
/// scene rather than a hand-built window is what supplies the toolbar-tab
/// chrome and the ⌘, shortcut. `SettingsLink` in the usage panel and the
/// status item's menu both open it. Window management for Pair Device and
/// About lives in `WindowCoordinator`; `AppDelegate` only bootstraps the
/// runtime objects.
@main
struct SissyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsRootView(model: appDelegate.model)
        }
    }
}
