import AppKit
import Observation
import SwiftUI

/// Owns the app's status item: the icon, the left-click that opens the usage
/// panel, and a right-click menu that says whether the Mac is being held awake,
/// and quits.
@MainActor
final class StatusItemController: NSObject {
    let statusItem: NSStatusItem
    private let menu = NSMenu()
    /// The hold readout and the rule under it, kept as references rather than
    /// found by index: both are hidden together whenever nothing is held.
    private let holdItem = NSMenuItem()
    private let holdSeparator = NSMenuItem.separator()

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

    /// What the Mac is doing about sleep, a re-read of everything, and quit.
    ///
    /// The three modes used to hang here as a radio group, on the grounds that
    /// the menu bar is the one surface always present while every other way to
    /// the mode needed a window opened first. The panel is one left-click away
    /// and now says the hold in its own header, so that grounds is gone and a
    /// third place to *change* the mode is duplication. What is kept is the
    /// diagnostic — a hold nobody can see is a battery complaint with no path
    /// back to its cause — and it is shown only when there is a hold to
    /// report, because an "off" nobody switched on is not news.
    private func buildMenu() {
        menu.autoenablesItems = false
        menu.delegate = self

        holdItem.isEnabled = false
        menu.addItem(holdItem)
        menu.addItem(holdSeparator)

        let refresh = NSMenuItem(
            title: Self.refreshAllTitle, action: #selector(handleRefreshAll), keyEquivalent: "r")
        refresh.target = self
        refresh.keyEquivalentModifierMask = [.command]
        menu.addItem(refresh)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Sissy", action: #selector(handleQuit), keyEquivalent: "q")
        quit.target = self
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)
    }

    /// Says what the Mac is actually doing rather than which mode is selected,
    /// which are two different things: an automatic mode with no agents
    /// working is selected and holding nothing, and so is a mode whose
    /// assertion power management refused. Neither is a hold, so neither
    /// shows a line.
    private func refreshHoldItem() {
        let state = model.keepAwake
        guard state.active, let since = state.since else {
            holdItem.isHidden = true
            holdSeparator.isHidden = true
            return
        }
        holdItem.title = UsageFormat.keepAwakeHolding(Date().timeIntervalSince(since))
        holdItem.isHidden = false
        holdSeparator.isHidden = false
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
        sissyAnimator?.setArtwork(artwork(for: icon))
    }

    /// The lit eye is the one thing on the button that is not a template
    /// image, and an open menu is the one moment that matters: AppKit inverts
    /// a template to white against the highlight and leaves anything else
    /// exactly as it is, which in a light menu bar is a black cat on a filled
    /// row. The menu is also the surface that says the hold in words, so
    /// nothing is lost by handing the template back for as long as it is up.
    private func artwork(for icon: SissyModel.StatusIconSnapshot)
        -> SissyMenuBarAnimator.Artwork
    {
        icon.isHolding && !isMenuOpen ? .lit : .template
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

    /// Every reading the panel's pages re-read one at a time, in one gesture.
    /// Here rather than on the panel because it answers for no one page: the
    /// menu is the app's own surface, and each page keeps its own button.
    private static let refreshAllTitle = "Refresh All"

    @objc private func handleRefreshAll() {
        model.refreshAll()
    }

    @objc private func handleQuit() {
        NSApp.terminate(nil)
    }
}

extension StatusItemController: NSMenuDelegate {
    // NSMenuDelegate is `@MainActor` on macOS 26's Swift 6 AppKit so the
    // methods can be implemented as MainActor-isolated directly.
    /// The hold line is built on open rather than kept live: the menu is the
    /// only place that reads it, and a closed menu observing every frame would
    /// redraw an item nobody is looking at. It also means the elapsed time is
    /// read at the moment it is shown, which is the only moment it is true.
    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        refreshHoldItem()
        refreshIcon(model.menuSnapshot.statusIcon)
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        refreshIcon(model.menuSnapshot.statusIcon)
    }
}
