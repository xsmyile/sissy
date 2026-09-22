import XCTest

@testable import Sissy

/// What the pills answer for while the pointer moves along the strip: the day
/// it is on, today when it is on none, and nothing at all for a day the
/// archive never wrote.
final class UsageModelHoverTests: XCTestCase {
    private static let stripDays = 7

    func testEachBarCarriesItsOwnDaysSplit() throws {
        let now = Date()
        let strip = try XCTUnwrap(
            makeStrip(
                series: [
                    archived(
                        1, cost: "10.00", now: now,
                        models: [
                            totals("claude-opus-5", 800, "7.50"), totals("claude-sonnet-5", 200, "2.50"),
                        ])
                ],
                now: now))

        let yesterday = try XCTUnwrap(strip.rows.dropLast().last)
        XCTAssertEqual(yesterday.models.map(\.name), ["opus-5", "sonnet-5"])
        XCTAssertEqual(yesterday.models.map(\.reading), ["75% · $7.50", "25% · $2.50"])
    }

    /// The pointed day's percentages are shares of that day, not of today.
    /// Sharing today's total would make every past bar read as a fraction of
    /// a figure it has nothing to do with.
    func testAPastDaysPercentagesAreSharesOfThatDay() throws {
        let now = Date()
        let strip = try XCTUnwrap(
            makeStrip(
                series: [
                    archived(
                        2, cost: "4.00", now: now,
                        models: [
                            totals("claude-opus-5", 300, "3.00"), totals("claude-sonnet-5", 100, "1.00"),
                        ])
                ],
                todayCost: Decimal(1_000),
                now: now))

        let day = try XCTUnwrap(strip.rows.first { $0.models.isEmpty == false && !$0.isToday })
        XCTAssertEqual(day.models.map(\.reading), ["75% · $3.00", "25% · $1.00"])
    }

    /// A day Sissy was not running for still gets a bar, and that bar has no
    /// split. An absent reading is not a reading of zero, and the pills must
    /// not keep the last day that had one.
    func testADayTheArchiveNeverWroteHasNoPills() throws {
        let now = Date()
        let strip = try XCTUnwrap(
            makeStrip(
                series: [
                    archived(1, cost: "10.00", now: now, models: [totals("claude-opus-5", 800, "10.00")])
                ],
                now: now))

        let missing = try XCTUnwrap(strip.rows.first { $0.cost == nil })
        XCTAssertTrue(missing.models.isEmpty)
    }

    /// Today's bar draws the rows the block under it is already drawing rather
    /// than a second derivation of them, so the last bar cannot disagree with
    /// the page it sits on.
    func testTodaysBarCarriesTheRowsTheBlockAlreadyHas() throws {
        let now = Date()
        let today = [
            UsagePanelSnapshot.ModelRow(
                id: "claude-opus-5", name: "opus-5", reading: "100% · $8.46", detail: "d")
        ]
        let strip = try XCTUnwrap(
            makeStrip(
                series: [
                    archived(1, cost: "10.00", now: now, models: [totals("claude-opus-5", 800, "10.00")])
                ],
                todayModels: today, now: now))

        XCTAssertEqual(strip.rows.last?.models, today)
    }

    // MARK: Helpers

    private func makeStrip(
        series: [UsageHistoryDaySummary],
        todayCost: Decimal = Decimal(20),
        todayModels: [UsagePanelSnapshot.ModelRow] = [],
        now: Date
    ) -> UsagePanelSnapshot.DayStrip? {
        UsagePanelSnapshot.dayStrip(
            series: series, provider: ProviderID.claudeCode, todayTokens: 500,
            todayCost: todayCost, todayModels: todayModels,
            days: Self.stripDays, now: now)
    }

    private func archived(
        _ back: Int, cost: String, now: Date, models: [ModelTotals]
    ) -> UsageHistoryDaySummary {
        let day = Calendar.current.date(
            byAdding: .day, value: -back, to: Calendar.current.startOfDay(for: now))!
        return UsageHistoryDaySummary(
            day: day,
            tokens: models.reduce(0) { $0 + $1.tokens },
            cost: Decimal(string: cost) ?? 0,
            models: models)
    }

    private func totals(_ model: String, _ tokens: Int, _ cost: String) -> ModelTotals {
        ModelTotals(
            model: model,
            totals: UsageHistoryTotals(
                inputTokens: tokens, cost: Decimal(string: cost) ?? 0))
    }

}
