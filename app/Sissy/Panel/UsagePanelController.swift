import AppKit
import SwiftUI

/// Owns the usage panel: an `NSPopover` anchored to the status item, hosting
/// SwiftUI content.
///
/// A popover rather than a borderless `NSPanel` because it brings screen-edge
/// repositioning and menubar anchoring for free, and `hasFullSizeContent` lets
/// the hosted view own the whole surface including the chevron region. The
/// status item stays an `NSStatusItem` so the panel has a button to anchor to.
///
/// **`.transient` dismissal is conditional on activation, so it cannot be the
/// only way out.** A status-item click usually makes the app active and the
/// popover window key, and AppKit then closes the popover on the next
/// interaction outside it — that much was measured on macOS 26 and is why this
/// class went a while with nothing else. It is not guaranteed: the app is an
/// accessory that asks for no activation of its own, and a showing that does
/// not take it leaves the panel on screen through every click that follows.
/// Measured on macOS 27 against this build, driving the status item and then
/// Control Center with synthetic clicks — which open the panel without the app
/// ever reaching the front — the panel survived the outside click **6 times out
/// of 6**, and survived the one after it. What the user sees is a panel that
/// has visibly lost key, over an app it will not get out of the way of.
///
/// `outsideClickMonitor` is what makes dismissal unconditional. A *global*
/// monitor sees only events delivered to other processes, which is exactly the
/// set AppKit may miss: it never fires for a click inside the panel, on the
/// status item, or on one of the panel's own `Menu`s, so it cannot dismiss a
/// gesture that belongs to the panel. Mouse events need no authorization —
/// only a keyboard monitor would, and that would cost the first-run prompt
/// this app is built not to have.
///
/// Activating on open would also fix it and is what most menubar apps do, but
/// taking key here costs the app in front no menu bar (`_NSPopoverWindow` is an
/// `NSPanel` carrying `.nonactivatingPanel`, which is what the system's own
/// menu bar extras use) where activating would, and `AppDelegate` goes out of
/// its way to hand activation back. A read-only panel is no reason to start.
///
/// **The host lives only while the panel is on screen.** A closed popover keeps
/// its window, and a `contentViewController` left attached to it keeps a live
/// SwiftUI view graph in that window: `SissyModel` is `@Observable`, so every
/// frame the engine emits invalidated the panel, and `NSHostingView` answered
/// with a full layout and a rasterization of all 340 pt of it into a backing
/// store nobody could see. `PanelSissy` then turned each arrival into 23 of
/// those at 60 fps. Measured on macOS 26 against a Debug build with the panel
/// closed: 15% of a core on the main thread, 79% of it inside
/// `CA::Transaction::flush`. Building the host on open and dropping it on close
/// is what makes a closed panel free.
///
/// **It is laid out before it is shown.** The panel measures its own page to
/// decide where the screen's ceiling falls, and a measurement taken during
/// layout is not available to the pass that triggered it: measured on
/// macOS 26, the first `sizeThatFits` answers with the header alone and the
/// real height only on the pass after. The popover reads `preferredContentSize`
/// as it is shown, so without this it opens as a 45 pt stub and jumps.
@MainActor
final class UsagePanelController: NSObject {
    private let popover = NSPopover()
    private let model: SissyModel
    private var outsideClickMonitor: Any?

    init(model: SissyModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.hasFullSizeContent = true
        popover.delegate = self
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            close()
            return
        }
        let host = NSHostingController(
            rootView: UsagePanelView(
                model: model,
                maxHeight: PanelMetrics.maxHeight(on: button.window?.screen)))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        host.view.layoutSubtreeIfNeeded()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        startWatchingForOutsideClicks()
    }

    func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    /// Idempotent because a showing that replaces one still closing inherits
    /// the monitor rather than adding a second: both describe the same panel,
    /// and the one that is already installed is watching for the same click.
    ///
    /// The handler asserts its isolation rather than hopping onto the actor:
    /// the monitor is registered from the main run loop and fires on it, so
    /// the dismissal lands on the click's own turn instead of the one after.
    private func startWatchingForOutsideClicks() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func stopWatchingForOutsideClicks() {
        guard let outsideClickMonitor else { return }
        NSEvent.removeMonitor(outsideClickMonitor)
        self.outsideClickMonitor = nil
    }

    /// Whether a SwiftUI host is attached to the popover right now.
    ///
    /// The cost this class exists to avoid is entirely a function of this
    /// being true while nothing is on screen, so it is the thing worth
    /// asserting rather than the construction that produces it.
    var isHostingPanel: Bool { popover.contentViewController != nil }
}

/// `NSPopoverDelegate` is `@MainActor` on macOS 26's Swift 6 AppKit, so its
/// methods can be implemented as MainActor-isolated directly.
extension UsagePanelController: NSPopoverDelegate {
    /// Drops the host and the monitor the finished showing was built for.
    ///
    /// The guard rests on when `isShown` moves, which `NSPopover.h` pins to
    /// the *call*: a popover is shown "until the popover is closed in response
    /// to an invocation of either `-close` or `-performClose:`", not until the
    /// close animation ends. A second click inside that animation therefore
    /// passes `toggle`'s check and shows a new host before the first close's
    /// notification arrives — and this, running late, would clear the host of
    /// the showing that replaced it. A host exists exactly while a showing
    /// does, so a close that no longer describes the popover has nothing to
    /// drop.
    func popoverDidClose(_ notification: Notification) {
        guard !popover.isShown else { return }
        stopWatchingForOutsideClicks()
        popover.contentViewController = nil
    }
}
