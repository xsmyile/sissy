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
            ts: 0,
            primary: tokens,
            primaryLabel: "TOKENS",
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
            ])
        )
        XCTAssertEqual(snapshot.providers.first?.windows.map(\.label), ["5h", "7d"])
    }

    func testWindowPercentRoundsWhileTheBarStaysClamped() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 1000, "1.00", windows: [window(300, 104.6)])])
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

    // MARK: Totals

    func testTotalsComeFromTheProviderSlicesNotTheOledScalars() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [
                slice("claude-code", 722_000_000, "478.20"),
                slice("codex", 14_300_000, "14.36"),
            ])
        )
        XCTAssertEqual(snapshot.tokens, "736.3M")
        XCTAssertEqual(snapshot.cost, "$492.56")
    }

    func testFallsBackToDaemonScalarsBeforeAnyProviderReports() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [], tokens: "233M", cost: "149")
        )
        XCTAssertEqual(snapshot.tokens, "233M")
        XCTAssertEqual(snapshot.cost, "$149")
    }

    // MARK: Day-over-day delta

    func testDeltaIsUpWhenTodayExceedsYesterday() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 130, "1.00")], prev: .init(tokens: 100, cost: 1))
        )
        let delta = try XCTUnwrap(snapshot.delta)
        XCTAssertEqual(delta.direction, .up)
        XCTAssertEqual(delta.percent, 30)
    }

    func testDeltaIsDownWithAPositivePercentage() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 40, "1.00")], prev: .init(tokens: 100, cost: 1))
        )
        let delta = try XCTUnwrap(snapshot.delta)
        XCTAssertEqual(delta.direction, .down)
        XCTAssertEqual(delta.percent, 60)
    }

    /// A sub-half-percent move rounds to 0, and an arrow next to "0%" reads
    /// as a rendering bug — so it collapses to `.flat` instead.
    func testSubPercentMoveReadsAsFlat() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 10_002, "1.00")], prev: .init(tokens: 10_000, cost: 1))
        )
        let delta = try XCTUnwrap(snapshot.delta)
        XCTAssertEqual(delta.direction, .flat)
        XCTAssertEqual(delta.percent, 0)
    }

    func testNoDeltaWhenTheDaemonHasNotShippedYesterday() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 100, "1.00")])
        )
        XCTAssertNil(snapshot.delta)
    }

    func testNoDeltaWhenYesterdayWasZero() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 100, "1.00")], prev: .init(tokens: 0, cost: 0))
        )
        XCTAssertNil(snapshot.delta)
    }

    func testNoDeltaBeforeTodayHasAnyTokens() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [], prev: .init(tokens: 100, cost: 1))
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
}
