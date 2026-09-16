import XCTest

@testable import Sissy

/// The pass that fills the archive in from days the live tail never reached.
///
/// Driven through a real tree and the real Claude Code adapter, for the reason
/// `UsageHistoryTailTests` is: the whole value of a backfilled day is that it
/// agrees with what the tail would have metered, which a stubbed provider
/// could not show.
final class UsageBackfillTests: XCTestCase {
    private var logDir: URL!
    private var stateDir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-backfill-\(UUID().uuidString)")
        logDir = base.appendingPathComponent("logs")
        stateDir = base.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: logDir.deletingLastPathComponent())
    }

    private static let tokensPerTurn = 1_000_000
    private static let model = "claude-sonnet-4-6"
    private static let unpricedModel = "claude-from-a-future-nobody-shipped"
    private static let retentionDays = 30

    private func day(_ offset: Int) throws -> Date {
        let cal = Calendar.current
        return try XCTUnwrap(
            cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date())))
    }

    private func dayKey(_ offset: Int) throws -> String {
        UsageReaderShared.dayFormatter.string(from: try day(offset))
    }

    /// Places one turn in the tree, stamped at noon of the day `offset` days
    /// from today so it cannot drift across a local midnight.
    @discardableResult
    private func writeTurn(
        _ name: String,
        requestId: String,
        dayOffset: Int,
        model: String = UsageBackfillTests.model
    ) throws -> URL {
        let cal = Calendar.current
        let when = try XCTUnwrap(
            cal.date(byAdding: .hour, value: 12, to: try day(dayOffset)))
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let line = """
            {"type":"assistant","timestamp":"\(iso.string(from: when))",\
            "requestId":"\(requestId)","message":{"model":"\(model)",\
            "usage":{"input_tokens":\(Self.tokensPerTurn),"output_tokens":0,\
            "cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
            """
        let url = logDir.appendingPathComponent(name)
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: when], ofItemAtPath: url.path)
        return url
    }

    private func runBackfill() async throws -> Int {
        let window = try XCTUnwrap(
            ArchiveBackfill.window(retentionDays: Self.retentionDays))
        let provider = LocalUsageProvider.claudeCode(
            claudeDir: logDir,
            historyRoot: stateDir,
            backfill: window
        )
        return await provider.backfillArchive()
    }

    private func archived(_ offset: Int) throws -> UsageHistoryDay? {
        UsageHistoryStore.load(
            provider: ProviderID.claudeCode, day: try dayKey(offset), in: stateDir)
    }

    func testTheWindowEndsWhereTheLiveTailsBegins() throws {
        let cal = Calendar.current
        let window = try XCTUnwrap(
            ArchiveBackfill.window(
                retentionDays: Self.retentionDays, liveRetainDays: 2, now: Date(),
                calendar: cal))
        XCTAssertEqual(window.lowerBound, try day(-(Self.retentionDays - 1)))
        XCTAssertEqual(
            window.upperBound, try day(-1),
            "the newest day a pass writes is the one the tail's rolling window cuts in half")
    }

    func testTheWindowStartsWhereRetentionDoes() throws {
        let window = try XCTUnwrap(ArchiveBackfill.window(retentionDays: Self.retentionDays))
        UsageHistoryStore.prune(keeping: Self.retentionDays, in: stateDir)
        XCTAssertEqual(
            window.lowerBound, try day(-(Self.retentionDays - 1)),
            "a pass that reached further back would write a day the next prune deletes")
    }

    func testAnArchiveThatIsSwitchedOffHasNoWindow() {
        XCTAssertNil(ArchiveBackfill.window(retentionDays: 0))
    }

    func testAPassArchivesTheDaysTheTailNeverReached() async throws {
        try writeTurn("old.jsonl", requestId: "r-old", dayOffset: -10)
        try writeTurn("older.jsonl", requestId: "r-older", dayOffset: -20)

        let written = try await runBackfill()
        XCTAssertEqual(written, 2)
        for offset in [-10, -20] {
            let day = try XCTUnwrap(try archived(offset), "day \(offset) was not archived")
            XCTAssertEqual(day.totalTokens, Self.tokensPerTurn)
        }
    }

    func testAPassLeavesTheDaysTheTailOwnsToTheTail() async throws {
        try writeTurn("today.jsonl", requestId: "r-today", dayOffset: 0)
        try writeTurn("yesterday.jsonl", requestId: "r-yesterday", dayOffset: -1)
        try writeTurn("older.jsonl", requestId: "r-older", dayOffset: -3)

        let written = try await runBackfill()
        XCTAssertEqual(written, 1, "only the day outside the tail's window is the pass's to write")
        XCTAssertNil(try archived(0))
        XCTAssertNil(try archived(-1))
        XCTAssertNotNil(try archived(-3))
    }

    func testAPassWritesNoSnapshot() async throws {
        try writeTurn("old.jsonl", requestId: "r-old", dayOffset: -5)
        _ = try await runBackfill()

        let contents = try FileManager.default.contentsOfDirectory(atPath: stateDir.path)
        XCTAssertEqual(
            contents.filter { $0.hasPrefix("usage-state") }, [],
            "the tail resumes from the byte it left off at whether a pass ran or not")
    }

    func testADayHoldingAModelNoRateCoversIsAbsentRatherThanShort() async throws {
        try writeTurn("priced.jsonl", requestId: "r-priced", dayOffset: -6)
        try writeTurn(
            "unpriced.jsonl", requestId: "r-unpriced", dayOffset: -6,
            model: Self.unpricedModel)
        try writeTurn("clean.jsonl", requestId: "r-clean", dayOffset: -7)

        _ = try await runBackfill()
        XCTAssertNil(
            try archived(-6),
            "a day written short is frozen short, and absence is the recoverable answer")
        XCTAssertNotNil(try archived(-7), "the day beside it is unaffected")
    }

    func testAPassRewritesItsOwnDaysWithTheSameNumbers() async throws {
        try writeTurn("old.jsonl", requestId: "r-old", dayOffset: -8)
        _ = try await runBackfill()
        let first = try XCTUnwrap(try archived(-8))

        _ = try await runBackfill()
        let second = try XCTUnwrap(try archived(-8))
        XCTAssertEqual(first.models, second.models, "a whole-day write replaces, never accumulates")
    }

    func testAnEmptyLedgerOwesAPass() throws {
        let ledger = ArchiveBackfillLedger()
        XCTAssertTrue(ledger.isDue(provider: ProviderID.claudeCode, coveringFrom: try day(-29)))
    }

    func testALedgerThatCoveredTheWindowOwesNothing() throws {
        let ledger = ArchiveBackfillLedger()
            .recording(provider: ProviderID.claudeCode, coveredFrom: try day(-29))
        XCTAssertFalse(ledger.isDue(provider: ProviderID.claudeCode, coveringFrom: try day(-29)))
        XCTAssertFalse(
            ledger.isDue(provider: ProviderID.claudeCode, coveringFrom: try day(-28)),
            "a day rolling over moves the window's start forward, which is not a new ask")
    }

    func testWideningRetentionOwesAnotherPass() throws {
        let ledger = ArchiveBackfillLedger()
            .recording(provider: ProviderID.claudeCode, coveredFrom: try day(-29))
        XCTAssertTrue(ledger.isDue(provider: ProviderID.claudeCode, coveringFrom: try day(-89)))
    }

    func testOneProvidersPassSaysNothingAboutAnothers() throws {
        let ledger = ArchiveBackfillLedger()
            .recording(provider: ProviderID.claudeCode, coveredFrom: try day(-29))
        XCTAssertTrue(ledger.isDue(provider: ProviderID.codex, coveringFrom: try day(-29)))
    }

    func testTheLedgerRoundTripsThroughDisk() throws {
        let url = ArchiveBackfillLedger.defaultURL(in: stateDir)
        let ledger = ArchiveBackfillLedger()
            .recording(provider: ProviderID.claudeCode, coveredFrom: try day(-29))
        try ArchiveBackfillLedger.save(ledger, to: url)
        XCTAssertEqual(ArchiveBackfillLedger.load(from: url), ledger)
    }

    func testALedgerFileThisBuildCannotReadOwesAPass() throws {
        let url = ArchiveBackfillLedger.defaultURL(in: stateDir)
        try Data("{\"schemaVersion\":99,\"coveredFrom\":{}}".utf8).write(to: url)
        XCTAssertTrue(
            ArchiveBackfillLedger.load(from: url)
                .isDue(provider: ProviderID.claudeCode, coveringFrom: try day(-29)))
    }
}
