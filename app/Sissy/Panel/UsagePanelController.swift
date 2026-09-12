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
/// `.transient` needs no help here. Measured on macOS 26: showing the popover
/// from a status-item click makes the app active and the popover window key,
/// and AppKit then closes it on the next interaction outside it and drops
/// activation on the way out. Taking key costs the app in front no menu bar —
/// `_NSPopoverWindow` is an `NSPanel` carrying `.nonactivatingPanel`, which is
/// what the system's own menu bar extras use. This class carried a global
/// mouse-event monitor for a while, on the reading that an accessory app never
/// activates and so never sees the click that dismisses a transient popover;
/// the monitor duplicated what AppKit was already doing.
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
@MainActor
final class UsagePanelController: NSObject {
    private let popover = NSPopover()
    private let model: SissyModel

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
        let host = NSHostingController(rootView: UsagePanelView(model: model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
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
    /// Drops the host the finished showing was built for.
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
        popover.contentViewController = nil
    }
}
