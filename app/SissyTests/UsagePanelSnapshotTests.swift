import XCTest

@testable import Sissy

final class UsagePanelSnapshotTests: XCTestCase {
    private func frame(
        providers: [ProviderSlice],
        prev: Int? = nil,
        tokens: String = "26K",
        cost: String = "0.09",
        burn: String = "1.5K",
        history: UsageHistoryRollup? = nil,
        projects: [ProjectTotals] = []
    ) -> FrameData {
        FrameData(
            tokens: tokens,
            cost: cost,
            burn: burn,
            providers: providers,
            prevTokens: prev,
            prevCost: prev.map { Decimal($0) },
            keepAwake: .off,
            history: history,
            projects: projects
        )
    }

    private func slice(
        _ id: String,
        _ tokens: Int,
        _ cost: String,
        windows: [UsageWindow] = [],
        plan: String? = nil,
        planTier: String? = nil
    ) -> ProviderSlice {
        ProviderSlice(
            id: id,
            tokens: tokens,
            cost: Decimal(string: cost)!,
            windows: windows,
            plan: plan,
            planTier: planTier
        )
    }

    private func window(_ minutes: Int, _ usedPercent: Double) throws -> UsageWindow {
        try XCTUnwrap(
            UsageWindow(
                minutes: minutes,
                usedPercent: usedPercent,
                resetsAt: Date(timeIntervalSince1970: 1_789_006_037)
            ))
    }

    // MARK: Rate-limit windows

    func testProviderRowCarriesALabelledWindowPerLimit() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [
                slice("codex", 1000, "1.00", windows: [try window(300, 25), try window(10080, 8)])
            ])
        )
        XCTAssertEqual(snapshot.providers.first?.windows.map(\.label), ["5h", "7d"])
    }

    func testWindowPercentRoundsWhileTheBarStaysClamped() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 1000, "1.00", windows: [try window(300, 104.6)])])
        )
        let row = snapshot.providers.first?.windows.first
        XCTAssertEqual(row?.percent, 105)
        XCTAssertEqual(row?.fraction, 1)
    }

    func testProviderWithoutLimitsReportsNoWindows() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("claude-code", 1000, "1.00")])
        )
        XCTAssertEqual(snapshot.providers.first?.windows, [])
    }

    // MARK: Plan

    func testProviderRowWordsTheVendorPlanToken() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [
                slice("claude-code", 1000, "1.00", plan: "max"),
                slice("codex", 1000, "1.00", plan: "plus"),
            ])
        )
        XCTAssertEqual(snapshot.providers.map(\.plan), ["Max", "Plus"])
    }

    func testProviderWithoutAPlanReportsNone() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("claude-code", 1000, "1.00")])
        )
        XCTAssertNil(snapshot.providers.first?.plan)
    }

    func testProviderRowFoldsTheTierIntoTheBadgeWhenItNamesThePlan() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [
                slice("claude-code", 1000, "1.00", plan: "max", planTier: "max_5x")
            ])
        )
        XCTAssertEqual(snapshot.providers.first?.plan, "Max 5x")
        XCTAssertNil(snapshot.providers.first?.planTier)
    }

    func testProviderRowCarriesAForeignTierSeparately() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [
                slice("claude-code", 1000, "1.00", plan: "team", planTier: "max_5x")
            ])
        )
        XCTAssertEqual(snapshot.providers.first?.plan, "Team")
        XCTAssertEqual(snapshot.providers.first?.planTier, "Max 5x")
    }

    /// A tier cannot arrive on its own: the engine drops it when there is no
    /// plan, and the decoder's own initialiser refuses the pairing too, so a
    /// row can never badge limits it cannot attribute.
    func testATierWithoutAPlanIsDiscarded() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("claude-code", 1000, "1.00", planTier: "max_5x")])
        )
        XCTAssertNil(snapshot.providers.first?.plan)
        XCTAssertNil(snapshot.providers.first?.planTier)
    }

    // MARK: Totals

    func testTotalsComeFromTheProviderSlicesNotTheFormattedScalars() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [
                slice("claude-code", 722_000_000, "478.20"),
                slice("codex", 14_300_000, "14.36"),
            ])
        )
        XCTAssertEqual(snapshot.tokens, "736.3M")
        XCTAssertEqual(snapshot.cost, "$492.56")
    }

    func testFallsBackToFrameScalarsBeforeAnyProviderReports() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [], tokens: "233M", cost: "149")
        )
        XCTAssertEqual(snapshot.tokens, "233M")
        XCTAssertEqual(snapshot.cost, "$149")
    }

    // MARK: Day-over-day delta

    func testDeltaIsUpWhenTodayExceedsYesterday() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 130, "1.00")], prev: 100)
        )
        let delta = try XCTUnwrap(snapshot.delta)
        XCTAssertEqual(delta.direction, .up)
        XCTAssertEqual(delta.percent, 30)
    }

    func testDeltaIsDownWithAPositivePercentage() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 40, "1.00")], prev: 100)
        )
        let delta = try XCTUnwrap(snapshot.delta)
        XCTAssertEqual(delta.direction, .down)
        XCTAssertEqual(delta.percent, 60)
    }

    /// A sub-half-percent move rounds to 0, and an arrow next to "0%" reads
    /// as a rendering bug — so it collapses to `.flat` instead.
    func testSubPercentMoveReadsAsFlat() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 10_002, "1.00")], prev: 10_000)
        )
        let delta = try XCTUnwrap(snapshot.delta)
        XCTAssertEqual(delta.direction, .flat)
        XCTAssertEqual(delta.percent, 0)
    }

    func testNoDeltaWhenTheFrameCarriesNoYesterday() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 100, "1.00")])
        )
        XCTAssertNil(snapshot.delta)
    }

    func testNoDeltaWhenYesterdayWasZero() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 100, "1.00")], prev: 0)
        )
        XCTAssertNil(snapshot.delta)
    }

    func testNoDeltaBeforeTodayHasAnyTokens() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [], prev: 100)
        )
        XCTAssertNil(snapshot.delta)
    }

    // MARK: Provider rows

    func testRowSharesAreProportionalToTokens() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("claude-code", 750, "7.50"), slice("codex", 250, "2.50")])
        )
        XCTAssertEqual(snapshot.providers.map(\.share), [0.75, 0.25])
    }

    func testRowsKeepTheWireOrderAndCarryDisplayNames() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("claude-code", 1, "1.00"), slice("codex", 1, "1.00")])
        )
        XCTAssertEqual(snapshot.providers.map(\.name), ["Claude Code", "Codex"])
    }

    func testRowShareIsZeroWhenNothingWasSpent() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 0, "0")])
        )
        XCTAssertEqual(snapshot.providers.first?.share, 0)
    }

    // MARK: Archive line

    func testTheArchiveLineCarriesTheWindowItCovers() {
        let now = Date()
        let earliest = Calendar.current.date(
            byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: now))
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(
                providers: [slice("codex", 10, "1.00")],
                history: UsageHistoryRollup(
                    days: 7, earliestDay: earliest, tokens: 2_500_000,
                    cost: Decimal(string: "41.5")!)
            ),
            now: now
        )
        XCTAssertEqual(snapshot.history?.label, "Last 7 days")
        XCTAssertEqual(snapshot.history?.tokens, "2.5M")
        XCTAssertEqual(snapshot.history?.cost, "$41.50")
    }

    /// The headline is already today. A second line saying the same thing, a
    /// few seconds behind it, reads as a disagreement.
    func testTheArchiveLineIsAbsentWhileItOnlyReachesBackToToday() {
        let now = Date()
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(
                providers: [slice("codex", 10, "1.00")],
                history: UsageHistoryRollup(
                    days: 7, earliestDay: Calendar.current.startOfDay(for: now),
                    tokens: 10, cost: 1)
            ),
            now: now
        )
        XCTAssertNil(snapshot.history)
    }
}
