import XCTest

@testable import Sissy

/// Sissy's face and the header's words are one signal: the eye is shut
/// exactly when the header says she is asleep, and the second line says why
/// only while she is. Anything else and the panel contradicts the menu bar.
///
/// Three ways to have nothing, and they are not interchangeable — one is
/// still working, one is a fault worth acting on, one is an ordinary empty
/// morning.
final class SissyModelHeaderTests: XCTestCase {
    func testAReadingNamesSissyAndOwesTheLineBackToTheDate() {
        let header = SissyModel.HeaderSnapshot.make(hasFrame: true, isWarm: true, filesWatched: 12)

        XCTAssertFalse(header.isAsleep)
        XCTAssertEqual(header.title, "Sissy")
        XCTAssertNil(header.subtitle, "an awake Sissy owes the line back to the date")
    }

    /// Warmth is what separates this from the two below: until the readers
    /// finish, "no files" is a number nobody has measured yet.
    func testAColdScanSaysItIsStillReading() {
        let header = SissyModel.HeaderSnapshot.make(hasFrame: false, isWarm: false, filesWatched: 0)

        XCTAssertTrue(header.isAsleep)
        XCTAssertEqual(header.title, "Sissy is waking up")
        XCTAssertEqual(header.subtitle, "Reading your session logs")
    }

    func testNoLogsAtAllIsNamedAsSuch() {
        let header = SissyModel.HeaderSnapshot.make(hasFrame: false, isWarm: true, filesWatched: 0)

        XCTAssertTrue(header.isAsleep)
        XCTAssertEqual(header.subtitle, "No session logs found")
    }

    /// The common case first thing in the morning, and the one that must not
    /// read as a fault.
    func testLogsButAnEmptyDaySaysSoWithoutBlamingAnything() {
        let header = SissyModel.HeaderSnapshot.make(hasFrame: false, isWarm: true, filesWatched: 98)

        XCTAssertTrue(header.isAsleep)
        XCTAssertEqual(header.subtitle, "Nothing spent yet today")
    }
}
