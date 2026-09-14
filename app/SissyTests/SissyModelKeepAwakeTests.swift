import XCTest

@testable import Sissy

/// The mode belongs to the engine; the app asks and reports. These pin the
/// way that reporting can lie: a request retired by a frame that was never
/// answering it.
@MainActor
final class SissyModelKeepAwakeTests: XCTestCase {
    private func frame(_ keepAwake: KeepAwakeState) -> FrameData {
        FrameData(
            tokens: 26_000,
            cost: Decimal(string: "0.09")!,
            burn: 1500,
            providers: [],
            keepAwake: keepAwake,
            history: nil
        )
    }

    func testTheEnginesStateIsWhatTheControlShows() {
        let model = SissyModel()
        model.applyFrame(frame(KeepAwakeState(mode: .on, active: true)))

        XCTAssertEqual(model.keepAwake, KeepAwakeState(mode: .on, active: true))
    }

    /// Frames keep arriving on their own while an agent works, which is
    /// exactly when someone switches this on. One built before the engine saw
    /// the request must not flip the control back.
    func testAFrameThatDoesNotAnswerTheRequestLeavesItStanding() {
        let model = SissyModel()
        model.setKeepAwake(.on)
        model.applyFrame(frame(.off))

        XCTAssertEqual(model.keepAwake.mode, .on)
    }

    /// The optimistic window lies about the mode on purpose and about nothing
    /// else. An instant belongs to a hold the engine has actually taken, so a
    /// request it has not answered yet borrows none: the alternative starts a
    /// duration running on a Mac that is still free to sleep.
    func testAPendingRequestBorrowsNoInstant() {
        let model = SissyModel()
        model.setKeepAwake(.on)

        XCTAssertEqual(model.keepAwake.mode, .on)
        XCTAssertNil(model.keepAwake.since)
    }

    /// Switching off is pending the same way, and until the engine answers the
    /// hold is still in force — so the duration keeps running rather than
    /// blanking for the width of the window.
    func testAPendingReleaseKeepsTheRunningHoldsInstant() {
        let model = SissyModel()
        let since = Date(timeIntervalSinceNow: -600)
        model.applyFrame(frame(KeepAwakeState(mode: .on, active: true, since: since)))
        model.setKeepAwake(.off)

        XCTAssertEqual(model.keepAwake.mode, .off)
        XCTAssertEqual(model.keepAwake.since, since)
    }

    func testTheAnsweringFrameTakesOver() {
        let model = SissyModel()
        model.setKeepAwake(.on)
        model.applyFrame(frame(KeepAwakeState(mode: .on, active: true)))
        model.applyFrame(frame(.off))

        XCTAssertEqual(model.keepAwake, .off)
    }

    /// What the panel's button arms when it is clicked out of `off`. The menu
    /// on that button is the only place the choice is made, so a choice it
    /// does not carry forward means the click after a switch-off silently
    /// takes the other mode — a bounded hold becoming a permanent one.
    func testTheButtonArmsTheModeLastChosen() {
        let model = SissyModel()
        model.setKeepAwake(.auto)
        model.applyFrame(frame(KeepAwakeState(mode: .auto, active: true, since: Date())))
        model.setKeepAwake(.off)
        model.applyFrame(frame(.off))

        XCTAssertEqual(model.preferredKeepAwakeMode, .auto)
    }

    /// What a click arms before anything has told the app otherwise. The
    /// tooltip names this, so it is a promise rather than an internal default.
    func testTheColdTargetIsThePermanentMode() {
        XCTAssertEqual(SissyModel().preferredKeepAwakeMode, .on)
    }

    /// A hold does not survive the process but the mode does, so the target is
    /// re-learned from the first frame that reports an armed mode rather than
    /// staying at the cold default for the rest of the run.
    func testARelaunchLearnsTheTargetFromTheFirstArmedFrame() {
        let model = SissyModel()
        model.applyFrame(frame(KeepAwakeState(mode: .auto, active: false)))

        XCTAssertEqual(model.preferredKeepAwakeMode, .auto)
    }

    /// The optimistic window lies about the mode and must lie about nothing
    /// else. Dropping `coversScreen` there tells someone who just switched
    /// modes under a screen-covering hold that their screen is about to lock,
    /// for as long as the window lasts.
    func testAPendingRequestKeepsTheRunningHoldsScreenClause() {
        let model = SissyModel()
        model.applyFrame(
            frame(KeepAwakeState(mode: .on, active: true, since: Date(), coversScreen: true)))
        model.setKeepAwake(.auto)

        XCTAssertEqual(model.keepAwake.mode, .auto)
        XCTAssertTrue(model.keepAwake.coversScreen)
    }

    /// Switching off is not a choice of mode. The engine does it on its own
    /// when a manual hold reaches its ceiling, and a target reset by that
    /// would turn the next click into a different mode than the one the user
    /// had running a moment earlier.
    func testSwitchingOffLeavesTheTargetWhereItWas() {
        let model = SissyModel()
        model.setKeepAwake(.auto)
        model.applyFrame(frame(.off))

        XCTAssertEqual(model.preferredKeepAwakeMode, .auto)
    }
}
