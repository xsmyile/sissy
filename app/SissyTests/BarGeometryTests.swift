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

    func testSegmentsSplitTheFillInProportionToTheirShares() {
        XCTAssertEqual(BarGeometry.segmentWidths([0.75, 0.25], in: 100), [75, 25])
    }

    /// The shares are of the day and the fill is the row's share of it, so the
    /// segments are laid out against each other rather than against the bar —
    /// otherwise a row worth a tenth of the day would draw two stubs.
    func testSegmentsFillTheWidthTheyAreGivenWhateverTheySumTo() {
        XCTAssertEqual(BarGeometry.segmentWidths([0.06, 0.02], in: 100), [75, 25])
    }

    /// Three thirds rounded independently leave a hairline of track inside a
    /// fill that is meant to be solid, so the last one takes what is left.
    func testTheLastSegmentTakesTheRemainder() {
        let widths = BarGeometry.segmentWidths([1, 1, 1], in: 10)

        XCTAssertEqual(widths.reduce(0, +), 10, accuracy: 0.0001)
    }

    /// The caller zips these against its own segments, so a share of nothing
    /// keeps its place rather than tinting the next one.
    func testASegmentOfNothingKeepsItsPlace() {
        XCTAssertEqual(BarGeometry.segmentWidths([1, 0], in: 100), [100, 0])
    }

    func testAFillOfNothingHasNoSegments() {
        XCTAssertEqual(BarGeometry.segmentWidths([0.5, 0.5], in: 0), [0, 0])
    }
}
