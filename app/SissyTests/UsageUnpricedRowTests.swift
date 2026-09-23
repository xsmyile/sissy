import XCTest

@testable import Sissy

/// A model a vendor ships before the rate catalog carries it is metered at $0
/// until the catalog catches up. These pin what happens to those free rows
/// once it does, through a real tree and the real Claude Code adapter.
final class UsageUnpricedRowTests: XCTestCase {
    private var logDir: URL!
    private var stateDir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-unpriced-\(UUID().uuidString)")
        logDir = base.appendingPathComponent("logs")
        stateDir = base.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: logDir.deletingLastPathComponent())
    }

    private static let newModel = "claude-lab-9"
    private static let localModel = "qwen3-coder"
    private static let tokensPerTurn = 1_000_000
    private static let rates = ModelPricing(
        inputPerMTok: 3, outputPerMTok: 15, cacheReadPerMTok: Decimal(string: "0.3")!,
        cacheCreationPerMTok: Decimal(string: "3.75")!, cacheCreation1hPerMTok: 6)
    private static let catalog = PriceCatalog(
        fetchedAt: Date(), anthropic: [newModel: rates], openai: [:])

    private var today: String {
        UsageReaderShared.dayFormatter.string(from: Date())
    }

    private func writeTurn(
        _ name: String, requestId: String, model: String = UsageUnpricedRowTests.newModel,
        input: Int = UsageUnpricedRowTests.tokensPerTurn, oneHourWrites: Int = 0
    ) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let line = """
            {"type":"assistant","timestamp":"\(iso.string(from: Date()))",\
            "requestId":"\(requestId)","message":{"model":"\(model)",\
            "usage":{"input_tokens":\(input),"output_tokens":0,\
            "cache_read_input_tokens":0,"cache_creation_input_tokens":\(oneHourWrites),\
            "cache_creation":{"ephemeral_5m_input_tokens":0,\
            "ephemeral_1h_input_tokens":\(oneHourWrites)}}}}
            """
        try (line + "\n").write(
            to: logDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func provider() -> LocalUsageProvider {
        LocalUsageProvider.claudeCode(
            claudeDir: logDir,
            retainDays: 2,
            pollInterval: .seconds(60),
            persistenceURL: UsageStatePersistence.defaultURL(in: stateDir),
            historyRoot: stateDir
        )
    }

    private func archivedCost(of model: String) throws -> Decimal {
        let day = try XCTUnwrap(
            UsageHistoryStore.load(provider: ProviderID.claudeCode, day: today, in: stateDir))
        return day.totals(forModel: model).cost
    }

    func testAFreeRowIsPricedWhenTheCatalogFirstCarriesItsModel() async throws {
        try writeTurn("a.jsonl", requestId: "r1")
        let tail = provider()
        let readings = ReadingLog()
        await tail.start { await readings.record($0) }

        await tail.applyPriceCatalog(Self.catalog)
        await tail.stop()

        XCTAssertEqual(try archivedCost(of: Self.newModel), 3)
        let last = await readings.last
        XCTAssertEqual(last?.totalCost, 3, "the panel kept the free reading until the next turn")
    }

    /// The case pricing on read cannot see: a turn priced on top of the free
    /// row gives it a cost, and the tokens counted before the rate would then
    /// stay free with nothing left to tell them apart.
    func testATurnPricedAfterARelaunchDoesNotHideTheTokensCountedFree() async throws {
        try writeTurn("a.jsonl", requestId: "r1")
        let first = provider()
        await first.start { _ in }
        await first.stop()
        XCTAssertEqual(try archivedCost(of: Self.newModel), 0)

        try writeTurn("b.jsonl", requestId: "r2")
        let second = provider()
        await second.applyPriceCatalog(Self.catalog)
        await second.start { _ in }
        await second.stop()

        XCTAssertEqual(try archivedCost(of: Self.newModel), 6)
    }

    /// A model behind the CLI that no source will ever price, such as a local
    /// one, keeps the zero ingest gave it.
    func testAModelNoSourcePricesKeepsItsZero() async throws {
        try writeTurn("a.jsonl", requestId: "r1", model: Self.localModel)
        let tail = provider()
        await tail.start { _ in }

        await tail.applyPriceCatalog(Self.catalog)
        await tail.stop()

        XCTAssertEqual(try archivedCost(of: Self.localModel), 0)
    }

    /// The 1-hour cache writes bill at their own rate, which is why the row
    /// keeps them apart: priced at the 5-minute rate this would read $3.75.
    func testOneHourCacheWritesArePricedAtTheOneHourRate() async throws {
        try writeTurn("a.jsonl", requestId: "r1", input: 0, oneHourWrites: Self.tokensPerTurn)
        let tail = provider()
        await tail.start { _ in }

        await tail.applyPriceCatalog(Self.catalog)
        await tail.stop()

        XCTAssertEqual(try archivedCost(of: Self.newModel), 6)
    }
}

private actor ReadingLog {
    private(set) var last: DayTotals?

    func record(_ reading: DayTotals) { last = reading }
}
