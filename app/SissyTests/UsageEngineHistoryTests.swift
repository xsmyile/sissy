import XCTest

@testable import Sissy

/// The wiring between the archive and a frame: which directory the engine
/// hands its tails, what the frame carries back out of it, and what the one
/// button that deletes it leaves behind.
///
/// The store's own rules are covered against files in `UsageHistoryStoreTests`
/// and the tail's in `UsageHistoryTailTests`. What is only reachable here is
/// that the engine points all three at the same place.
final class UsageEngineHistoryTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-engine-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var claudeDir: URL { tempDir.appendingPathComponent("claude") }
    private var codexDir: URL { tempDir.appendingPathComponent("codex") }
    private var configURL: URL { tempDir.appendingPathComponent("server.json") }

    private static let tokensPerTurn = 1_000_000
    private static let archivedTokens = 4_242

    private func makeEngine(retentionDays: Int? = nil) -> UsageEngine {
        var config = ServerConfig.defaults
        config.claudeDataDir = claudeDir.path
        config.codexDataDir = codexDir.path
        config.remotePricing = false
        config.providers = ProviderToggles(claudeCode: true, codex: false)
        config.historyRetentionDays = retentionDays
        return UsageEngine(
            config: config,
            configURL: configURL,
            limitsProbe: ClaudeLimitsProbe { _, _ in .absent }
        )
    }

    private func writeClaudeTurn() throws {
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let line = """
            {"type":"assistant","timestamp":"\(iso.string(from: Date()))",\
            "requestId":"r1","message":{"model":"claude-sonnet-4-6",\
            "usage":{"input_tokens":\(Self.tokensPerTurn),"output_tokens":0,\
            "cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
            """
        try (line + "\n").write(
            to: claudeDir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
    }

    private func yesterday() throws -> Date {
        let cal = Calendar.current
        return try XCTUnwrap(cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date())))
    }

    /// A day from before this run, so the rollup has something no live reading
    /// could have produced.
    private func archiveYesterday() throws {
        let yesterday = try yesterday()
        try UsageHistoryStore.save(
            UsageHistoryDay(
                day: UsageReaderShared.dayFormatter.string(from: yesterday),
                provider: ProviderID.claudeCode,
                updatedAt: Date(),
                totals: [
                    UsageHistoryRow(model: "claude-sonnet-4-6", project: nil):
                        UsageHistoryTotals(
                            inputTokens: Self.archivedTokens,
                            outputTokens: 0,
                            cacheReadTokens: 0,
                            cacheCreationTokens: 0,
                            cost: Decimal(string: "1.25") ?? 0
                        )
                ]
            ),
            in: tempDir
        )
    }

    private func firstFrame(from engine: UsageEngine) async throws -> FrameData {
        let frames = FrameRecorder()
        let landed = frames.expectation(forFrameCount: 1)
        await engine.start { frames.record($0) }
        await fulfillment(of: [landed], timeout: 5)
        return try XCTUnwrap(frames.all.last)
    }

    func testTheFrameCarriesWhatTheArchiveHoldsForTheWeek() async throws {
        try writeClaudeTurn()
        try archiveYesterday()
        let engine = makeEngine()
        addTeardownBlock { await engine.stop() }

        let frame = try await firstFrame(from: engine)

        XCTAssertEqual(frame.history?.tokens, Self.archivedTokens)
        XCTAssertEqual(frame.history?.days, UsageEngine.historyWindowDays)
    }

    /// The engine hands its tails the directory beside the config that named
    /// the trees, which is the rule the snapshots already follow. Nothing else
    /// proves the two agree on where that is.
    func testTheEngineArchivesTheDayItsTailsMetered() async throws {
        try writeClaudeTurn()
        let engine = makeEngine()

        _ = try await firstFrame(from: engine)
        await engine.stop()

        let today = UsageHistoryStore.load(
            provider: ProviderID.claudeCode,
            day: UsageReaderShared.dayFormatter.string(from: Date()),
            in: tempDir
        )
        XCTAssertEqual(today?.models.first?.inputTokens, Self.tokensPerTurn)
    }

    /// Today is not what the button deletes — it is still being counted, and
    /// the tails put it back on their next flush. Every day before it is gone,
    /// on disk and on the frame that follows.
    func testDeletingTheArchiveTakesTheDaysBeforeTodayOffTheNextFrame() async throws {
        try writeClaudeTurn()
        try archiveYesterday()
        let engine = makeEngine()
        addTeardownBlock { await engine.stop() }
        let frames = FrameRecorder()
        let landed = frames.expectation(forFrameCount: 1)
        await engine.start { frames.record($0) }
        await fulfillment(of: [landed], timeout: 5)
        let replayed = frames.expectation(forFrameCount: frames.count + 1)

        await engine.deleteHistory()

        await fulfillment(of: [replayed], timeout: 5)
        XCTAssertNotEqual(frames.all.last?.history?.earliestDay, try yesterday())
        XCTAssertNil(
            UsageHistoryStore.load(
                provider: ProviderID.claudeCode,
                day: UsageReaderShared.dayFormatter.string(from: try yesterday()),
                in: tempDir
            )
        )
    }

    /// Zero days is the off switch, and it has to reach both halves: nothing
    /// written, and nothing read back out of what an earlier run wrote. What
    /// it deliberately does not do is delete — that is the button's job, and
    /// a config edit must not take a user's record with it.
    func testARetentionOfZeroDaysArchivesNothingAndReportsNothing() async throws {
        try writeClaudeTurn()
        try archiveYesterday()
        let engine = makeEngine(retentionDays: 0)
        addTeardownBlock { await engine.stop() }

        let frame = try await firstFrame(from: engine)
        await engine.stop()

        XCTAssertNil(frame.history)
        XCTAssertNil(
            UsageHistoryStore.load(
                provider: ProviderID.claudeCode,
                day: UsageReaderShared.dayFormatter.string(from: Date()),
                in: tempDir
            ),
            "a day was archived with the archive switched off")
        XCTAssertNotNil(
            UsageHistoryStore.load(
                provider: ProviderID.claudeCode,
                day: UsageReaderShared.dayFormatter.string(from: try yesterday()),
                in: tempDir
            ),
            "switching the archive off deleted what an earlier run had recorded")
    }

    /// The dialog behind the button says today keeps counting, and its file
    /// went with the rest of the archive. A day the tail is still holding has
    /// to be back on disk at the next flush.
    func testDeletingTheArchiveLeavesTodayOnDisk() async throws {
        try writeClaudeTurn()
        let engine = makeEngine()
        _ = try await firstFrame(from: engine)

        await engine.deleteHistory()
        await engine.stop()

        XCTAssertEqual(
            UsageHistoryStore.load(
                provider: ProviderID.claudeCode,
                day: UsageReaderShared.dayFormatter.string(from: Date()),
                in: tempDir
            )?.models.first?.inputTokens,
            Self.tokensPerTurn
        )
    }

    /// Retention is the engine's to enforce because a provider switched off is
    /// never built, and the days it recorded are still in the archive. Nothing
    /// but the engine walks a directory whose tail is not running.
    func testRetentionReachesTheDaysOfAProviderThatIsNotRunning() async throws {
        try writeClaudeTurn()
        let staleDay = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: -30, to: Date()))
        try UsageHistoryStore.save(
            UsageHistoryDay(
                day: UsageReaderShared.dayFormatter.string(from: staleDay),
                provider: ProviderID.codex,
                updatedAt: Date(),
                totals: [
                    UsageHistoryRow(model: "gpt-5", project: nil):
                        UsageHistoryTotals(inputTokens: 10, cost: 1)
                ]
            ),
            in: tempDir
        )
        let engine = makeEngine(retentionDays: 7)
        addTeardownBlock { await engine.stop() }

        _ = try await firstFrame(from: engine)

        XCTAssertNil(
            UsageHistoryStore.load(
                provider: ProviderID.codex,
                day: UsageReaderShared.dayFormatter.string(from: staleDay),
                in: tempDir
            ),
            "a day past retention survived because its provider was switched off")
    }
}
