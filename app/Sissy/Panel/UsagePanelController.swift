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
/// Click-outside dismissal is *not* free here — see `outsideClickMonitor`.
@MainActor
final class UsagePanelController: NSObject {
    private let popover = NSPopover()
    private var hostingController: NSHostingController<UsagePanelView>?
    /// Closes the panel on a click that landed in another application.
    ///
    /// `.transient` dismisses only on events AppKit delivers to this process,
    /// and this app is an accessory that never activates to show the panel —
    /// so the click that lands on someone else's window is never ours to see
    /// and the panel stayed open behind whatever the user clicked next. A
    /// global monitor sees exactly those events: clicks inside the panel, and
    /// on the status item, are delivered to us and never reach it.
    ///
    /// Activating the app on open would also make `.transient` work, and is
    /// what most menubar apps do — but this one deliberately never takes
    /// focus from the app in front (see `AppDelegate`'s activation yield), and
    /// opening a read-only panel is no reason to start.
    private var outsideClickMonitor: Any?

    var isOpen: Bool { popover.isShown }

    init(model: SissyModel) {
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.hasFullSizeContent = true
        popover.delegate = self

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
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            // Event monitors added to the main run loop fire on the main
            // thread, which is what lets this hop straight onto the actor
            // instead of deferring the dismissal by a run-loop turn.
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        if popover.isShown {
            popover.performClose(nil)
        }
        removeOutsideClickMonitor()
    }

    private func removeOutsideClickMonitor() {
        guard let outsideClickMonitor else { return }
        NSEvent.removeMonitor(outsideClickMonitor)
        self.outsideClickMonitor = nil
    }
}

extension UsagePanelController: NSPopoverDelegate {
    /// Drops the monitor on every close, not only the ones this class asked
    /// for: `.transient` still dismisses on in-app events, and nothing
    /// guarantees that route came through `close()`.
    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
    }
}
