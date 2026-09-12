import AppKit
import Observation
import SwiftUI

/// Owns the app's status item: the icon, the left-click that opens the usage
/// panel, and a right-click menu that holds the keep-awake mode and nothing
/// else the panel or the settings window already own.
@MainActor
final class StatusItemController: NSObject {
    let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let model: SissyModel
    private var sissyAnimator: SissyMenuBarAnimator?
    private var lastDataBlinkAt: Date = .distantPast

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
        configureSissyAnimator()
        observeModel()
        observeFrameArrivals()
        refreshIcon(model.menuSnapshot.statusIcon)
    }

    /// Canvas height Sissy is drawn at in the menu bar.
    ///
    /// The asset is a 22 pt canvas carrying 20 pt of ink, while an
    /// unconfigured SF Symbol — what most menu bar extras render — measures
    /// 15 pt. At its native size Sissy therefore reads a third taller
    /// than everything beside it. 17 pt of canvas puts the ink at ~15.5 pt,
    /// which sits with the system's own items.
    private static let menuBarIconSize: CGFloat = 17

    /// The image is assigned once: it never varies, and re-reading it on every
    /// model change would only hand back the same instance. That instance is
    /// the asset catalogue's shared one, so it is copied before resizing —
    /// mutating it would resize Sissy everywhere else she is drawn.
    private func configureButton() {
        guard let button = statusItem.button else { return }
        if let image = NSImage(named: SissyModel.sissyAssetName)?.copy() as? NSImage {
            image.size = NSSize(width: Self.menuBarIconSize, height: Self.menuBarIconSize)
            button.image = image
        }
        button.imagePosition = .imageOnly
        button.toolTip = "Sissy"
        button.wantsLayer = true
        button.target = self
        button.action = #selector(handleStatusButtonClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// Hands the button's image to the animator, which keeps the resting
    /// frame. A catalogue without the frames leaves `configureButton`'s
    /// static icon in place and Sissy simply never moves.
    private func configureSissyAnimator() {
        guard let button = statusItem.button else { return }
        do {
            let animator = try SissyMenuBarAnimator(button: button, iconSize: Self.menuBarIconSize)
            animator.canAnimate = { [weak self] in self?.isMenuOpen == false }
            // Snapped: closing her eye a beat after the icon
            // appears would read as her falling asleep, not as her starting
            // out that way.
            animator.setPose(
                model.menuSnapshot.statusIcon.isAsleep ? .asleep : .awake,
                animated: false
            )
            sissyAnimator = animator
        } catch {
            NSLog("sissy: motion unavailable: %@", error.localizedDescription)
        }
    }

    /// The three keep-awake modes, in the order the menu lists them: what the
    /// Mac does by itself, then the two ways Sissy can stop it.
    private static let keepAwakeItems: [(mode: KeepAwakeMode, title: String)] = [
        (.off, "Never"),
        (.auto, "While agents are working"),
        (.on, "Always"),
    ]

    /// The menu holds nothing the panel already owns, with one exception: the
    /// keep-awake mode.
    ///
    /// It is here because a hold nobody can see is a battery complaint with no
    /// path back to its cause, and the menu bar is the one surface that is
    /// always there — the panel has to be opened to say anything. Three modes
    /// also do not fit the panel's button, and a radio group is what macOS
    /// uses for a choice of one; the button stays the switch and this is where
    /// what it switches into is chosen.
    private func buildMenu() {
        menu.autoenablesItems = false
        menu.delegate = self

        let header = NSMenuItem()
        header.title = "Keep awake"
        header.isEnabled = false
        menu.addItem(header)

        for item in Self.keepAwakeItems {
            let entry = NSMenuItem(
                title: item.title, action: #selector(handleKeepAwake(_:)), keyEquivalent: "")
            entry.target = self
            entry.indentationLevel = 1
            entry.representedObject = item.mode.rawValue
            menu.addItem(entry)
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Sissy", action: #selector(handleQuit), keyEquivalent: "q")
        quit.target = self
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)
    }

    /// Ticks the mode in force and says underneath it what the Mac is actually
    /// doing, which are two different things: an automatic mode with no agents
    /// working is selected and holding nothing, and so is a mode whose
    /// assertion power management refused.
    private func refreshKeepAwakeItems() {
        let state = model.keepAwake
        for entry in menu.items {
            guard let raw = entry.representedObject as? String,
                let mode = KeepAwakeMode(rawValue: raw)
            else { continue }
            entry.state = mode == state.mode ? .on : .off
        }
        menu.items.first?.title = state.active ? "Keep awake — holding" : "Keep awake"
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
        sissyAnimator?.setPose(
            icon.isAsleep ? .asleep : .awake,
            animated: model.preferences.sissyMotion
        )
    }

    /// A blink when a frame lands is Sissy noticing new numbers.
    ///
    /// `lastFrameAt` carries the frame's own `ts`, which has second
    /// resolution, and `@Observable` suppresses an assignment that doesn't
    /// change the value — so a replayed frame is already silent.
    /// `SissyMenuBarMotion.dataBlinkCooldown` covers what that leaves. The
    /// panel's Sissy paces herself on the same constant, off her own clock:
    /// the two surfaces match in rhythm, not frame for frame.
    private func observeFrameArrivals() {
        withObservationTracking {
            _ = model.lastFrameAt
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.blinkForArrivedFrame()
                self.observeFrameArrivals()
            }
        }
    }

    private func blinkForArrivedFrame() {
        let now = Date()
        guard model.preferences.sissyMotion,
            now.timeIntervalSince(lastDataBlinkAt) >= SissyMenuBarMotion.dataBlinkCooldown,
            sissyAnimator?.blink() == true
        else { return }
        lastDataBlinkAt = now
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

    @objc private func handleKeepAwake(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
            let mode = KeepAwakeMode(rawValue: raw)
        else { return }
        model.setKeepAwake(mode)
    }

    @objc private func handleQuit() {
        NSApp.terminate(nil)
    }
}

extension StatusItemController: NSMenuDelegate {
    // NSMenuDelegate is `@MainActor` on macOS 26's Swift 6 AppKit so the
    // methods can be implemented as MainActor-isolated directly.
    /// The marks are refreshed on open rather than kept live: the menu is the
    /// only place that reads them, and a closed menu observing every frame
    /// would redraw items nobody is looking at.
    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        refreshKeepAwakeItems()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }
}
