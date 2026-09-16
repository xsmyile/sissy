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

    private func span(_ from: Int, _ through: Int) throws -> Range<Date> {
        try day(from)..<(try day(through))
    }

    func testAnEmptyRecordLeavesTheWholeWindowUncovered() throws {
        let window = try span(-89, -1)
        XCTAssertEqual(
            ArchiveBackfill.uncovered(window, coverage: nil, meteredThrough: nil), window)
    }

    func testAWindowAlreadyCoveredIsNotPassedOverAgain() throws {
        let window = try span(-89, -1)
        let ledger = ArchiveBackfillLedger()
            .recording(provider: ProviderID.claudeCode, covered: window)
        XCTAssertNil(
            ArchiveBackfill.uncovered(
                window, coverage: ledger.coverage[ProviderID.claudeCode],
                meteredThrough: try day(0)))
    }

    /// The correction this rule exists for. A Mac shut for a fortnight comes
    /// back with days the tail's 48 h cannot reach; asking only "has a pass
    /// run" answered no and left them unarchived for good.
    func testAMacThatWasOffLeavesThoseDaysUncovered() throws {
        let ledger = ArchiveBackfillLedger()
            .recording(provider: ProviderID.claudeCode, covered: try span(-103, -15))
        let uncovered = try XCTUnwrap(
            ArchiveBackfill.uncovered(
                try span(-89, -1),
                coverage: ledger.coverage[ProviderID.claudeCode],
                meteredThrough: try day(-14)))
        XCTAssertEqual(uncovered.lowerBound, try day(-14))
        XCTAssertEqual(uncovered.upperBound, try day(-1))
    }

    /// The tail archives every day it runs across, so a relaunch owes nothing
    /// and must not re-read the tree to prove it.
    func testAPlainRelaunchOwesNothing() throws {
        let ledger = ArchiveBackfillLedger()
            .recording(provider: ProviderID.claudeCode, covered: try span(-89, -2))
        XCTAssertNil(
            ArchiveBackfill.uncovered(
                try span(-88, -1),
                coverage: ledger.coverage[ProviderID.claudeCode],
                meteredThrough: try day(-1)))
    }

    func testWideningRetentionAsksForTheWholeWindowAgain() throws {
        let ledger = ArchiveBackfillLedger()
            .recording(provider: ProviderID.claudeCode, covered: try span(-29, -1))
        let window = try span(-89, -1)
        XCTAssertEqual(
            ArchiveBackfill.uncovered(
                window, coverage: ledger.coverage[ProviderID.claudeCode],
                meteredThrough: try day(0)),
            window)
    }

    func testOneProvidersPassSaysNothingAboutAnothers() throws {
        let window = try span(-89, -1)
        let ledger = ArchiveBackfillLedger()
            .recording(provider: ProviderID.claudeCode, covered: window)
        XCTAssertEqual(
            ArchiveBackfill.uncovered(
                window, coverage: ledger.coverage[ProviderID.codex], meteredThrough: try day(0)),
            window)
    }

    /// A top-up pass covers days, not months. Replacing the record with its
    /// span would throw away the history the first pass indexed.
    func testATopUpPassExtendsTheRecordRatherThanReplacingIt() throws {
        let ledger = ArchiveBackfillLedger()
            .recording(provider: ProviderID.claudeCode, covered: try span(-89, -15))
            .recording(provider: ProviderID.claudeCode, covered: try span(-14, -1))
        let coverage = try XCTUnwrap(ledger.coverage[ProviderID.claudeCode])
        XCTAssertEqual(coverage.fromDay, try day(-89))
        XCTAssertEqual(coverage.throughDay, try day(-1))
    }

    /// The tail's window is rolling seconds and the backfill's is calendar
    /// days; derived apart they disagree about which day they meet in across a
    /// daylight-saving boundary, and a day then belongs to both or to neither.
    func testTheWindowEndsOnTheTailsOwnBoundaryAcrossADaylightShift() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Rome"))
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        let now = try XCTUnwrap(formatter.date(from: "2026-10-26T00:30:00+01:00"))
        let window = try XCTUnwrap(
            ArchiveBackfill.window(
                retentionDays: Self.retentionDays, liveRetainDays: 2, now: now,
                calendar: calendar))
        let tailCuts = calendar.startOfDay(
            for: LocalUsageProvider.liveWindowStart(retainDays: 2, now: now))
        XCTAssertEqual(
            window.upperBound, calendar.date(byAdding: .day, value: 1, to: tailCuts),
            "the newest day a pass writes is the one the tail suppresses, whatever the clock did")
    }

    func testTheLedgerRoundTripsThroughDisk() throws {
        let url = ArchiveBackfillLedger.defaultURL(in: stateDir)
        let ledger = ArchiveBackfillLedger()
            .recording(provider: ProviderID.claudeCode, covered: try span(-89, -1))
        try ArchiveBackfillLedger.save(ledger, to: url)
        XCTAssertEqual(ArchiveBackfillLedger.load(from: url), ledger)
    }

    func testALedgerFileThisBuildCannotReadOwesAPass() throws {
        let url = ArchiveBackfillLedger.defaultURL(in: stateDir)
        try Data("{\"schemaVersion\":99,\"coverage\":{}}".utf8).write(to: url)
        XCTAssertNil(ArchiveBackfillLedger.load(from: url).coverage[ProviderID.claudeCode])
    }
}
