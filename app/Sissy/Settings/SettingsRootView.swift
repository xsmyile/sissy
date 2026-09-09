import SwiftUI

/// Root of the `Settings` scene: one window, one tab per concern.
///
/// Uses the native settings scene rather than a hand-built `NSWindow` so the
/// window gets the system toolbar-tab chrome, the ⌘, shortcut, and frame
/// persistence without reimplementing any of it.
struct SettingsRootView: View {
    let model: SissyModel

    private static let width: CGFloat = 520
    private static let minHeight: CGFloat = 320

    enum Tab: Hashable {
        case general
        case advanced
        case about
    }

    @State private var selection: Tab = .general

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsView(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)

            AdvancedSettingsView(model: model)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
                .tag(Tab.advanced)

            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        .frame(width: Self.width)
        .frame(minHeight: Self.minHeight)
    }
}
