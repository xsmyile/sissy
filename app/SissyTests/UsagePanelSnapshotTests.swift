import XCTest

@testable import Sissy

final class UsagePanelSnapshotTests: XCTestCase {
    private func frame(
        providers: [DisplayFrame.ProviderSlice],
        prev: DisplayFrame.PrevTotals? = nil,
        tokens: String = "26K",
        cost: String = "0.09",
        burn: String = "1.5K"
    ) -> DisplayFrame {
        DisplayFrame(
            tokens: tokens,
            cost: cost,
            burn: burn,
            state: "code",
            ts: 0,
            primary: tokens,
            primaryLabel: "TOKENS",
            devicePresent: false,
            milestone: nil,
            providers: providers,
            prev: prev
        )
    }

    private func slice(
        _ id: String,
        _ tokens: Int,
        _ cost: String,
        windows: [DisplayFrame.UsageWindow] = []
    ) -> DisplayFrame.ProviderSlice {
        DisplayFrame.ProviderSlice(
            id: id,
            tokens: tokens,
            cost: Decimal(string: cost)!,
            windows: windows
        )
    }

    private func window(_ minutes: Int, _ usedPercent: Double) -> DisplayFrame.UsageWindow {
        DisplayFrame.UsageWindow(
            minutes: minutes,
            usedPercent: usedPercent,
            resetsAt: Date(timeIntervalSince1970: 1_789_006_037)
        )
    }

    // MARK: Rate-limit windows

    func testProviderRowCarriesALabelledWindowPerLimit() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [
                slice("codex", 1000, "1.00", windows: [window(300, 25), window(10080, 8)])
            ]),
            milestoneFrequency: .normal
        )
        XCTAssertEqual(snapshot.providers.first?.windows.map(\.label), ["5h", "7d"])
    }

    func testWindowPercentRoundsWhileTheBarStaysClamped() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 1000, "1.00", windows: [window(300, 104.6)])]),
            milestoneFrequency: .normal
        )
        let row = snapshot.providers.first?.windows.first
        XCTAssertEqual(row?.percent, 105)
        XCTAssertEqual(row?.fraction, 1)
    }

    func testProviderWithoutLimitsReportsNoWindows() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("claude-code", 1000, "1.00")]),
            milestoneFrequency: .normal
        )
        XCTAssertEqual(snapshot.providers.first?.windows, [])
    }

    // MARK: Totals

    func testTotalsComeFromTheProviderSlicesNotTheOledScalars() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [
                slice("claude-code", 722_000_000, "478.20"),
                slice("codex", 14_300_000, "14.36"),
            ]),
            milestoneFrequency: .normal
        )
        XCTAssertEqual(snapshot.tokens, "736.3M")
        XCTAssertEqual(snapshot.cost, "$492.56")
    }

    func testFallsBackToDaemonScalarsBeforeAnyProviderReports() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [], tokens: "233M", cost: "149"),
            milestoneFrequency: .normal
        )
        XCTAssertEqual(snapshot.tokens, "233M")
        XCTAssertEqual(snapshot.cost, "$149")
    }

    // MARK: Day-over-day delta

    func testDeltaIsUpWhenTodayExceedsYesterday() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 130, "1.00")], prev: .init(tokens: 100, cost: 1)),
            milestoneFrequency: .normal
        )
        let delta = try XCTUnwrap(snapshot.delta)
        XCTAssertEqual(delta.direction, .up)
        XCTAssertEqual(delta.percent, 30)
    }

    func testDeltaIsDownWithAPositivePercentage() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 40, "1.00")], prev: .init(tokens: 100, cost: 1)),
            milestoneFrequency: .normal
        )
        let delta = try XCTUnwrap(snapshot.delta)
        XCTAssertEqual(delta.direction, .down)
        XCTAssertEqual(delta.percent, 60)
    }

    /// A sub-half-percent move rounds to 0, and an arrow next to "0%" reads
    /// as a rendering bug — so it collapses to `.flat` instead.
    func testSubPercentMoveReadsAsFlat() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 10_002, "1.00")], prev: .init(tokens: 10_000, cost: 1)),
            milestoneFrequency: .normal
        )
        let delta = try XCTUnwrap(snapshot.delta)
        XCTAssertEqual(delta.direction, .flat)
        XCTAssertEqual(delta.percent, 0)
    }

    func testNoDeltaWhenTheDaemonHasNotShippedYesterday() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 100, "1.00")]),
            milestoneFrequency: .normal
        )
        XCTAssertNil(snapshot.delta)
    }

    func testNoDeltaWhenYesterdayWasZero() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 100, "1.00")], prev: .init(tokens: 0, cost: 0)),
            milestoneFrequency: .normal
        )
        XCTAssertNil(snapshot.delta)
    }

    func testNoDeltaBeforeTodayHasAnyTokens() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [], prev: .init(tokens: 100, cost: 1)),
            milestoneFrequency: .normal
        )
        XCTAssertNil(snapshot.delta)
    }

    // MARK: Milestone progress

    func testMilestoneTargetsTheNextStepAboveTodaysSpend() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("claude-code", 1, "492.56")]),
            milestoneFrequency: .normal
        )
        let milestone = try XCTUnwrap(snapshot.milestone)
        XCTAssertEqual(milestone.nextDollars, 500)
        XCTAssertEqual(milestone.fraction, 0.7024, accuracy: 0.0001)
        XCTAssertEqual(milestone.remaining, Decimal(string: "7.44"))
    }

    func testMilestoneFollowsTheSelectedPreset() throws {
        let spend = frame(providers: [slice("claude-code", 1, "12.00")])
        let frequent = UsagePanelSnapshot.make(frame: spend, milestoneFrequency: .frequent)
        let rare = UsagePanelSnapshot.make(frame: spend, milestoneFrequency: .rare)
        XCTAssertEqual(try XCTUnwrap(frequent.milestone).nextDollars, 20)
        XCTAssertEqual(try XCTUnwrap(rare.milestone).nextDollars, 100)
    }

    /// Truncating toward zero is what keeps the panel's target aligned with
    /// the crossing the daemon actually celebrates.
    func testExactCrossingTargetsTheFollowingStep() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("claude-code", 1, "25.00")]),
            milestoneFrequency: .normal
        )
        let milestone = try XCTUnwrap(snapshot.milestone)
        XCTAssertEqual(milestone.nextDollars, 50)
        XCTAssertEqual(milestone.fraction, 0, accuracy: 0.0001)
        XCTAssertEqual(milestone.remaining, Decimal(string: "25.00"))
    }

    func testZeroSpendTargetsTheFirstStep() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: []),
            milestoneFrequency: .frequent
        )
        let milestone = try XCTUnwrap(snapshot.milestone)
        XCTAssertEqual(milestone.nextDollars, 10)
        XCTAssertEqual(milestone.fraction, 0, accuracy: 0.0001)
    }

    // MARK: Provider rows

    func testRowSharesAreProportionalToTokens() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("claude-code", 750, "7.50"), slice("codex", 250, "2.50")]),
            milestoneFrequency: .normal
        )
        XCTAssertEqual(snapshot.providers.map(\.share), [0.75, 0.25])
    }

    func testRowsKeepTheWireOrderAndCarryDisplayNames() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("claude-code", 1, "1.00"), slice("codex", 1, "1.00")]),
            milestoneFrequency: .normal
        )
        XCTAssertEqual(snapshot.providers.map(\.name), ["Claude Code", "Codex"])
    }

    func testRowShareIsZeroWhenNothingWasSpent() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 0, "0")]),
            milestoneFrequency: .normal
        )
        XCTAssertEqual(snapshot.providers.first?.share, 0)
    }
}
