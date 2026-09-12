import XCTest

@testable import Sissy

/// A panel nobody has opened costs nothing.
///
/// The host is what makes it cost something: attached to the popover it keeps
/// a live SwiftUI view graph in a window that is not on screen, and every
/// frame the engine emits then buys a layout and a rasterization of the whole
/// panel. Measured on macOS 26 before this was fixed: 8.7% of a core, with the
/// panel closed and the app otherwise idle.
@MainActor
final class UsagePanelControllerTests: XCTestCase {
    func testAPanelThatHasNeverBeenOpenedHoldsNoHost() {
        let controller = UsagePanelController(model: SissyModel())

        XCTAssertFalse(
            controller.isHostingPanel,
            "building the host up front is what made a closed panel render at 60 fps")
    }
}
