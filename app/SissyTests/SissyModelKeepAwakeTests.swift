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
            keepAwake: keepAwake
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

    func testTheAnsweringFrameTakesOver() {
        let model = SissyModel()
        model.setKeepAwake(.on)
        model.applyFrame(frame(KeepAwakeState(mode: .on, active: true)))
        model.applyFrame(frame(.off))

        XCTAssertEqual(model.keepAwake, .off)
    }
}
