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
    func testAReadingNamesSissyAndOwesTheLineBackToTheReadingsAge() {
        let header = SissyModel.HeaderSnapshot.make(hasFrame: true, isWarm: true, filesWatched: 12)

        XCTAssertFalse(header.isAsleep)
        XCTAssertEqual(header.title, "Sissy")
        XCTAssertNil(header.subtitle, "an awake Sissy owes the line back to the reading's age")
    }

    /// The one state that earns a sentence in the title: the Mac is being
    /// held, and it is being held because agents are working.
    func testAnAutomaticHoldSaysWhySissyIsUp() {
        let header = SissyModel.HeaderSnapshot.make(
            hasFrame: true, isWarm: true, filesWatched: 12, holdingForAgents: true)

        XCTAssertFalse(header.isAsleep)
        XCTAssertEqual(header.title, "Sissy is up with the agents")
    }

    /// Sissy asleep is Sissy with no reading, and a hold does not make one
    /// arrive — the sentence about the agents must not overwrite the one
    /// saying why the panel is empty.
    func testAHoldNeverOverwritesTheReasonThereIsNoReading() {
        let header = SissyModel.HeaderSnapshot.make(
            hasFrame: false, isWarm: true, filesWatched: 98, holdingForAgents: true)

        XCTAssertTrue(header.isAsleep)
        XCTAssertEqual(header.title, "Sissy is sleeping")
        XCTAssertEqual(header.subtitle, "Nothing spent yet today")
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

    /// A run with every provider switched off is warm with nothing to watch,
    /// so it reaches the same zero as a Mac with no logs on it. Told as the
    /// second, it sends someone looking at a log tree for a CLI they told
    /// Sissy not to read.
    func testNothingSwitchedOnIsNotTheSameAsNothingFound() {
        let header = SissyModel.HeaderSnapshot.make(
            hasFrame: false, isWarm: true, filesWatched: 0, isMetering: false)

        XCTAssertTrue(header.isAsleep)
        XCTAssertEqual(header.title, "Sissy is sleeping")
        XCTAssertEqual(header.subtitle, "No provider switched on")
    }

    /// The list is empty for the first moments of a launch as well, and an
    /// empty list is warm — so the cold-start sentence has to win, or every
    /// launch claims the user switched everything off.
    func testAColdStartIsNotMistakenForNothingSwitchedOn() {
        let header = SissyModel.HeaderSnapshot.make(
            hasFrame: false, isWarm: false, filesWatched: 0, isMetering: false)

        XCTAssertEqual(header.title, "Sissy is waking up")
        XCTAssertEqual(header.subtitle, "Reading your session logs")
    }

    /// The common case first thing in the morning, and the one that must not
    /// read as a fault.
    func testLogsButAnEmptyDaySaysSoWithoutBlamingAnything() {
        let header = SissyModel.HeaderSnapshot.make(hasFrame: false, isWarm: true, filesWatched: 98)

        XCTAssertTrue(header.isAsleep)
        XCTAssertEqual(header.subtitle, "Nothing spent yet today")
    }
}
