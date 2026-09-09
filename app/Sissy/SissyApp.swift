import SwiftUI

/// LSUIElement (menu-bar-only) app. The right-click menu is built in AppKit by
/// `StatusItemController` (`NSStatusItem` + `NSMenu`) so key equivalents and
/// dismissal stay native. The only hosted menu row is the non-interactive
/// header.
///
/// The `Settings` scene is the app's only window: using the system scene
/// rather than a hand-built one is what supplies the toolbar-tab chrome and
/// the ⌘, shortcut. The usage panel's footer opens it through `SettingsLink`.
/// `AppDelegate` only bootstraps the runtime objects.
@main
struct SissyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsRootView(model: appDelegate.model)
        }
    }
}
