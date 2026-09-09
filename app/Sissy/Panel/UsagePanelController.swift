import AppKit
import SwiftUI

/// Owns the usage panel: an `NSPopover` anchored to the status item, hosting
/// SwiftUI content.
///
/// A popover rather than a borderless `NSPanel` because it brings
/// click-outside dismissal, screen-edge repositioning and menubar anchoring
/// for free, and `hasFullSizeContent` lets the hosted view own the whole
/// surface including the chevron region. The status item stays an
/// `NSStatusItem`, which is what keeps `MascotNotifier`'s button anchor
/// working.
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
        if popover.isShown {
            popover.performClose(nil)
        }
    }
}
