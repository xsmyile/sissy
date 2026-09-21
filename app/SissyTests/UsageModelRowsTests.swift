import XCTest

@testable import Sissy

/// What the provider page says about which models a day's money went to:
/// which rows exist, what they are called, what their bands are a share of,
/// and that the four token counters stay reachable without a pointer.
final class UsageModelRowsTests: XCTestCase {
    func testTwoModelsAreTwoRowsDearestFirst() {
        let rows = models(
            frame(
                models: [
                    model("claude-sonnet-5", 300, "19.39"),
                    model("claude-opus-5", 3_900, "396.88"),
                ]))

        XCTAssertEqual(rows.map(\.name), ["claude-opus-5", "claude-sonnet-5"])
        XCTAssertEqual(rows.map(\.cost), ["$396.88", "$19.39"])
    }

    /// One model's split is the row above it at 100%, so it is not drawn. The
    /// same rule the page's unattributed line follows: say it only where there
    /// is more than one answer.
    func testOneModelDrawsNoRows() {
        let rows = models(frame(models: [model("claude-opus-5", 3_900, "396.88")]))

        XCTAssertTrue(rows.isEmpty, "a single model repeated the figure above it")
    }

    func testAProviderThatHasReadNothingDrawsNoRows() {
        XCTAssertTrue(models(frame(models: [])).isEmpty)
    }

    /// The rows sit under the day's own figure, so their bands have to be
    /// shares of it rather than of each other.
    func testTheSharesAreSharesOfTheProvidersDay() {
        let rows = models(
            frame(
                models: [
                    model("claude-opus-5", 750, "7.50"),
                    model("claude-sonnet-5", 250, "2.50"),
                ]))

        XCTAssertEqual(rows.map { Int(($0.share * 100).rounded()) }, [75, 25])
    }

    /// A day no pricing source has a rate for costs zero across the board.
    /// Sharing that would draw every band empty on a day that measured
    /// millions of tokens, so the tokens are what the bands are of.
    func testADayWithNoCostSharesOnTokensInstead() {
        let rows = models(
            frame(
                models: [
                    model("mystery-9", 900, "0"),
                    model("mystery-1", 100, "0"),
                ]))

        XCTAssertEqual(rows.map(\.name), ["mystery-9", "mystery-1"])
        XCTAssertEqual(rows.map { Int(($0.share * 100).rounded()) }, [90, 10])
    }

    /// The date a vendor puts on an id says nothing to a reader, and taking it
    /// off is a rule about the shape rather than a table of names — so the raw
    /// id has to stay somewhere, and that is the detail line.
    func testADatedIdIsTrimmedOnTheRowAndKeptInTheDetail() {
        let rows = models(
            frame(
                models: [
                    model("claude-haiku-4-5-20251001", 900, "9.00"),
                    model("claude-opus-5", 100, "1.00"),
                ]))

        XCTAssertEqual(rows.first?.name, "claude-haiku-4-5")
        XCTAssertEqual(rows.first?.id, "claude-haiku-4-5-20251001")
        XCTAssertTrue(
            rows.first?.detail.hasPrefix("claude-haiku-4-5-20251001") == true,
            "the raw id was nowhere on the row")
    }

    func testAnIdThatMerelyEndsInNumbersKeepsThemAll() {
        XCTAssertEqual(UsageFormat.modelName("gpt-5.6-sol"), "gpt-5.6-sol")
        XCTAssertEqual(UsageFormat.modelName("claude-opus-5"), "claude-opus-5")
        XCTAssertEqual(UsageFormat.modelName("o3-2025"), "o3-2025")
        XCTAssertEqual(UsageFormat.modelName("20251001"), "20251001")
    }

    /// ccusage's own breakdown prints the four counters apart, and a total
    /// cannot be taken back apart. They do not fit the row, so they are on the
    /// hover — and on the accessibility label with it, because anything only a
    /// pointer reaches does not exist for VoiceOver.
    func testTheDetailCarriesTheFourCountersApart() {
        let rows = models(
            frame(
                models: [
                    ModelTotals(
                        model: "claude-opus-5",
                        totals: UsageHistoryTotals(
                            inputTokens: 1_000, outputTokens: 2_000,
                            cacheReadTokens: 3_000, cacheCreationTokens: 4_000,
                            cost: 9)),
                    model("claude-sonnet-5", 100, "1.00"),
                ]))

        XCTAssertEqual(
            rows.first?.detail,
            "claude-opus-5 · in 1.0K · out 2.0K · cache read 3.0K · cache write 4.0K")
    }

    private func models(_ frame: FrameData) -> [UsagePanelSnapshot.ModelRow] {
        UsagePanelSnapshot.make(frame: frame).providers.first?.models ?? []
    }

    private func model(_ id: String, _ tokens: Int, _ cost: String) -> ModelTotals {
        ModelTotals(
            model: id,
            totals: UsageHistoryTotals(
                inputTokens: tokens, cost: Decimal(string: cost)!))
    }

    /// The provider spends exactly what its models add up to, which is what
    /// the fold guarantees: a line naming no model is not counted at all, so
    /// there is no remainder a test could grow by accident.
    private func frame(models: [ModelTotals]) -> FrameData {
        let tokens = models.reduce(0) { $0 + $1.tokens }
        let cost = models.reduce(Decimal(0)) { $0 + $1.cost }
        return FrameData(
            tokens: tokens,
            cost: cost,
            burn: 1500,
            providers: [
                ProviderSlice(
                    id: ProviderID.claudeCode, tokens: tokens, cost: cost, models: models)
            ],
            keepAwake: .off
        )
    }
}
