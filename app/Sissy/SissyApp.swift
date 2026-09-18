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
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutCommand(model: appDelegate.model)
            }
        }
    }
}

/// `About Sissy`, aimed at the tab of the same name.
///
/// Left alone, SwiftUI's own item opens AppKit's standard about panel, which is
/// a second About surface carrying the icon and the version and none of the
/// links — two pages answering one question, of which only one is designed.
///
/// `openSettings` rather than `SettingsLink`: a link takes no action closure,
/// so the only way to aim it at a tab is a `simultaneousGesture`, and that does
/// not fire inside an AppKit menu — measured on the dev build for the panel's
/// own account list, where the item opened Settings on whatever tab was last
/// shown.
private struct AboutCommand: View {
    let model: SissyModel

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("About Sissy") {
            model.settingsTab = .about
            openSettings()
        }
    }
}
