import XCTest

@testable import Sissy

/// What Sissy bills for an assistant turn Claude Code wrote more than once.
///
/// The CLI logs the same message several times while the answer streams:
/// `output_tokens` grows with each copy, while the input and cache counts —
/// fixed when the request was made — repeat unchanged. Measured against
/// `ccusage` on a day of real logs, the copy the turn ended on is the turn.
///
/// Driven through a real tree and the real adapter, and read back off the
/// archive rather than off `DayTotals`, because the whole point is which of
/// the four token counts moved.
final class ClaudeStreamedTurnTests: XCTestCase {
    private var logDir: URL!
    private var stateDir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-streamed-\(UUID().uuidString)")
        logDir = base.appendingPathComponent("logs")
        stateDir = base.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: logDir.deletingLastPathComponent())
    }

    private static let model = "claude-opus-5"
    private static let inputTokens = 200
    private static let cacheReadTokens = 30_000
    private static let firstCopyOutput = 3
    private static let finalCopyOutput = 901
    private static let sessionFile = "s.jsonl"

    func testAStreamedTurnBillsTheCountItEndedOn() async throws {
        try append(outputs: [Self.firstCopyOutput, Self.firstCopyOutput, Self.finalCopyOutput])
        try await runTail()

        XCTAssertEqual(
            try billed().outputTokens, Self.finalCopyOutput,
            "the turn was billed at the count its first copy carried")
    }

    func testTheInputAndCacheOfAStreamedTurnAreBilledOnce() async throws {
        try append(outputs: [Self.firstCopyOutput, Self.firstCopyOutput, Self.finalCopyOutput])
        try await runTail()

        let totals = try billed()
        XCTAssertEqual(totals.inputTokens, Self.inputTokens, "input was billed per copy")
        XCTAssertEqual(
            totals.cacheReadTokens, Self.cacheReadTokens, "the cache read was billed per copy")
    }

    func testACopyThatAddsNothingIsNotBilledAgain() async throws {
        try append(outputs: [Self.finalCopyOutput, Self.finalCopyOutput])
        try await runTail()

        XCTAssertEqual(
            try billed().outputTokens, Self.finalCopyOutput,
            "a copy carrying the same count as the one before it was billed twice")
    }

    /// The copies of one turn can land either side of a relaunch, which is the
    /// reason the ledger's billed count is persisted at all: the offsets are
    /// past the copies already read, so what they billed cannot be re-derived.
    func testARelaunchBillsTheRestOfATurnItOnlySawTheStartOf() async throws {
        try append(outputs: [Self.firstCopyOutput])
        try await runTail()
        XCTAssertEqual(
            try billed().outputTokens, Self.firstCopyOutput,
            "the first run billed something other than the copy it saw")

        try append(outputs: [Self.finalCopyOutput])
        try await runTail()

        XCTAssertEqual(
            try billed().outputTokens, Self.finalCopyOutput,
            "the second run billed the remainder wrong")
        XCTAssertEqual(
            try billed().inputTokens, Self.inputTokens,
            "the relaunch billed the turn's input a second time")
    }

    /// A snapshot written before the ledger carried a billed count cannot say
    /// how much of a turn was already paid for. The key still claims the turn:
    /// under-counting one day's in-flight messages once beats billing them
    /// twice, and there is no third answer.
    func testAKeyRestoredWithoutABilledCountIsNotBilledAgain() async throws {
        try append(outputs: [Self.firstCopyOutput])
        try await runTail()
        try stripBilledCountsFromSnapshot()

        try append(outputs: [Self.finalCopyOutput])
        try await runTail()

        XCTAssertEqual(
            try billed().outputTokens, Self.firstCopyOutput,
            "a turn whose billed count was unknown was billed a second time")
    }

    /// A turn streaming across local midnight is a turn whose day stops being
    /// today while copies of it are still arriving, which is the same shape as
    /// a turn on any day that is not today. Its ledger key has to reach the
    /// snapshot or the relaunch bills the whole turn a second time — the
    /// input, the cache read, and the output already paid for.
    func testARelaunchBillsATurnFromADayThatIsNoLongerTodayOnlyOnce() async throws {
        let earlier = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: Date()))
        try append(outputs: [Self.firstCopyOutput], at: earlier)
        try await runTail()

        try append(outputs: [Self.finalCopyOutput], at: earlier)
        try await runTail()

        let totals = try billed(on: earlier)
        XCTAssertEqual(
            totals.inputTokens, Self.inputTokens,
            "the relaunch billed the turn's input a second time")
        XCTAssertEqual(
            totals.cacheReadTokens, Self.cacheReadTokens,
            "the relaunch billed the turn's cache read a second time")
        XCTAssertEqual(
            totals.outputTokens, Self.finalCopyOutput,
            "the relaunch billed the output it had already paid for")
    }

    private func runTail() async throws {
        let provider = LocalUsageProvider.claudeCode(
            claudeDir: logDir,
            retainDays: 2,
            pollInterval: .seconds(60),
            persistenceURL: UsageStatePersistence.defaultURL(in: stateDir),
            historyRoot: stateDir
        )
        await provider.start { _, _ in }
        await provider.stop()
    }

    /// Appends copies of one turn to the session file, in the order the CLI
    /// writes them: same request id, same message id, growing output.
    private func append(outputs: [Int], at when: Date = Date()) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let stamp = iso.string(from: when)
        let body =
            outputs
            .map { output in
                """
                {"type":"assistant","timestamp":"\(stamp)","requestId":"r1",\
                "message":{"id":"m1","model":"\(Self.model)",\
                "usage":{"input_tokens":\(Self.inputTokens),"output_tokens":\(output),\
                "cache_read_input_tokens":\(Self.cacheReadTokens),\
                "cache_creation_input_tokens":0}}}
                """
            }
            .joined(separator: "\n") + "\n"

        let url = logDir.appendingPathComponent(Self.sessionFile)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(body.utf8))
        } else {
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func billed(on when: Date = Date()) throws -> UsageHistoryTotals {
        let day = UsageReaderShared.dayFormatter.string(from: when)
        let record = try XCTUnwrap(
            UsageHistoryStore.load(provider: ProviderID.claudeCode, day: day, in: stateDir),
            "the tail archived nothing for today")
        return try XCTUnwrap(record.totalsByModel[Self.model], "no row for the model under test")
    }

    /// Rewrites the snapshot the way a build that predates the field left it.
    private func stripBilledCountsFromSnapshot() throws {
        let url = UsageStatePersistence.defaultURL(in: stateDir)
        let raw = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        var root = try XCTUnwrap(raw as? [String: Any], "the snapshot is not an object")
        let keys = try XCTUnwrap(
            root["dedupKeysToday"] as? [[String: Any]], "the snapshot carries no dedup keys")
        XCTAssertFalse(keys.isEmpty, "the run under test claimed no dedup key")
        root["dedupKeysToday"] = keys.map { entry in
            entry.filter { $0.key != "outputTokens" }
        }
        try JSONSerialization.data(withJSONObject: root).write(to: url, options: [.atomic])
    }
}
