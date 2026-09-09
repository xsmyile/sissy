import SwiftUI

/// Tab the settings window shows. Held on `SissyModel` rather than in local
/// `@State` so a surface that opens the window can aim it — the panel's device
/// button lands on `.device` instead of dropping the user on General.
enum SettingsTab: Hashable {
    case general
    case device
    case about
}

/// Root of the `Settings` scene: one window, one tab per concern.
///
/// Uses the native settings scene rather than a hand-built `NSWindow` so the
/// window gets the system toolbar-tab chrome, the ⌘, shortcut, and frame
/// persistence without reimplementing any of it.
struct SettingsRootView: View {
    @Bindable var model: SissyModel

    private static let width: CGFloat = 560
    private static let minHeight: CGFloat = 340

    var body: some View {
        TabView(selection: $model.settingsTab) {
            GeneralSettingsView(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            DeviceSettingsView(model: model)
                .tabItem { Label("Device", systemImage: "cpu") }
                .tag(SettingsTab.device)

            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: Self.width)
        .frame(minHeight: Self.minHeight)
    }
}
