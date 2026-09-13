import XCTest

@testable import Sissy

/// The two placements the panel's bar has to get right, asserted without
/// rendering: how wide the fill is, and where the pace mark lands.
final class BarGeometryTests: XCTestCase {
    private let width: CGFloat = 312

    func testAShareOfNothingDrawsNothing() {
        XCTAssertEqual(BarGeometry.fillWidth(0, in: width), 0)
    }

    func testAShareTooSmallToSeeStillDrawsAStub() {
        XCTAssertEqual(BarGeometry.fillWidth(0.0001, in: width), 3)
    }

    func testAFullShareStopsAtTheBar() {
        XCTAssertEqual(BarGeometry.fillWidth(1.2, in: width), width)
    }

    func testTheMarkSitsWhereTheWindowHasReached() {
        XCTAssertEqual(BarGeometry.markCentre(0.5, in: width), width / 2)
    }

    func testAWindowInItsLastMinutesDrawsAWholeMark() {
        XCTAssertEqual(
            BarGeometry.markCentre(1, in: width), width - BarGeometry.markGap / 2)
    }

    func testAWindowThatHasJustResetDrawsAWholeMark() {
        XCTAssertEqual(BarGeometry.markCentre(0, in: width), BarGeometry.markGap / 2)
    }

    func testABarTooNarrowToInsetTheMarkCentresIt() {
        XCTAssertEqual(BarGeometry.markCentre(0.9, in: 4), 2)
    }
}
