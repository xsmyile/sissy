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
