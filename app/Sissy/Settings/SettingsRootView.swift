import SwiftUI

/// Tab the settings window shows. Held on `SissyModel` rather than in local
/// `@State` so a surface that opens the window can aim it — the panel's device
/// button lands on `.device` instead of dropping the user on General.
enum SettingsTab: Hashable, CaseIterable {
    case general
    case device
    case about

    var title: String {
        switch self {
        case .general: return "General"
        case .device: return "Device"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .device: return "cpu"
        case .about: return "info.circle"
        }
    }
}

/// Root of the `Settings` scene: one window, one tab per concern.
///
/// The tab strip is drawn here rather than by a `TabView`, whose toolbar
/// items darken under the pointer with no way to opt out. Only the selected
/// tab carries a chip; hovering an unselected one changes nothing.
struct SettingsRootView: View {
    @Bindable var model: SissyModel

    private static let width: CGFloat = 560
    private static let tabSize = CGSize(width: 78, height: 48)

    /// `fixedSize` is what makes the window follow the selected tab: without a
    /// definite ideal height the settings window keeps whatever height the
    /// tallest tab established, and About then floats in the leftover space.
    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            selectedTab
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var selectedTab: some View {
        switch model.settingsTab {
        case .general:
            GeneralSettingsView(model: model)
        case .device:
            DeviceSettingsView(model: model)
        case .about:
            AboutView()
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func tabButton(_ tab: SettingsTab) -> some View {
        let isSelected = model.settingsTab == tab
        return Button {
            model.settingsTab = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 15))
                Text(tab.title)
                    .font(.system(size: 11))
            }
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .frame(width: Self.tabSize.width, height: Self.tabSize.height)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .opacity(isSelected ? 1 : 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
