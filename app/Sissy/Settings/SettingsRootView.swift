import SwiftUI

/// Tab the settings window shows. Held on `SissyModel` rather than in local
/// `@State` so a surface that opens the window can aim it, rather than
/// dropping the user on whichever tab was last selected.
enum SettingsTab: Hashable {
    case general
    case about

    var title: String {
        switch self {
        case .general: return "General"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .about: return "info.circle"
        }
    }
}

/// Root of the `Settings` scene: one window, one tab per concern.
///
/// The strip is the scene's own toolbar rather than a row drawn in content
/// space: the toolbar is what carries the centred window title and the Liquid
/// Glass chrome the rest of the system draws, and a `Material.bar` strip below
/// the title bar can imitate neither. Toolbar tabs do highlight under the
/// pointer — so do System Settings', which is why that is no longer a reason
/// to hand-draw them.
struct SettingsRootView: View {
    @Bindable var model: SissyModel

    private static let width: CGFloat = 560
    /// A `TabView` in a `Settings` scene otherwise names the window after the
    /// selected tab, which reads as three different windows in the Window menu
    /// and in Mission Control.
    private static let windowTitle = "Sissy Settings"

    /// `fixedSize` is what makes the window follow the selected tab: without a
    /// definite ideal height the settings window keeps whatever height the
    /// tallest tab established, and About then floats in the leftover space.
    var body: some View {
        TabView(selection: $model.settingsTab) {
            tab(.general) { GeneralSettingsView(model: model) }
            tab(.about) { AboutView(model: model) }
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        // Left automatic, the toolbar decides its own background from whether
        // a scroll view underneath it is scrolled off the top — so General,
        // whose `Form` is one, and About, which has none and can never report
        // "at the top", disagreed about whether to draw a band under the tabs.
        // Neither tab ever scrolls: the window is sized to its content.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    private func tab<Content: View>(
        _ tab: SettingsTab,
        @ViewBuilder content: () -> Content
    ) -> some TabContent<SettingsTab> {
        Tab(tab.title, systemImage: tab.symbol, value: tab) {
            content().navigationTitle(Self.windowTitle)
        }
    }
}
