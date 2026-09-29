import XCTest

@testable import Sissy

/// A day the tail counted before the Mac changed zone keeps the date it was
/// counted under. Its key is a midnight in the old zone, which the formatter,
/// following the new one, would otherwise name as the day before, and the
/// next flush would write it over that day's file.
final class UsageDayKeyZoneChangeTests: XCTestCase {
    private static let rome = TimeZone(identifier: "Europe/Rome")!
    private static let newYork = TimeZone(identifier: "America/New_York")!
    private static let model = "claude-lab-9"
    private static let catalog = PriceCatalog(
        fetchedAt: Date(),
        anthropic: [
            model: ModelPricing(
                inputPerMTok: 3, outputPerMTok: 15, cacheReadPerMTok: 0,
                cacheCreationPerMTok: 0, cacheCreation1hPerMTok: 0)
        ],
        openai: [:])
    private static let halfDay: TimeInterval = 12 * 3600

    private var logDir: URL!
    private var stateDir: URL!
    private var launchZone: TimeZone!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-day-key-zone-\(UUID().uuidString)")
        logDir = base.appendingPathComponent("logs")
        stateDir = base.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        launchZone = NSTimeZone.default
        NSTimeZone.default = Self.rome
    }

    override func tearDownWithError() throws {
        NSTimeZone.default = launchZone
        try? FileManager.default.removeItem(at: logDir.deletingLastPathComponent())
    }

    /// The tail trims its day-keyed state only when the cutoff it trims to
    /// moves. A zone change moves it: from eleven hours behind UTC to fourteen
    /// ahead, the window's first day is more than a day later, so a day
    /// counted at the old window's edge has to go on the next batch rather
    /// than wait for the cutoff to move again at midnight.
    func testTheNextBatchAfterAZoneChangeTrimsToTheNewCutoff() async throws {
        let behind = try XCTUnwrap(TimeZone(identifier: "Pacific/Pago_Pago"))
        let ahead = try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati"))
        NSTimeZone.default = behind
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = behind
        let windowStart = LocalUsageProvider.liveWindowStart(retainDays: 2)
        let edgeDayEnd = try XCTUnwrap(
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: windowStart)))
        guard edgeDayEnd.timeIntervalSince(windowStart) > Self.edgeMargin * 2 else {
            throw XCTSkip("the window starts too close to a midnight for a line to sit on its first day")
        }
        let edge = windowStart.addingTimeInterval(Self.edgeMargin)
        let edgeDay = UsageReaderShared.dayFormatter.string(from: edge)
        try appendTurn(id: "edge", at: edge)
        let (readings, onChange) = TailReadings.stream()
        let tail = LocalUsageProvider.claudeCode(
            claudeDir: logDir,
            retainDays: 2,
            pollInterval: .milliseconds(50),
            persistenceURL: UsageStatePersistence.defaultURL(in: stateDir),
            historyRoot: stateDir,
            profile: ClaudeProfileSource(url: stateDir.appendingPathComponent("claude.json")))
        await tail.start(onChange: onChange)
        XCTAssertTrue(
            try snapshotDays().contains(edgeDay), "the day at the window's edge was never counted")

        NSTimeZone.default = ahead
        try appendTurn(id: "after-1", at: Date())
        try await TailReadings.waitUntil(readings, reach: Self.edgeTurnTokens)
        try appendTurn(id: "after-2", at: Date())
        try await TailReadings.waitUntil(readings, reach: 2 * Self.edgeTurnTokens)
        await tail.stop()

        XCTAssertFalse(
            try snapshotDays().contains(edgeDay),
            "a day before the moved cutoff outlived the batch after the zone change")
    }

    /// How far inside the window the edge line sits, enough for the scan that
    /// reads it to run before the window slides past it.
    private static let edgeMargin: TimeInterval = 60
    /// What one turn `appendTurn` writes counts for. The second wait is for a
    /// reading holding both, which only a poll starting after the one that
    /// read the first can publish, so the first poll's trim has run by then.
    private static let edgeTurnTokens = 11

    private func snapshotDays() throws -> [String] {
        guard
            case .ok(let snapshot) = UsageStatePersistence.load(
                from: UsageStatePersistence.defaultURL(in: stateDir))
        else {
            XCTFail("no snapshot was written")
            return []
        }
        return snapshot.dailyTotals.map(\.day)
    }

    private func appendTurn(id: String, at when: Date) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let line = """
            {"type":"assistant","timestamp":"\(iso.string(from: when))","requestId":"r-\(id)",\
            "message":{"id":"\(id)","model":"\(Self.model)","usage":{"input_tokens":10,"output_tokens":1}}}

            """
        let url = logDir.appendingPathComponent("edge.jsonl")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } else {
            try line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func testADayCountedBeforeAZoneChangeKeepsItsDate() async throws {
        var rome = Calendar(identifier: .gregorian)
        rome.timeZone = Self.rome
        let noonYesterday = rome.startOfDay(for: Date()).addingTimeInterval(
            -Self.halfDay)
        let counted = UsageReaderShared.dayFormatter.string(from: noonYesterday)
        let dayBefore = UsageReaderShared.dayFormatter.string(
            from: noonYesterday.addingTimeInterval(-2 * Self.halfDay))
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let line = """
            {"type":"assistant","timestamp":"\(iso.string(from: noonYesterday))",\
            "requestId":"r1","message":{"id":"m1","model":"\(Self.model)",\
            "usage":{"input_tokens":1000000,"output_tokens":0}}}
            """
        try (line + "\n").write(
            to: logDir.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        let tail = LocalUsageProvider.claudeCode(
            claudeDir: logDir,
            retainDays: 2,
            pollInterval: .seconds(60),
            persistenceURL: UsageStatePersistence.defaultURL(in: stateDir),
            historyRoot: stateDir,
            profile: ClaudeProfileSource(url: stateDir.appendingPathComponent("claude.json")))
        await tail.start { _ in }

        NSTimeZone.default = Self.newYork
        await tail.applyPriceCatalog(Self.catalog)
        await tail.stop()

        let archived = try XCTUnwrap(
            UsageHistoryStore.load(provider: ProviderID.claudeCode, day: counted, in: stateDir))
        XCTAssertEqual(archived.totals(forModel: Self.model).cost, 3)
        XCTAssertNil(
            UsageHistoryStore.load(provider: ProviderID.claudeCode, day: dayBefore, in: stateDir))
    }
}
