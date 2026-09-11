import ServiceManagement
import XCTest

@testable import Sissy

/// The mode belongs to the daemon; the app asks and reports. These pin the
/// two ways that reporting can lie — a state that outlives the daemon, and a
/// request retired by a frame that was never answering it.
@MainActor
final class SissyModelKeepAwakeTests: XCTestCase {
    /// Pins `SMAppService` to a plist the bundle does not carry, so the model
    /// derives the server state from health alone rather than from whichever
    /// agent happens to be installed on the machine running the tests.
    private func makeModel() -> SissyModel {
        SissyModel(
            serverService: ServerServiceController(
                service: .agent(plistName: "com.radonforge.sissy.tests.absent.plist")
            )
        )
    }

    private func frame(_ keepAwake: KeepAwakeState) -> FrameData {
        FrameData(
            tokens: "26K",
            cost: "0.09",
            burn: "1.5K",
            primary: "26K",
            primaryLabel: "TOKENS",
            providers: [],
            prevTokens: nil,
            prevCost: nil,
            keepAwake: keepAwake
        )
    }

    func testTheDaemonsStateIsWhatTheControlShows() {
        let model = makeModel()
        model.serverHealth.status = .up
        model.applyFrame(frame(KeepAwakeState(mode: .on, active: true)))

        XCTAssertEqual(model.keepAwake, KeepAwakeState(mode: .on, active: true))
    }

    func testTheStateIsWithheldOnceTheServerIsOff() {
        let model = makeModel()
        model.serverHealth.status = .up
        model.applyFrame(frame(KeepAwakeState(mode: .on, active: true)))
        model.serverHealth.status = .down

        XCTAssertEqual(model.keepAwake, .off)
    }

    /// Frames keep arriving on their own while an agent works, which is
    /// exactly when someone switches this on. One built before the daemon saw
    /// the request must not flip the control back.
    func testAFrameThatDoesNotAnswerTheRequestLeavesItStanding() {
        let model = makeModel()
        model.serverHealth.status = .up
        model.setKeepAwake(.on)
        model.applyFrame(frame(.off))

        XCTAssertEqual(model.keepAwake.mode, .on)
    }

    func testTheAnsweringFrameTakesOver() {
        let model = makeModel()
        model.serverHealth.status = .up
        model.setKeepAwake(.on)
        model.applyFrame(frame(KeepAwakeState(mode: .on, active: true)))
        model.applyFrame(frame(.off))

        XCTAssertEqual(model.keepAwake, .off)
    }
}
