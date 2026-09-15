import XCTest

@testable import Sissy

/// The panel's numbers and its "updated Ns ago" line are one reading, so they
/// hang off one gate: a frame and the moment it landed, or neither.
@MainActor
final class SissyModelLiveFrameTests: XCTestCase {
    private static let landedAt = Date(timeIntervalSince1970: 1_789_000_000)

    private func frame() -> FrameData {
        FrameData(
            tokens: 26_000,
            cost: Decimal(string: "0.09")!,
            burn: 1500,
            providers: [],
            keepAwake: .off,
            history: [:]
        )
    }

    func testLiveFrameCarriesTheFrameAndWhenItLanded() {
        let model = SissyModel()
        model.currentFrame = frame()
        model.lastFrameAt = Self.landedAt

        XCTAssertEqual(model.liveFrame?.at, Self.landedAt)
        XCTAssertEqual(model.liveFrame?.frame.tokens, 26_000)
    }

    func testNoFrameMeansNoReading() {
        XCTAssertNil(SissyModel().liveFrame)
    }
}
