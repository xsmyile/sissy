import SwiftUI

/// LSUIElement (menu-bar-only) app. The dropdown is built in AppKit by
/// `StatusItemController` (`NSStatusItem` + `NSMenu`) so submenus, selection,
/// key equivalents, and dismissal stay native. The only hosted menu row is the
/// non-interactive header.
///
/// SwiftUI's `App` protocol requires at least one Scene; for an LSUIElement
/// app a `Settings` scene with empty content is invisible and cheap.
/// Window management for Pair Device and About lives in `WindowCoordinator`;
/// `AppDelegate` only bootstraps the runtime objects.
@main
struct SissyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
