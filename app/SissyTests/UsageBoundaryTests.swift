import XCTest

@testable import Sissy

/// The edge where Sissy accepts what the CLIs write.
///
/// Named for the boundary rather than for one type because that is the unit:
/// `UsageReaderShared.tokenCount` and `UsageWindow.init?` are the two places a
/// value crosses from a third-party JSONL into Sissy's own numbers, and both
/// were reachable with a value that crashed the process.
final class UsageBoundaryTests: XCTestCase {

    // MARK: Token counts

    /// `Int.max` in a usage field crashed the reader: the per-day sum uses
    /// trapping arithmetic, and the file offset only advances once the whole
    /// chunk has been ingested, so the poisoned line was re-read — and
    /// re-trapped — on every relaunch.
    func testTokenCountClampsAValueThatWouldOverflowTheDailySum() {
        XCTAssertEqual(UsageReaderShared.tokenCount(Int.max), UsageReaderShared.maxTokenCount)
    }

    /// Codex derives uncached input as `input - cached`, so a negative field
    /// underflowed the subtraction rather than the sum.
    func testTokenCountFloorsANegativeValueAtZero() {
        XCTAssertEqual(UsageReaderShared.tokenCount(Int.min), 0)
        XCTAssertEqual(UsageReaderShared.tokenCount(-1), 0)
    }

    func testTokenCountPassesARealReadingThrough() {
        XCTAssertEqual(UsageReaderShared.tokenCount(14_297), 14_297)
    }

    func testTokenCountReadsAMissingOrNonNumericFieldAsZero() {
        XCTAssertEqual(UsageReaderShared.tokenCount(nil), 0)
        XCTAssertEqual(UsageReaderShared.tokenCount("12"), 0)
        XCTAssertEqual(UsageReaderShared.tokenCount(1.5), 0)
    }

    // MARK: Rate-limit windows

    /// `JSONSerialization` parses `-1e400` to `-infinity`, which reached
    /// `Int(_:)` in the panel and killed it on every render — and made
    /// `JSONEncoder` throw, taking snapshot persistence down with it.
    func testWindowRejectsANonFinitePercent() {
        XCTAssertNil(UsageWindow(minutes: 300, usedPercent: .infinity, resetsAt: .now))
        XCTAssertNil(UsageWindow(minutes: 300, usedPercent: -.infinity, resetsAt: .now))
        XCTAssertNil(UsageWindow(minutes: 300, usedPercent: .nan, resetsAt: .now))
    }

    func testWindowRejectsANonFiniteReset() {
        XCTAssertNil(
            UsageWindow(
                minutes: 300, usedPercent: 25,
                resetsAt: Date(timeIntervalSince1970: .infinity)))
    }

    func testWindowRejectsAPercentOutsideTheDrawableRange() {
        XCTAssertNil(UsageWindow(minutes: 300, usedPercent: -1, resetsAt: .now))
        XCTAssertNil(
            UsageWindow(
                minutes: 300,
                usedPercent: UsageWindow.maxUsedPercent + 1,
                resetsAt: .now))
    }

    /// An overage is real and the panel renders it, so validation must not
    /// quietly cap it — `UsagePanelSnapshotTests` pins 104.6% rendering as
    /// 105%.
    func testWindowKeepsAnOverageItCanStillDraw() throws {
        let window = try XCTUnwrap(
            UsageWindow(minutes: 300, usedPercent: 104.6, resetsAt: .now))
        XCTAssertEqual(window.usedPercent, 104.6)
    }

    // MARK: Per-file tracking

    private static let fresh = URL(fileURLWithPath: "/tmp/fresh.jsonl")
    private static let aged = URL(fileURLWithPath: "/tmp/aged.jsonl")

    /// The maps only ever shrank at relaunch: the enumerator re-admits an
    /// aged-out file *because* it still has an offset, so a session left
    /// running kept stat-ing every file it had ever read and writing a row
    /// for each into every snapshot.
    func testRetainedFilesDropsOneWrittenBeforeTheCutoff() {
        let retained = UsageReaderShared.retainedFiles(
            mtimes: [Self.fresh: 2_000, Self.aged: 500],
            cutoff: 1_000
        )
        XCTAssertEqual(retained, [Self.fresh])
    }

    func testRetainedFilesKeepsOneWrittenExactlyAtTheCutoff() {
        let retained = UsageReaderShared.retainedFiles(
            mtimes: [Self.fresh: 1_000],
            cutoff: 1_000
        )
        XCTAssertEqual(retained, [Self.fresh])
    }

    /// Nothing can vouch for when it was last written, and the enumerator
    /// would read it from zero anyway.
    func testRetainedFilesDropsOneWithNoRecordedMTime() {
        XCTAssertTrue(UsageReaderShared.retainedFiles(mtimes: [:], cutoff: 1_000).isEmpty)
    }
}
