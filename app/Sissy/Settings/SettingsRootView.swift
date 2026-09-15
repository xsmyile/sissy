import SwiftUI

/// Tab the settings window shows. Held on `SissyModel` rather than in local
/// `@State` so a surface that opens the window can aim it, rather than
/// dropping the user on whichever tab was last selected.
enum SettingsTab: Hashable {
    case general
    case providers
    case about

    var title: String {
        switch self {
        case .general: return "General"
        case .providers: return "Providers"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .providers: return "rectangle.stack"
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
    /// The budget a tab is designed to fit in, and the height past which one
    /// scrolls instead of growing the window. A tab that needs more than this
    /// is a tab that should have split.
    ///
    /// It is a ceiling on the content, which the window adds its own title bar
    /// and tab strip to. Without one the window followed the content off the
    /// bottom of the screen — and it cannot be resized or scrolled back, so
    /// what went past the edge was unreachable: measured at 850 pt for General
    /// against the 841 pt a 14" Mac set to a larger text size has room for, and
    /// the 775 pt of a 1280×800 display.
    private static let maxContentHeight: CGFloat = 600
    /// A `TabView` in a `Settings` scene otherwise names the window after the
    /// selected tab, which reads as three different windows in the Window menu
    /// and in Mission Control.
    private static let windowTitle = "Sissy Settings"

    /// `fixedSize` is what makes the window follow the selected tab: without a
    /// definite ideal height the settings window keeps whatever height the
    /// tallest tab established, and a shorter tab then floats centred in the
    /// leftover space. The ceiling therefore goes on each tab's own content,
    /// inside the `fixedSize` — put outside it, it makes the whole `TabView`
    /// flexible again and brings that floating back.
    var body: some View {
        TabView(selection: $model.settingsTab) {
            tab(.general) { GeneralSettingsView(model: model) }
            tab(.providers) { ProvidersSettingsView(model: model) }
            tab(.about) { AboutView(model: model) }
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        // Left automatic, the toolbar decides its own background from whether
        // a scroll view underneath it is scrolled off the top — so General,
        // whose `Form` is one, and About, which has none and can never report
        // "at the top", disagreed about whether to draw a band under the tabs.
        // A tab at the ceiling does scroll, and gives up that band to keep the
        // three tabs drawing the same chrome.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    private func tab<Content: View>(
        _ tab: SettingsTab,
        @ViewBuilder content: () -> Content
    ) -> some TabContent<SettingsTab> {
        Tab(tab.title, systemImage: tab.symbol, value: tab) {
            content()
                .frame(maxHeight: Self.maxContentHeight)
                .navigationTitle(Self.windowTitle)
        }
    }
}
