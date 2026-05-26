import AppKit
import Combine
import SwiftUI

/// Owns the app's native status item and root pull-down menu. Interactive
/// rows are native `NSMenuItem`s; the only hosted SwiftUI row is the
/// non-interactive header.
@MainActor
final class StatusItemController: NSObject {
    let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let model: SissyModel
    private let windowCoordinator: WindowCoordinator

    private let headerItem = NSMenuItem()
    private let serverItem = NSMenuItem(title: "Server", action: nil, keyEquivalent: "")
    private let metricItem = NSMenuItem(title: "Metric", action: nil, keyEquivalent: "")
    private let milestonesItem = NSMenuItem(title: "Milestones", action: nil, keyEquivalent: "")
    private let mascotItem = NSMenuItem(title: "Mascot", action: nil, keyEquivalent: "")
    /// "Breakdown" submenu shown only when the daemon reports two or more
    /// active providers. A single-CLI install never sees a one-row submenu.
    private let breakdownItem = NSMenuItem(title: "Breakdown", action: nil, keyEquivalent: "")
    private let pairItem = NSMenuItem(title: "Pair Device...", action: nil, keyEquivalent: "p")

    private var headerView: NSHostingView<HeaderRowView>?
    private var cancellables: Set<AnyCancellable> = []

    private static let rowWidth: CGFloat = 260

    private(set) var isMenuOpen: Bool = false
    var statusButton: NSStatusBarButton? { statusItem.button }

    init(model: SissyModel, windowCoordinator: WindowCoordinator) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.model = model
        self.windowCoordinator = windowCoordinator
        super.init()

        configureHeaderItem()
        configureSubmenus()
        buildMenu()
        configureButton()
        startObservers()
        refreshFromModel()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.toolTip = "Sissy"
        button.wantsLayer = true
    }

    private func configureHeaderItem() {
        let view = NSHostingView(rootView: HeaderRowView(header: model.menuSnapshot.header))
        view.frame = NSRect(x: 0, y: 0, width: Self.rowWidth, height: 52)
        headerView = view
        headerItem.view = view
        headerItem.isEnabled = false
    }

    private func configureSubmenus() {
        metricItem.submenu = NSMenu()
        metricItem.submenu?.delegate = self
        milestonesItem.submenu = NSMenu()
        milestonesItem.submenu?.delegate = self
        mascotItem.submenu = NSMenu()
        mascotItem.submenu?.delegate = self
        breakdownItem.submenu = NSMenu()
        breakdownItem.submenu?.delegate = self
    }

    private func buildMenu() {
        menu.autoenablesItems = false
        menu.delegate = self
        menu.removeAllItems()

        statusItem.menu = menu

        menu.addItem(headerItem)
        menu.addItem(.separator())

        serverItem.target = self
        serverItem.action = #selector(handleServer)
        menu.addItem(serverItem)

        menu.addItem(milestonesItem)
        menu.addItem(mascotItem)

        menu.addItem(.separator())

        pairItem.target = self
        pairItem.action = #selector(handlePair)
        pairItem.keyEquivalentModifierMask = [.command]
        menu.addItem(pairItem)

        let openLogs = NSMenuItem(title: "Open Logs", action: #selector(handleOpenLogs), keyEquivalent: "l")
        openLogs.target = self
        openLogs.keyEquivalentModifierMask = [.command]
        menu.addItem(openLogs)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About", action: #selector(handleAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit", action: #selector(handleQuit), keyEquivalent: "q")
        quit.target = self
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)
    }

    private func startObservers() {
        model.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.refreshFromModel()
                }
            }
            .store(in: &cancellables)
    }

    private func refreshFromModel() {
        let snapshot = model.menuSnapshot
        refreshIcon(snapshot.statusIcon)
        refreshTopLevelItems(snapshot)
    }

    private func refreshIcon(_ icon: SissyModel.StatusIconSnapshot) {
        guard let button = statusItem.button else { return }
        let image = NSImage(named: icon.imageName)
        image?.isTemplate = true
        button.image = image
        button.alphaValue = icon.alpha
    }

    private func refreshTopLevelItems(_ snapshot: SissyModel.MenuSnapshot) {
        headerView?.rootView = HeaderRowView(header: snapshot.header)

        serverItem.title = snapshot.server.title
        serverItem.subtitle = snapshot.server.subtitle
        serverItem.state = .off
        serverItem.isEnabled = snapshot.server.isEnabled

        metricItem.subtitle = snapshot.primaryMetric.label
        setItemPresent(metricItem, present: snapshot.showMetric, after: serverItem)
        milestonesItem.subtitle = "every \(snapshot.milestoneFrequency.detail)"
        mascotItem.subtitle = snapshot.mascotLabel

        let showBreakdown = snapshot.providerBreakdown.count >= 2
        breakdownItem.subtitle =
            showBreakdown
            ? "\(snapshot.providerBreakdown.count) sources" : ""
        setItemPresent(breakdownItem, present: showBreakdown, after: mascotItem)
    }

    /// Insert or remove `item` so it sits directly after `anchor`. Visibility
    /// is driven by structural mutation instead of `NSMenuItem.isHidden`
    /// because NSMenu re-flows on `insertItem`/`removeItem` mid-tracking but
    /// caches item rects across an `isHidden` flip — the latter produced the
    /// clipped-row glitch when `providerBreakdown` crossed the ≥2 threshold
    /// while the menu was already on screen.
    private func setItemPresent(_ item: NSMenuItem, present: Bool, after anchor: NSMenuItem) {
        let containsItem = menu.items.contains(item)
        if present, !containsItem {
            let anchorIdx = menu.index(of: anchor)
            guard anchorIdx >= 0 else { return }
            menu.insertItem(item, at: anchorIdx + 1)
        } else if !present, containsItem {
            menu.removeItem(item)
        }
    }

    // MARK: Submenus

    private func rebuildMetricSubmenu(_ submenu: NSMenu) {
        let snapshot = model.menuSnapshot
        submenu.removeAllItems()
        for metric in Preferences.PrimaryMetric.allCases {
            let item = NSMenuItem(
                title: metric.label,
                action: #selector(pickMetric(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = metric.rawValue
            item.state = (metric == snapshot.primaryMetric) ? .on : .off
            submenu.addItem(item)
        }
    }

    private func rebuildMilestonesSubmenu(_ submenu: NSMenu) {
        let snapshot = model.menuSnapshot
        submenu.removeAllItems()
        for preset in Preferences.MilestoneFrequency.allCases {
            let item = NSMenuItem(
                title: preset.label,
                action: #selector(pickMilestone(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.subtitle = preset.detail
            item.representedObject = preset.rawValue
            item.state = (preset == snapshot.milestoneFrequency) ? .on : .off
            submenu.addItem(item)
        }
    }

    private func rebuildBreakdownSubmenu(_ submenu: NSMenu) {
        let rows = model.menuSnapshot.providerBreakdown
        submenu.removeAllItems()
        for row in rows {
            let title = Self.providerDisplayName(row.id)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.subtitle = Self.formatBreakdownSubtitle(tokens: row.tokens, cost: row.cost)
            submenu.addItem(item)
        }
        if rows.isEmpty {
            let empty = NSMenuItem(title: "No data yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
    }

    private static func providerDisplayName(_ id: String) -> String {
        switch id {
        case "claude-code": return "Claude Code"
        case "codex": return "Codex"
        default: return id
        }
    }

    /// Intentionally diverges from the daemon's `FrameBuilder.fmtTokens` /
    /// `fmtCost`: this row lives in a wide submenu and has room for full
    /// `.2f` cost precision and always-decimal token suffixes. The OLED
    /// frame is space-constrained and trades precision for compactness.
    /// Keep these two formatters separate — unifying would force one
    /// surface to compromise.
    private static func formatBreakdownSubtitle(tokens: Int, cost: Decimal) -> String {
        let dollars = NSDecimalNumber(decimal: cost).doubleValue
        return String(format: "%@ tok · $%.2f", formatTokens(tokens), dollars)
    }

    private static func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        }
        if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }

    /// Header subtitle for the menubar pull-down. Sums the provider slices
    /// the daemon shipped on the WS frame so the total here matches the sum
    /// of the Breakdown rows to the penny — same token formatter, same `%.2f`
    /// cost precision. Burn rate isn't per-provider so it passes through
    /// daemon-formatted.
    static func formatHeaderSubtitle(
        providers: [DisplayFrame.ProviderSlice],
        burn: String
    ) -> String? {
        var parts: [String] = []
        let totalTokens = providers.reduce(0) { $0 + $1.tokens }
        let totalCost = providers.reduce(Decimal(0)) { $0 + $1.cost }
        if totalTokens > 0 {
            parts.append("\(formatTokens(totalTokens)) tok")
        }
        let dollars = NSDecimalNumber(decimal: totalCost).doubleValue
        if totalCost > 0 || !providers.isEmpty {
            parts.append(String(format: "$%.2f", dollars))
        }
        if burn != "..." {
            parts.append("\(burn)/h")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func rebuildMascotSubmenu(_ submenu: NSMenu) {
        let snapshot = model.menuSnapshot
        submenu.removeAllItems()

        let autoActive = snapshot.pinnedMascot == nil
        let auto = NSMenuItem(title: "Auto", action: #selector(pickMascotAuto), keyEquivalent: "")
        auto.target = self
        auto.state = autoActive ? .on : .off
        auto.isEnabled = snapshot.canPickMascot || autoActive
        submenu.addItem(auto)

        submenu.addItem(.separator())

        for entry in SissyModel.mascotStates {
            let item = NSMenuItem(
                title: entry.label,
                action: #selector(pickMascot(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = entry.wire
            item.state = (snapshot.pinnedMascot == entry.wire) ? .on : .off
            item.isEnabled = snapshot.canPickMascot
            submenu.addItem(item)
        }

        submenu.addItem(.separator())

        let notify = NSMenuItem(
            title: "Show mood pop-up",
            action: #selector(toggleNotify),
            keyEquivalent: ""
        )
        notify.target = self
        notify.state = snapshot.notifyOnMascotChange ? .on : .off
        submenu.addItem(notify)
    }

    // MARK: Actions

    @objc private func handleServer() {
        model.toggleServerFromMenu()
        refreshTopLevelItems(model.menuSnapshot)
    }

    @objc private func pickMetric(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
            let value = Preferences.PrimaryMetric(rawValue: raw)
        else { return }
        model.selectMetric(value)
    }

    @objc private func pickMilestone(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
            let value = Preferences.MilestoneFrequency(rawValue: raw)
        else { return }
        model.selectMilestoneFrequency(value)
    }

    @objc private func pickMascotAuto() {
        model.clearMascotPin()
    }

    @objc private func pickMascot(_ sender: NSMenuItem) {
        guard let wire = sender.representedObject as? String else { return }
        model.pinMascot(wire)
    }

    @objc private func toggleNotify() {
        model.toggleNotifications()
    }

    @objc private func handlePair() {
        windowCoordinator.openPairingWindow()
    }

    @objc private func handleOpenLogs() {
        model.openLogs()
    }

    @objc private func handleAbout() {
        windowCoordinator.openAboutWindow()
    }

    @objc private func handleQuit() {
        NSApp.terminate(nil)
    }
}

extension StatusItemController: NSMenuDelegate {
    // NSMenuDelegate is `@MainActor` on macOS 26's Swift 6 AppKit so the
    // methods can be implemented as MainActor-isolated directly — no
    // `nonisolated` + `MainActor.assumeIsolated` ceremony needed, and no
    // Sendable warnings on the NSMenu parameter.
    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu {
            self.isMenuOpen = true
            self.refreshTopLevelItems(self.model.menuSnapshot)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === self.menu {
            self.isMenuOpen = false
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === self.menu {
            self.refreshTopLevelItems(self.model.menuSnapshot)
        } else if menu === self.metricItem.submenu {
            self.rebuildMetricSubmenu(menu)
        } else if menu === self.milestonesItem.submenu {
            self.rebuildMilestonesSubmenu(menu)
        } else if menu === self.mascotItem.submenu {
            self.rebuildMascotSubmenu(menu)
        } else if menu === self.breakdownItem.submenu {
            self.rebuildBreakdownSubmenu(menu)
        }
    }
}

private struct HeaderRowView: View {
    let header: SissyModel.HeaderSnapshot

    var body: some View {
        HStack(spacing: 10) {
            Image(header.imageName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(header.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let subtitle = header.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .opacity(header.isDimmed ? 0.55 : 1.0)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
