import XCTest

@testable import Sissy

/// The row has one job: answer "why is this provider not in my panel". The
/// four ways to have nothing are not interchangeable, and each names the path
/// so the answer is actionable rather than a verdict.
final class ProviderRowSnapshotTests: XCTestCase {
    private func readiness(
        id: String = ProviderID.claudeCode,
        activation: ProviderActivation,
        dataDir: String = "/tmp/sissy-tests/projects",
        scan: ProviderReadiness.ScanProgress? = nil
    ) -> ProviderReadiness {
        ProviderReadiness(
            id: id,
            activation: activation,
            dataDir: URL(fileURLWithPath: dataDir),
            scan: scan
        )
    }

    func testTheRowIsNamedByTheAppNotByItsID() {
        let row = ProviderRowSnapshot.make(
            readiness(id: ProviderID.codex, activation: .on, scan: .init(filesWatched: 3, isWarm: true))
        )

        XCTAssertEqual(row.name, "Codex")
    }

    func testAWarmProviderCountsWhatItIsWatching() {
        let row = ProviderRowSnapshot.make(
            readiness(activation: .on, scan: .init(filesWatched: 12, isWarm: true))
        )

        XCTAssertEqual(row.state, "On")
        XCTAssertEqual(row.detail, "12 session files in /tmp/sissy-tests/projects")
    }

    func testOneFileIsNotCalledOneFiles() {
        let row = ProviderRowSnapshot.make(
            readiness(activation: .on, scan: .init(filesWatched: 1, isWarm: true))
        )

        XCTAssertEqual(row.detail, "1 session file in /tmp/sissy-tests/projects")
    }

    /// Until the scan finishes, "no files" is a number nobody has measured.
    func testAColdScanSaysItIsStillReadingRatherThanZero() {
        let row = ProviderRowSnapshot.make(
            readiness(activation: .on, scan: .init(filesWatched: 0, isWarm: false))
        )

        XCTAssertEqual(row.detail, "Reading your session logs")
    }

    /// The distinction the tab exists for: a dir that is there and empty is a
    /// different problem from one that is not there at all.
    func testAnEmptyDirAndAMissingDirDoNotReadAlike() {
        let empty = ProviderRowSnapshot.make(
            readiness(activation: .on, scan: .init(filesWatched: 0, isWarm: true))
        )
        let missing = ProviderRowSnapshot.make(readiness(activation: .autoNotFound))

        XCTAssertEqual(empty.detail, "No session logs in /tmp/sissy-tests/projects")
        XCTAssertEqual(missing.state, "Not found")
        XCTAssertEqual(missing.detail, "/tmp/sissy-tests/projects does not exist")
    }

    func testAutoDetectionSaysSoRatherThanClaimingTheUserAskedForIt() {
        let row = ProviderRowSnapshot.make(
            readiness(activation: .autoDetected, scan: .init(filesWatched: 4, isWarm: true))
        )

        XCTAssertEqual(row.state, "On, detected")
    }

    /// There is no switch on this page yet, so the row has to say where the
    /// one that turned it off actually lives.
    func testAProviderSwitchedOffNamesWhereItWasSwitchedOff() {
        let row = ProviderRowSnapshot.make(readiness(activation: .off))

        XCTAssertEqual(row.state, "Off")
        XCTAssertEqual(row.detail, "Switched off in server.json")
    }
}
