import AppKit
import Observation
import SwiftUI

/// Owns the app's status item: the icon, the left-click that opens the usage
/// panel, and a right-click menu that holds nothing the panel or the settings
/// window already own.
@MainActor
final class StatusItemController: NSObject {
    let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let model: SissyModel

    private(set) var isMenuOpen: Bool = false
    var statusButton: NSStatusBarButton? { statusItem.button }
    /// Invoked on a plain left-click. The panel is owned by `AppDelegate`, so
    /// the status item only reports the gesture; a right- or control-click
    /// pops the menu instead.
    var onPrimaryClick: (() -> Void)?

    init(model: SissyModel) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.model = model
        super.init()

        buildMenu()
        configureButton()
        observeModel()
        refreshIcon(model.menuSnapshot.statusIcon)
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

    private func buildMenu() {
        menu.autoenablesItems = false
        menu.delegate = self

        let quit = NSMenuItem(title: "Quit Sissy", action: #selector(handleQuit), keyEquivalent: "q")
        quit.target = self
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)
    }

    /// Re-arming observation bridge. `@Observable` exposes no
    /// `objectWillChange`, so to keep the status-bar icon live we track the
    /// snapshot and refresh on each change, re-registering the tracker every
    /// fire (`withObservationTracking` is one-shot). The async hop preserves
    /// the previous `objectWillChange` behaviour — the callback runs at
    /// `willSet` time, so the committed value is read on the next
    /// main-actor turn.
    private func observeModel() {
        withObservationTracking {
            _ = model.menuSnapshot
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshIcon(self.model.menuSnapshot.statusIcon)
                self.observeModel()
            }
        }
    }

    private func refreshIcon(_ icon: SissyModel.StatusIconSnapshot) {
        guard let button = statusItem.button else { return }
        let image = NSImage(named: icon.imageName)
        image?.isTemplate = true
        button.image = image
        button.alphaValue = icon.alpha
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

    /// Pops the menu under the status item. Assigning `statusItem.menu` for
    /// the duration of the click is what keeps the menu's native placement
    /// and highlight; leaving it assigned would make every left-click open
    /// the menu too.
    func showMenu() {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func handleQuit() {
        NSApp.terminate(nil)
    }
}

extension StatusItemController: NSMenuDelegate {
    // NSMenuDelegate is `@MainActor` on macOS 26's Swift 6 AppKit so the
    // methods can be implemented as MainActor-isolated directly.
    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }
}
