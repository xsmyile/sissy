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
    private var mascotAnimator: SissyMenuBarAnimator?
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
        configureMascotAnimator()
        observeModel()
        observeFrameArrivals()
        refreshIcon(model.menuSnapshot.statusIcon)
    }

    /// Canvas height the mascot is drawn at in the menu bar.
    ///
    /// The asset is a 22 pt canvas carrying 20 pt of ink, while an
    /// unconfigured SF Symbol — what most menu bar extras render — measures
    /// 15 pt. At its native size the mascot therefore reads a third taller
    /// than everything beside it. 17 pt of canvas puts the ink at ~15.5 pt,
    /// which sits with the system's own items.
    private static let menuBarIconSize: CGFloat = 17

    /// Shortest spacing between two data-driven blinks.
    private static let dataBlinkCooldown: TimeInterval = 3

    /// The image is assigned once: it never varies, and re-reading it on every
    /// model change would only hand back the same instance. That instance is
    /// the asset catalogue's shared one, so it is copied before resizing —
    /// mutating it would resize the mascot everywhere else it is drawn.
    private func configureButton() {
        guard let button = statusItem.button else { return }
        if let image = NSImage(named: SissyModel.mascotAssetName)?.copy() as? NSImage {
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
    /// static icon in place and the mascot simply never moves.
    private func configureMascotAnimator() {
        guard let button = statusItem.button else { return }
        do {
            let animator = try SissyMenuBarAnimator(button: button, iconSize: Self.menuBarIconSize)
            animator.canAnimate = { [weak self] in self?.isMenuOpen == false }
            // Snapped: a mascot that closes its eye a beat after the icon
            // appears would read as the daemon dying, not as it being off.
            animator.setPose(
                model.menuSnapshot.statusIcon.isAsleep ? .asleep : .awake,
                animated: false
            )
            mascotAnimator = animator
        } catch {
            NSLog("sissy: mascot motion unavailable: %@", error.localizedDescription)
        }
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
        mascotAnimator?.setPose(
            icon.isAsleep ? .asleep : .awake,
            animated: model.preferences.mascotMotion
        )
    }

    /// A blink when a frame lands is the mascot noticing new numbers.
    ///
    /// `lastFrameAt` carries the frame's own `ts`, which has second
    /// resolution, and `@Observable` suppresses an assignment that doesn't
    /// change the value — so a replayed frame is already silent. The cooldown
    /// covers what that leaves: the readers coalesce emits only down to
    /// `UsageReaderShared.pollEmitThrottle` (0.2 s), so a turn appending JSONL
    /// in bursts can push a frame a second, and a 380 ms gesture that often
    /// never lets the icon settle.
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
        guard model.preferences.mascotMotion,
            now.timeIntervalSince(lastDataBlinkAt) >= Self.dataBlinkCooldown,
            mascotAnimator?.blink() == true
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
