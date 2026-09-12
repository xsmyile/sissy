import XCTest

@testable import Sissy

/// The one switch on the page that makes macOS put up a dialog. Sissy's first
/// run asks for nothing, and this caption is what keeps that promise intact
/// when the user flips it: a prompt the app did not warn about reads as a
/// surprise from something that was supposed to ask for nothing.
///
/// Which is why the warning is asserted against the *visible* line rather than
/// against both halves together — moving it into the popover would pass a test
/// that only checked the text still existed somewhere.
final class ClaudeLimitsCopyTests: XCTestCase {
    func testTheVisibleCaptionWarnsThatMacOSWillAsk() {
        XCTAssertTrue(
            ClaudeLimitsCopy.caption.contains("macOS will ask"),
            "the line on screen stopped warning about the permission prompt"
        )
    }

    func testTheVisibleCaptionSaysWhatTheSwitchIsFor() {
        XCTAssertTrue(
            ClaudeLimitsCopy.caption.contains("5-hour and weekly"),
            "the line on screen stopped saying what the switch actually shows"
        )
    }

    /// Reading someone's keychain is worth a promise in writing, even when the
    /// promise is a click away rather than on screen.
    func testTheDetailKeepsTheReadOnlyGuarantee() {
        XCTAssertTrue(
            ClaudeLimitsCopy.detail.contains("never writes or refreshes"),
            "the read-only promise about the user's keychain went missing"
        )
    }

    /// A permission bound to the binary lapses on every update, so someone who
    /// has just updated Sissy needs that to read as expected rather than as a
    /// fault.
    func testTheDetailSetsTheExpectationAfterAnUpdate() {
        XCTAssertTrue(
            ClaudeLimitsCopy.detail.contains("after an update"),
            "nothing left to tell someone the permission lapses after an update"
        )
    }

    /// The promise this whole change exists to keep: Sissy does not re-ask by
    /// itself. A copy that still said macOS would ask again would describe an
    /// app that raises dialogs at launch, which is the behaviour that was
    /// removed.
    func testTheDetailPromisesSissyNeverReAsksOnItsOwn() {
        XCTAssertTrue(
            ClaudeLimitsCopy.detail.contains("never asks again on its own"),
            "the promise that a launch raises no dialog went missing"
        )
        XCTAssertTrue(
            ClaudeLimitsCopy.detail.contains("off and back on"),
            "nothing left to tell someone how to ask for the limits back"
        )
    }
}
