import XCTest

@testable import Sissy

/// The mode belongs to the engine; the app asks and reports. These pin the
/// way that reporting can lie: a request retired by a frame that was never
/// answering it.
@MainActor
final class SissyModelKeepAwakeTests: XCTestCase {
    private func frame(_ keepAwake: KeepAwakeState) -> FrameData {
        FrameData(
            tokens: "26K",
            cost: "0.09",
            burn: "1.5K",
            providers: [],
            prevTokens: nil,
            prevCost: nil,
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
}
