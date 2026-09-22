import XCTest

@testable import Sissy

/// What the provider page says about which models a day's money went to:
/// which pills exist, what they are called, what their percentage is a share
/// of, and that the four token counters stay reachable without a pointer.
final class UsageModelRowsTests: XCTestCase {
    func testTwoModelsAreTwoPillsDearestFirst() {
        let rows = models(
            frame(
                models: [
                    model("claude-sonnet-5", 300, "19.39"),
                    model("claude-opus-5", 3_900, "396.88"),
                ]))

        XCTAssertEqual(rows.map(\.name), ["opus-5", "sonnet-5"])
        XCTAssertEqual(rows.map(\.reading), ["95% · $396.88", "5% · $19.39"])
    }

    /// A day spent entirely on one model is the day the block is most needed:
    /// nothing else on the page says which model it was. Only the percentage
    /// is redundant at 100%, and the pill is not there for the percentage.
    func testOneModelIsOnePillNamingIt() {
        let rows = models(frame(models: [model("claude-opus-5", 3_900, "396.88")]))

        XCTAssertEqual(rows.map(\.name), ["opus-5"])
        XCTAssertEqual(rows.map(\.reading), ["100% · $396.88"])
    }

    func testAProviderThatHasReadNothingDrawsNoPills() {
        XCTAssertTrue(models(frame(models: [])).isEmpty)
    }

    /// The pills are the split of the provider's whole day, so the
    /// percentages have to be shares of it rather than of each other.
    func testThePercentagesAreSharesOfTheProvidersDay() {
        let rows = models(
            frame(
                models: [
                    model("claude-opus-5", 750, "7.50"),
                    model("claude-sonnet-5", 250, "2.50"),
                ]))

        XCTAssertEqual(rows.map(\.reading), ["75% · $7.50", "25% · $2.50"])
    }

    /// A day no pricing source has a rate for costs zero across the board.
    /// Sharing that would draw every band empty on a day that measured
    /// millions of tokens, so the tokens are what the bands are of.
    func testADayWithNoCostTakesItsPercentagesFromTokens() {
        let rows = models(
            frame(
                models: [
                    model("mystery-9", 900, "0"),
                    model("mystery-1", 100, "0"),
                ]))

        XCTAssertEqual(rows.map(\.name), ["mystery-9", "mystery-1"])
        XCTAssertEqual(rows.map(\.reading), ["90% · $0.00", "10% · $0.00"])
    }

    /// The date a vendor puts on an id says nothing to a reader, and taking it
    /// off is a rule about the shape rather than a table of names — so the raw
    /// id has to stay somewhere, and that is the detail line.
    func testADatedIdIsTrimmedOnThePillAndKeptInTheDetail() {
        let rows = models(
            frame(
                models: [
                    model("claude-haiku-4-5-20251001", 900, "9.00"),
                    model("claude-opus-5", 100, "1.00"),
                ]))

        XCTAssertEqual(rows.first?.name, "haiku-4-5")
        XCTAssertEqual(rows.first?.id, "claude-haiku-4-5-20251001")
        XCTAssertTrue(
            rows.first?.detail.hasPrefix("claude-haiku-4-5-20251001") == true,
            "the raw id was nowhere on the pill")
    }

    func testAnIdThatMerelyEndsInNumbersKeepsThemAll() {
        XCTAssertEqual(UsageFormat.modelName("gpt-5.6-sol", on: ProviderID.codex), "gpt-5.6-sol")
        XCTAssertEqual(UsageFormat.modelName("o3-2025", on: ProviderID.codex), "o3-2025")
        XCTAssertEqual(UsageFormat.modelName("20251001", on: ProviderID.codex), "20251001")
    }

    /// The prefix comes off only when it is the page's own provider. `gpt` is
    /// not `Codex`, so nothing comes off an OpenAI id, and a name that is only
    /// the vendor word survives whole rather than becoming nothing.
    func testTheVendorPrefixComesOffOnlyOnItsOwnPage() {
        XCTAssertEqual(
            UsageFormat.modelName("claude-opus-5", on: ProviderID.claudeCode), "opus-5")
        XCTAssertEqual(
            UsageFormat.modelName("claude-opus-5", on: ProviderID.codex), "claude-opus-5")
        XCTAssertEqual(
            UsageFormat.modelName("gpt-5-codex", on: ProviderID.codex), "gpt-5-codex")
        XCTAssertEqual(UsageFormat.modelName("claude", on: ProviderID.claudeCode), "claude")
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
