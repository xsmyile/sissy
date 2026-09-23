import XCTest

@testable import Sissy

/// A day the tail archived while no pricing source carried its model, and that
/// has since left the tail's window. The rows keep every token count, so the
/// catalog that first prices the model prices the day too, through the same
/// arithmetic an event is priced with.
final class UsageArchiveRepriceTests: XCTestCase {
    private var logDir: URL!
    private var stateDir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-archive-reprice-\(UUID().uuidString)")
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
    private static let tokensPerRow = 1_000_000
    private static let daysAgo = 5
    private static let rates = ModelPricing(
        inputPerMTok: 3, outputPerMTok: 15, cacheReadPerMTok: Decimal(string: "0.3")!,
        cacheCreationPerMTok: Decimal(string: "3.75")!, cacheCreation1hPerMTok: 6)
    private static let catalog = PriceCatalog(
        fetchedAt: Date(), anthropic: [newModel: rates], openai: [:])

    private static let newCodexModel = "gpt-lab-9"
    private static let codexCatalog = PriceCatalog(
        fetchedAt: Date(), anthropic: [:], openai: [newCodexModel: rates])
    /// A Codex turn as the adapter archives it: `input_tokens` net of the
    /// cached part, which is billed on its own channel, and no cache writes.
    private static let codexTurn = UsageHistoryTotals(
        inputTokens: 9000, outputTokens: 2000, cacheReadTokens: 1000)
    /// That turn at `rates`: 9000 × 3 + 2000 × 15 + 1000 × 0.3, per million.
    private static let codexTurnCost = Decimal(string: "0.0573")!

    /// The pricing-oracle fixture's first turn, the one that carries every
    /// counter a cost is made of: fresh input, output, cache reads, and cache
    /// writes split between the 5-minute and the 1-hour tier.
    private static let oracleTurn = UsageHistoryTotals(
        inputTokens: 1000, outputTokens: 2000, cacheReadTokens: 50000,
        cacheCreationTokens: 9000, cacheCreation1hTokens: 5000)
    /// That turn at `rates`: 1000 × 3 + 2000 × 15 + 50000 × 0.3 + 4000 × 3.75
    /// + 5000 × 6, per million.
    private static let oracleTurnCost = Decimal(string: "0.093")!

    private var pastDay: String {
        get throws {
            let date = try XCTUnwrap(
                Calendar.current.date(byAdding: .day, value: -Self.daysAgo, to: Date()))
            return UsageReaderShared.dayFormatter.string(from: date)
        }
    }

    private func archive(
        _ totals: UsageHistoryTotals, model: String = UsageArchiveRepriceTests.newModel,
        provider: String = ProviderID.claudeCode, effort: Bool = false
    ) throws {
        let day = UsageHistoryDay(
            day: try pastDay, provider: provider, updatedAt: Date(),
            totals: [UsageHistoryRow(model: model, project: nil): totals],
            effort: effort
                ? [EffortKey(model: model, effort: "high"): EffortTotals(turns: 1, totals: totals)]
                : [:])
        try UsageHistoryStore.save(day, in: stateDir)
    }

    private func archived(provider: String = ProviderID.claudeCode) throws -> UsageHistoryDay {
        try XCTUnwrap(UsageHistoryStore.load(provider: provider, day: try pastDay, in: stateDir))
    }

    /// A profile file of the test's own, so nothing reads the real
    /// `~/.claude.json`.
    private var profile: ClaudeProfileSource {
        ClaudeProfileSource(url: stateDir.appendingPathComponent("claude.json"))
    }

    private func tail() -> LocalUsageProvider {
        LocalUsageProvider.claudeCode(
            claudeDir: logDir,
            retainDays: 2,
            pollInterval: .seconds(60),
            persistenceURL: UsageStatePersistence.defaultURL(in: stateDir),
            historyRoot: stateDir,
            profile: profile
        )
    }

    private func codexTail() -> LocalUsageProvider {
        LocalUsageProvider.codex(
            codexDir: logDir,
            retainDays: 2,
            pollInterval: .seconds(60),
            persistenceURL: UsageStatePersistence.forProvider(ProviderID.codex, in: stateDir),
            historyRoot: stateDir
        )
    }

    private func freeRow(_ tokens: Int = UsageArchiveRepriceTests.tokensPerRow) -> UsageHistoryTotals {
        UsageHistoryTotals(inputTokens: tokens)
    }

    func testAnArchivedFreeDayIsPricedWhenTheCatalogCarriesItsModel() async throws {
        try archive(freeRow())

        await tail().applyPriceCatalog(Self.catalog)

        XCTAssertEqual(try archived().totals(forModel: Self.newModel).cost, 3)
    }

    func testTheArchivedEffortSplitIsPricedWithTheRows() async throws {
        try archive(freeRow(), effort: true)

        await tail().applyPriceCatalog(Self.catalog)

        let split = try XCTUnwrap(try archived().effort?.first)
        XCTAssertEqual(split.split.totals.cost, 3)
    }

    func testAnArchivedModelNoSourcePricesKeepsItsZero() async throws {
        try archive(freeRow(), model: Self.localModel)

        await tail().applyPriceCatalog(Self.catalog)

        XCTAssertEqual(try archived().totals(forModel: Self.localModel).cost, 0)
    }

    /// What was priced keeps its rate, as a `pricingOverride` edit does: only
    /// a row counted with no rate at all is priced again.
    func testAnArchivedRowThatHasACostKeepsIt() async throws {
        var priced = freeRow()
        priced.cost = 1
        try archive(priced)

        await tail().applyPriceCatalog(Self.catalog)

        XCTAssertEqual(try archived().totals(forModel: Self.newModel).cost, 1)
    }

    func testABackfillPassLeavesTheArchiveToTheTail() async throws {
        try archive(freeRow())
        let now = Date()
        let backfill = LocalUsageProvider.claudeCode(
            claudeDir: logDir, historyRoot: stateDir, profile: profile,
            backfill: now.addingTimeInterval(-Double(Self.daysAgo + 1) * 86_400)..<now)

        await backfill.applyPriceCatalog(Self.catalog)

        XCTAssertEqual(try archived().totals(forModel: Self.newModel).cost, 0)
    }

    /// The pricing-oracle fixture asserts that a turn ingested off a log line
    /// costs what `ccusage` says it costs. An archived day repriced from its
    /// counters has to land on the same figure, to the digit.
    func testARepricedDayCostsWhatTheOracleFixturesTurnCosts() async throws {
        try archive(Self.oracleTurn)

        await tail().applyPriceCatalog(Self.catalog)

        XCTAssertEqual(try archived().totals(forModel: Self.newModel).cost, Self.oracleTurnCost)
    }

    /// The same turn, written as a log line and priced at ingest by the tail,
    /// which is the path the oracle drives. Pins that the fixture figure above
    /// is the live path's figure and not an independent reading of the rates.
    func testTheOracleFixturesTurnCostsTheSameWhenIngestedLive() async throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let line = """
            {"type":"assistant","timestamp":"\(iso.string(from: Date()))","requestId":"r1",\
            "message":{"id":"m1","model":"\(Self.newModel)","usage":{"input_tokens":1000,\
            "output_tokens":2000,"cache_read_input_tokens":50000,"cache_creation_input_tokens":9000,\
            "cache_creation":{"ephemeral_5m_input_tokens":4000,"ephemeral_1h_input_tokens":5000}}}}
            """
        try (line + "\n").write(
            to: logDir.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        let live = tail()
        await live.applyPriceCatalog(Self.catalog)
        await live.start { _ in }
        await live.stop()

        let today = try XCTUnwrap(
            UsageHistoryStore.load(
                provider: ProviderID.claudeCode,
                day: UsageReaderShared.dayFormatter.string(from: Date()), in: stateDir))
        XCTAssertEqual(today.totals(forModel: Self.newModel).cost, Self.oracleTurnCost)
    }

    /// Codex prices through its own table, with no cache-write tiers, so its
    /// archived days are repriced by that arithmetic and not by Claude's.
    func testAnArchivedCodexDayIsPricedByTheCodexArithmetic() async throws {
        try archive(Self.codexTurn, model: Self.newCodexModel, provider: ProviderID.codex)

        await codexTail().applyPriceCatalog(Self.codexCatalog)

        XCTAssertEqual(
            try archived(provider: ProviderID.codex).totals(forModel: Self.newCodexModel).cost,
            Self.codexTurnCost)
    }

    /// The same Codex turn written as a rollout's `token_count` and priced at
    /// ingest, which pins the figure above to the live path's.
    func testTheCodexTurnCostsTheSameWhenIngestedLive() async throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let now = iso.string(from: Date())
        let lines = [
            #"{"type":"session_meta","timestamp":"\#(now)","payload":{"id":"s1"}}"#,
            #"{"type":"turn_context","timestamp":"\#(now)","payload":{"model":"\#(Self.newCodexModel)"}}"#,
            #"{"type":"event_msg","timestamp":"\#(now)","payload":{"type":"token_count","info":{"#
                + #""last_token_usage":{"input_tokens":10000,"cached_input_tokens":1000,"#
                + #""output_tokens":2000,"total_tokens":12000},"#
                + #""total_token_usage":{"input_tokens":10000,"cached_input_tokens":1000,"#
                + #""output_tokens":2000,"total_tokens":12000}}}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(
            to: logDir.appendingPathComponent("rollout.jsonl"), atomically: true, encoding: .utf8)
        let live = codexTail()
        await live.applyPriceCatalog(Self.codexCatalog)
        await live.start { _ in }
        await live.stop()

        let today = try XCTUnwrap(
            UsageHistoryStore.load(
                provider: ProviderID.codex,
                day: UsageReaderShared.dayFormatter.string(from: Date()), in: stateDir))
        XCTAssertEqual(today.totals(forModel: Self.newCodexModel).cost, Self.codexTurnCost)
    }
}
