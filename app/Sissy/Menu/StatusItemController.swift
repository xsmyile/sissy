import AppKit
import Observation
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
    private let pairItem = NSMenuItem(title: "Pair Device...", action: nil, keyEquivalent: "p")

    private var headerView: NSHostingView<HeaderRowView>?

    private static let rowWidth: CGFloat = 260

    private(set) var isMenuOpen: Bool = false
    var statusButton: NSStatusBarButton? { statusItem.button }
    /// Invoked on a plain left-click. The panel is owned by `AppDelegate`, so
    /// the status item only reports the gesture; a right- or control-click
    /// pops the configuration menu instead.
    var onPrimaryClick: (() -> Void)?

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
        button.target = self
        button.action = #selector(handleStatusButtonClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
    }

    private func buildMenu() {
        menu.autoenablesItems = false
        menu.delegate = self
        menu.removeAllItems()

        menu.addItem(headerItem)
        menu.addItem(.separator())

        serverItem.target = self
        serverItem.action = #selector(handleServer)
        menu.addItem(serverItem)

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
        observeModel()
    }

    /// Re-arming observation bridge. `@Observable` exposes no
    /// `objectWillChange`, so to keep the status-bar icon live while the menu
    /// is closed we track the snapshot's inputs and refresh on each change,
    /// re-registering the tracker every fire (`withObservationTracking` is
    /// one-shot). The async hop preserves the previous `objectWillChange`
    /// behaviour — the callback runs at `willSet` time, so the committed value
    /// is read on the next main-actor turn. Menu rows refresh independently
    /// through `NSMenuDelegate`.
    private func observeModel() {
        withObservationTracking {
            _ = model.menuSnapshot
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshFromModel()
                self.observeModel()
            }
        }
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
        serverItem.isEnabled = snapshot.server.isEnabled

        metricItem.subtitle = snapshot.primaryMetric.label
        setItemPresent(metricItem, present: snapshot.showMetric, after: serverItem)
    }

    /// Insert or remove `item` so it sits directly after `anchor`. Visibility
    /// is driven by structural mutation instead of `NSMenuItem.isHidden`
    /// because NSMenu re-flows on `insertItem`/`removeItem` mid-tracking but
    /// caches item rects across an `isHidden` flip — the latter produced a
    /// clipped row when the device connected while the menu was already on
    /// screen.
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

    // MARK: Actions

    @objc private func handleStatusButtonClick() {
        guard let event = NSApp.currentEvent else { return }
        let wantsMenu = event.type == .rightMouseUp || event.modifierFlags.contains(.control)
        if wantsMenu {
            showMenu()
        } else {
            onPrimaryClick?()
        }
    }

    /// Pops the configuration menu under the status item. Assigning
    /// `statusItem.menu` for the duration of the click is what keeps the
    /// menu's native placement and highlight; leaving it assigned would make
    /// every left-click open the menu too.
    func showMenu() {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

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
