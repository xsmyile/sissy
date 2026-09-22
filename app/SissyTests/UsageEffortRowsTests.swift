import XCTest

@testable import Sissy

/// The provider page's `By effort` block: a row per model, each saying how
/// that model's spend split across the efforts it ran at.
final class UsageEffortRowsTests: XCTestCase {
    private func split(
        _ model: String, _ effort: String?, turns: Int, cost: String, tokens: Int = 100
    ) -> EffortSplit {
        EffortSplit(
            model: model, effort: effort,
            totals: EffortTotals(
                turns: turns,
                totals: UsageHistoryTotals(
                    inputTokens: tokens, cost: Decimal(string: cost) ?? 0)))
    }

    private func rows(_ splits: [EffortSplit], provider: String = ProviderID.codex)
        -> [UsagePanelSnapshot.EffortRow]
    {
        UsagePanelSnapshot.makeEffort(splits, provider: provider)
    }

    /// Each row's shares are of its own model, so they sum across the row and
    /// never across the block: the question is how this model's spend split.
    func testARowsSharesAreOfItsOwnModel() {
        let out = rows([
            split("gpt-6-astra", "medium", turns: 545, cost: "6.10"),
            split("gpt-6-astra", "high", turns: 345, cost: "4.71"),
            split("gpt-5.6-sol", "high", turns: 172, cost: "2.41"),
            split("gpt-5.6-sol", "medium", turns: 35, cost: "0.49"),
        ])
        XCTAssertEqual(out.map(\.name), ["gpt-6-astra", "gpt-5.6-sol"])
        XCTAssertEqual(out.first?.run, "medium 56% · high 44%")
        XCTAssertEqual(out.last?.run, "high 83% · medium 17%")
    }

    /// Dearest model first, and inside a row the dearest effort first.
    func testModelsAndEffortsAreOrderedByWhatTheyCost() {
        let out = rows([
            split("cheap", "low", turns: 1, cost: "0.01"),
            split("dear", "medium", turns: 1, cost: "1.00"),
            split("dear", "ultra", turns: 1, cost: "9.00"),
        ])
        XCTAssertEqual(out.map(\.name), ["dear", "cheap"])
        XCTAssertEqual(out.first?.run, "ultra 90% · medium 10%")
    }

    /// A share too small to round is not a share of nothing, which is the
    /// rule the model pills already hold.
    func testAShareTooSmallToRoundIsWordedRatherThanRoundedAway() {
        let out = rows([
            split("astra", "medium", turns: 500, cost: "100.00"),
            split("astra", "ultra", turns: 1, cost: "0.20"),
        ])
        XCTAssertEqual(out.first?.run, "medium 100% · ultra <1%")
    }

    /// A model the pricing sources do not know books tokens at a cost of zero,
    /// and zero is what it is not — so the window shares by tokens instead.
    func testAnUnpricedPairSharesByTokensRatherThanByMoney() {
        let out = rows([
            split("unknown", "high", turns: 2, cost: "0", tokens: 300),
            split("unknown", "low", turns: 1, cost: "0", tokens: 100),
        ])
        XCTAssertEqual(out.first?.run, "high 75% · low 25%")
    }

    /// The money and the turns are what the run has no room for, so they are
    /// the hover and the spoken label.
    func testTheRowCarriesTheMoneyAndTheTurnsOnItsDetail() {
        let out = rows([split("astra", "medium", turns: 545, cost: "6.10")])
        XCTAssertEqual(out.first?.detail, "medium $6.10 · 545 turns")
    }

    /// Uncapped: the pills fold at four because four is what 312 pt holds side
    /// by side, and these rows are stacked. Dropping a model's row without
    /// saying so is the one thing this block cannot do, since which model ran
    /// at what is its whole subject.
    func testEveryModelTheWindowSpentOnGetsARow() {
        let out = rows(
            (1...6).map { split("m\($0)", "high", turns: 1, cost: "\(10 - $0).00") })
        XCTAssertEqual(out.map(\.name), ["m1", "m2", "m3", "m4", "m5", "m6"])
    }

    /// An absent reading is not a reading of zero: a window that named no
    /// effort gets no block rather than an empty one.
    func testAWindowThatNamedNoEffortHasNoRows() {
        XCTAssertTrue(rows([]).isEmpty)
    }

    /// The name is the one the pills above spell, so the two blocks do not
    /// call one model two things.
    func testTheRowNamesTheModelTheWayThePillsDo() {
        let out = rows(
            [split("claude-opus-5", "xhigh", turns: 1, cost: "1")],
            provider: ProviderID.claudeCode)
        XCTAssertEqual(out.first?.name, "opus-5")
    }

    /// The window is the strip's, so a day's splits and today's are one
    /// reading before any share is taken.
    func testTheArchivedDaysAndTodayAreSummedBeforeSharing() {
        let archived = [split("astra", "high", turns: 10, cost: "1.00")]
        let today = [split("astra", "high", turns: 5, cost: "0.50")]
        let summed = archived.summed(with: today)
        XCTAssertEqual(summed.count, 1)
        XCTAssertEqual(summed.first?.turns, 15)
        XCTAssertEqual(summed.first?.cost, Decimal(string: "1.50"))
    }

    /// An event whose line named no effort still counts in the model's rows,
    /// so leaving it out here would put `high 100%` under a pill counting more
    /// than the run accounts for.
    func testSpendThatNamedNoEffortStaysInTheDenominator() {
        let out = rows([
            split("astra", "high", turns: 9, cost: "9.00"),
            split("astra", nil, turns: 1, cost: "1.00"),
        ])
        XCTAssertEqual(out.first?.run, "high 90% · unattributed 10%")
    }

    /// It is not an effort, so it never takes the rank a setting would: last
    /// however large, the rule the projects residue already holds.
    func testUnattributedSpendIsTheLastClauseHoweverLargeItIs() {
        let out = rows([
            split("astra", nil, turns: 90, cost: "90.00"),
            split("astra", "high", turns: 10, cost: "10.00"),
        ])
        XCTAssertEqual(out.first?.run, "high 10% · unattributed 90%")
    }

    /// A row reading `unattributed 100%` is an absent reading dressed as one.
    func testAModelWhoseSplitIsOnlyUnattributedGetsNoRow() {
        XCTAssertTrue(rows([split("astra", nil, turns: 5, cost: "5.00")]).isEmpty)
    }

    /// The hover names it too, since the run has no room for the money.
    func testTheDetailNamesTheUnattributedSpend() {
        let out = rows([
            split("astra", "high", turns: 9, cost: "9.00"),
            split("astra", nil, turns: 1, cost: "1.00"),
        ])
        XCTAssertEqual(out.first?.detail, "high $9.00 · 9 turns · unattributed $1.00 · 1 turn")
    }
}
