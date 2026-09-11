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
@MainActor
final class UsagePanelController {
    private let popover = NSPopover()
    private var hostingController: NSHostingController<UsagePanelView>?

    var isOpen: Bool { popover.isShown }

    init(model: SissyModel) {
        popover.behavior = .transient
        popover.animates = true
        popover.hasFullSizeContent = true

        let root = UsagePanelView(model: model)
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        hostingController = controller
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            close()
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }
}
