import XCTest

@testable import Sissy

/// Which model a day's spend went to, driven through real trees and the real
/// adapters. The unit under test is the whole path from a `model` on a log
/// line to the split the frame carries, because that is the claim the panel
/// makes: these rows are the figure above them, taken apart.
final class UsageModelSplitTests: XCTestCase {
    private var base: URL!
    private var logDir: URL!
    private var stateDir: URL!
    private var repos: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-models-split-\(UUID().uuidString)")
        logDir = base.appendingPathComponent("logs")
        stateDir = base.appendingPathComponent("state")
        repos = base.appendingPathComponent("repos")
        for dir in [logDir, stateDir, repos] {
            try FileManager.default.createDirectory(at: dir!, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private static let opus = "claude-opus-5"
    private static let sonnet = "claude-sonnet-5"
    private static let synthetic = "<synthetic>"
    private static let tokensPerTurn = 1_000

    func testTwoModelsAreTwoRowsThatAddUpToTheDay() async throws {
        let repo = try makeRepository("legion")
        try writeTurn("a.jsonl", requestId: "r1", model: Self.opus, cwd: repo.path)
        try writeTurn("b.jsonl", requestId: "r2", model: Self.sonnet, cwd: repo.path)

        let (split, today) = try await runClaudeTail()

        XCTAssertEqual(Set(split.map(\.model)), [Self.opus, Self.sonnet])
        XCTAssertEqual(
            split.reduce(0) { $0 + $1.tokens }, today.totalTokens,
            "the rows do not add up to the day they are the split of")
        XCTAssertEqual(
            split.reduce(Decimal(0)) { $0 + $1.cost }, today.totalCost,
            "the rows do not add up to the day's cost")
    }

    /// The archive keeps a row per model *per project*; the split the panel
    /// reads is per model alone, so one model working in two repositories is
    /// one row rather than two with the same name.
    func testOneModelAcrossTwoProjectsIsOneRow() async throws {
        let legion = try makeRepository("legion")
        let vedite = try makeRepository("vedite")
        try writeTurn("a.jsonl", requestId: "r1", model: Self.opus, cwd: legion.path)
        try writeTurn("b.jsonl", requestId: "r2", model: Self.opus, cwd: vedite.path)

        let (split, _) = try await runClaudeTail()

        XCTAssertEqual(split.map(\.model), [Self.opus], "one model came back as two rows")
        XCTAssertEqual(split.first?.totals.inputTokens, Self.tokensPerTurn * 2)
    }

    /// Claude Code writes a `<synthetic>` assistant turn for its own local
    /// notices, with every counter at zero. The archive drops such a row on
    /// the way to disk; the live split has to drop it too, or the panel names
    /// a model that never ran.
    func testAModelThatSpentNothingGetsNoRow() async throws {
        let repo = try makeRepository("legion")
        try writeTurn("a.jsonl", requestId: "r1", model: Self.opus, cwd: repo.path)
        try writeTurn(
            "b.jsonl", requestId: "r2", model: Self.synthetic, cwd: repo.path, tokens: 0)

        let (split, _) = try await runClaudeTail()

        XCTAssertEqual(
            split.map(\.model), [Self.opus],
            "a turn with every counter at zero took a row of its own")
    }

    /// A model no pricing source knows costs nothing and still spent tokens.
    /// Dropping it would lose real usage; pricing it would invent a rate.
    func testAnUnpricedModelKeepsItsTokensAtZeroCost() async throws {
        let repo = try makeRepository("legion")
        try writeTurn("a.jsonl", requestId: "r1", model: "claude-not-a-model", cwd: repo.path)

        let (split, _) = try await runClaudeTail()

        XCTAssertEqual(split.map(\.model), ["claude-not-a-model"])
        XCTAssertEqual(split.first?.tokens, Self.tokensPerTurn)
        XCTAssertEqual(split.first?.cost, 0)
    }

    /// The offsets are at EOF after a restart, so nothing re-reads the lines
    /// that named the model. The split comes back off `historyResume` with the
    /// day totals it belongs to.
    func testTheSplitSurvivesARelaunchInTheMiddleOfADay() async throws {
        let repo = try makeRepository("legion")
        try writeTurn("a.jsonl", requestId: "r1", model: Self.opus, cwd: repo.path)
        _ = try await runClaudeTail()

        try writeTurn("b.jsonl", requestId: "r2", model: Self.sonnet, cwd: repo.path)
        let (split, today) = try await runClaudeTail()

        XCTAssertEqual(Set(split.map(\.model)), [Self.opus, Self.sonnet])
        XCTAssertEqual(
            split.reduce(0) { $0 + $1.tokens }, today.totalTokens,
            "the relaunched split lost the day it is meant to add up to")
    }

    /// `historyRetentionDays: 0` switches the archive off, which is a promise
    /// about what reaches disk. The split is read live and must survive it,
    /// exactly as the project split does.
    func testTheSplitIsStillReadableWithTheArchiveSwitchedOff() async throws {
        let repo = try makeRepository("legion")
        try writeTurn("a.jsonl", requestId: "r1", model: Self.opus, cwd: repo.path)
        try writeTurn("b.jsonl", requestId: "r2", model: Self.sonnet, cwd: repo.path)

        let (split, _) = try await runClaudeTail(archiving: false)

        XCTAssertEqual(
            Set(split.map(\.model)), [Self.opus, Self.sonnet],
            "switching the archive off blanked the live split too")
    }

    func testTheOrderIsCostThenTokensThenName() {
        let cheapButBusy = ModelTotals(
            model: "b-model", totals: UsageHistoryTotals(inputTokens: 900, cost: 1))
        let dear = ModelTotals(
            model: "c-model", totals: UsageHistoryTotals(inputTokens: 10, cost: 5))
        let free = ModelTotals(
            model: "a-model", totals: UsageHistoryTotals(inputTokens: 100, cost: 0))

        XCTAssertEqual(
            FrameBuilder.orderedModels([free, cheapButBusy, dear]).map(\.model),
            ["c-model", "b-model", "a-model"])
    }

    /// The case cost alone cannot order: nothing in the day has a rate, so
    /// every row reads $0.00 and the tokens are the only figure that ranks
    /// them.
    func testADayWithNoPricedModelStillLeadsWithItsLargest() {
        let small = ModelTotals(
            model: "a-model", totals: UsageHistoryTotals(inputTokens: 10, cost: 0))
        let large = ModelTotals(
            model: "z-model", totals: UsageHistoryTotals(inputTokens: 900, cost: 0))

        XCTAssertEqual(
            FrameBuilder.orderedModels([small, large]).map(\.model), ["z-model", "a-model"])
    }

    private func runClaudeTail(archiving: Bool = true) async throws
        -> ([ModelTotals], DayTotals)
    {
        let provider = LocalUsageProvider.claudeCode(
            claudeDir: logDir,
            retainDays: 2,
            pollInterval: .seconds(60),
            persistenceURL: UsageStatePersistence.defaultURL(in: stateDir),
            historyRoot: archiving ? stateDir : nil,
            ledger: ProjectLedger(url: ProjectLedger.defaultURL(in: stateDir))
        )
        await provider.start { _ in }
        let today = await provider.current()
        let split = provider.currentModels()
        await provider.stop()
        return (split, today)
    }

    private func writeTurn(
        _ name: String, requestId: String, model: String, cwd: String,
        tokens: Int? = nil
    ) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let line = """
            {"type":"assistant","timestamp":"\(iso.string(from: Date()))",\
            "cwd":"\(cwd)","requestId":"\(requestId)",\
            "message":{"id":"m-\(requestId)","model":"\(model)",\
            "usage":{"input_tokens":\(tokens ?? Self.tokensPerTurn),"output_tokens":0,\
            "cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
            """
        try (line + "\n").write(
            to: logDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func makeRepository(_ name: String) throws -> URL {
        let repo = repos.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        return repo.standardizedFileURL
    }
}
