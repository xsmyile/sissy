import XCTest

@testable import Sissy

/// At what effort a window was worked, as the pills under `Sessions and
/// agents` read it.
final class UsageEffortPillsTests: XCTestCase {
    private func frame(
        providers: [ProviderSlice] = [], history: [UsagePeriod: UsageHistoryRollup] = [:]
    ) -> FrameData {
        FrameData(
            tokens: 0, cost: 0, burn: nil, providers: providers, keepAwake: .off,
            history: history)
    }

    private func slice(_ id: String, effort: EffortCounts) -> ProviderSlice {
        ProviderSlice(id: id, tokens: 1, cost: 1, effort: effort)
    }

    private func rollup(_ period: UsagePeriod, effort: EffortCounts) -> UsageHistoryRollup {
        UsageHistoryRollup(
            period: period, earliestDay: nil, tokens: 1, cost: 1, effort: effort)
    }

    private func pills(_ window: UsagePeriod, in frame: FrameData) throws -> [(String, String)] {
        let block = UsagePanelSnapshot.make(frame: frame).agents
        return try XCTUnwrap(block.counted[window]).effort.map { ($0.name, $0.reading) }
    }

    func testTodaysPillsSumTheSlicesAndNameTheirShare() throws {
        let frame = frame(providers: [
            slice(ProviderID.claudeCode, effort: EffortCounts(["xhigh": 46, "high": 1])),
            slice(ProviderID.codex, effort: EffortCounts(["high": 3])),
        ])
        XCTAssertEqual(
            try pills(.today, in: frame).map(\.0), ["xhigh", "high"])
        XCTAssertEqual(
            try pills(.today, in: frame).map(\.1), ["92% · 46", "8% · 4"])
    }

    /// The window's own figure, not today's wearing its label.
    func testAWindowsPillsComeFromTheArchive() throws {
        let frame = frame(
            providers: [slice(ProviderID.claudeCode, effort: EffortCounts(["low": 2]))],
            history: [.sevenDays: rollup(.sevenDays, effort: EffortCounts(["xhigh": 300]))])
        XCTAssertEqual(try pills(.sevenDays, in: frame).map(\.0), ["xhigh"])
        XCTAssertEqual(try pills(.sevenDays, in: frame).map(\.1), ["100% · 300"])
    }

    /// A provider that names none contributes none, and the others still read
    /// as shares of the turns that were measured.
    func testAProviderNamingNoEffortDoesNotMakeTheOthersReadShort() throws {
        let frame = frame(providers: [
            slice(ProviderID.claudeCode, effort: EffortCounts(["xhigh": 10])),
            slice(ProviderID.codex, effort: .none),
        ])
        XCTAssertEqual(try pills(.today, in: frame).map(\.1), ["100% · 10"])
    }

    /// An absent reading is not a reading of zero, so a window whose days
    /// predate the field draws no pills at all.
    func testAWindowThatNamedNoEffortDrawsNoPills() throws {
        let frame = frame(
            providers: [slice(ProviderID.claudeCode, effort: .none)],
            history: [.thirtyDays: rollup(.thirtyDays, effort: .none)])
        XCTAssertTrue(try pills(.today, in: frame).isEmpty)
        XCTAssertTrue(try pills(.thirtyDays, in: frame).isEmpty)
    }

    /// A share that rounds to nothing beside a count that is not zero is the
    /// same lie in smaller type.
    func testAShareTooSmallToRoundIsWordedRatherThanRoundedAway() throws {
        let frame = frame(providers: [
            slice(ProviderID.claudeCode, effort: EffortCounts(["xhigh": 500, "low": 1]))
        ])
        XCTAssertEqual(try pills(.today, in: frame).map(\.1), ["100% · 500", "<1% · 1"])
    }

    /// Past four the pills stop fitting the page, so the quietest fold into
    /// one carrying their summed share and count.
    func testEffortsPastFourFoldIntoOnePill() throws {
        let frame = frame(providers: [
            slice(
                ProviderID.claudeCode,
                effort: EffortCounts([
                    "ultra": 50, "xhigh": 30, "high": 10, "medium": 8, "low": 2,
                ]))
        ])
        XCTAssertEqual(
            try pills(.today, in: frame).map(\.0), ["ultra", "xhigh", "high", "+2 more"])
        XCTAssertEqual(try pills(.today, in: frame).last?.1, "10% · 10")
    }
}
