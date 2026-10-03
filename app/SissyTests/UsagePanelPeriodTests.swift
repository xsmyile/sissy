import XCTest

@testable import Sissy

/// The panel over a window other than today: a day or a run of days picked on
/// the calendar, and the presets now that their projects follow them.
final class UsagePanelPeriodTests: XCTestCase {
    private let calendar = Calendar.current
    private lazy var now: Date =
        calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) ?? now
    }

    private func span(_ from: Int, _ to: Int) throws -> UsageDaySpan {
        try XCTUnwrap(UsageDaySpan(from: day(from), to: day(to), now: now))
    }

    private func frame(history: [UsagePeriod: UsageHistoryRollup] = archive()) -> FrameData {
        FrameData(
            tokens: 10,
            cost: Decimal(1),
            burn: 1500,
            providers: [
                ProviderSlice(
                    id: ProviderID.claudeCode, tokens: 10, cost: Decimal(1),
                    projects: [ProjectTotals(path: "/work/today", tokens: 10, cost: Decimal(1))])
            ],
            keepAwake: .off,
            history: history,
            projects: [ProjectTotals(path: "/work/today", tokens: 10, cost: Decimal(1))]
        )
    }

    private static func archive(
        projects: [ProjectTotals] = [], unattributed: UsageSpend = UsageSpend()
    ) -> [UsagePeriod: UsageHistoryRollup] {
        Dictionary(
            uniqueKeysWithValues: UsagePeriod.archived.map {
                (
                    $0,
                    UsageHistoryRollup(
                        period: .preset($0), earliestDay: Date.distantPast, tokens: 2_500_000,
                        cost: Decimal(string: "41.5") ?? 0, projects: projects,
                        unattributed: unattributed)
                )
            })
    }

    /// A reading of `span` as the archive would answer it: one Claude day on
    /// each of `filed`, the rest of the span holding no file.
    private func reading(_ span: UsageDaySpan, filed: [Int]) -> UsageSpanReading {
        let days = filed.map { UsageHistoryDayTotal(day: day($0), tokens: 1_000, cost: Decimal(2)) }
        let spend = UsageSpend(tokens: 1_000 * days.count, cost: Decimal(2 * days.count))
        return UsageSpanReading(
            rollup: UsageHistoryRollup(
                period: .days(span), earliestDay: days.first?.day, tokens: spend.tokens,
                cost: spend.cost,
                agentsByProvider: [ProviderID.claudeCode: AgentCounts(sessions: 3, agents: 2)],
                activity: ActivityTotals(activeMinutes: 90),
                activityByProvider: [ProviderID.claudeCode: ActivityTotals(activeMinutes: 90)],
                spendByProvider: [ProviderID.claudeCode: spend],
                projects: [ProjectTotals(path: "/work/past", tokens: spend.tokens, cost: spend.cost)]),
            days: days)
    }

    // MARK: A picked day

    /// One past day is read from its own reading: the headline is that day's,
    /// the gauges give way to what each provider spent, and a single day draws
    /// no strip, which would be the figure above it as a rectangle.
    func testAPickedDayReadsItsOwnReadingAndHidesTheGauges() throws {
        let picked = try span(-3, -3)
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(), period: .days(picked), span: reading(picked, filed: [-3]), now: now)

        XCTAssertEqual(snapshot.period, .days(picked))
        XCTAssertEqual(snapshot.cost, "$2.00")
        XCTAssertEqual(snapshot.tokens, "1.0K")
        XCTAssertFalse(snapshot.includesToday)
        XCTAssertEqual(snapshot.spendRows.map(\.id), [ProviderID.claudeCode])
        XCTAssertNil(snapshot.strip)
        XCTAssertNil(snapshot.burn)
        XCTAssertEqual(snapshot.worked, "1h30 active")
    }

    /// Until its reading lands, and when it lands empty, a picked window has
    /// no figure: a zero there would be a measurement nobody took.
    func testAPickedDayWithNoReadingIsADashNotAZero() throws {
        let picked = try span(-3, -3)
        let elsewhere = try span(-4, -4)
        let pending = UsagePanelSnapshot.make(
            frame: frame(), period: .days(picked), span: reading(elsewhere, filed: [-4]), now: now)
        let empty = UsagePanelSnapshot.make(
            frame: frame(), period: .days(picked), span: reading(picked, filed: []), now: now)

        XCTAssertEqual(pending.cost, "—")
        XCTAssertNil(pending.window)
        XCTAssertEqual(empty.cost, "—")
        XCTAssertEqual(empty.coverage, UsageFormat.notRunning)
    }

    // MARK: A past range

    /// A run of past days draws a bar for every day, a day with no file as
    /// the strip's dot, and each provider's row carries the window's spend
    /// with its sessions, sub-agents and worked time under it.
    func testAPastRangeDrawsEveryDayAndTheProvidersSpend() throws {
        let picked = try span(-6, -2)
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(), period: .days(picked), span: reading(picked, filed: [-6, -4, -2]),
            now: now)

        let strip = try XCTUnwrap(snapshot.strip)
        XCTAssertEqual(strip.rows.count, 5)
        XCTAssertEqual(strip.rows.map { $0.cost != nil }, [true, false, true, false, true])
        XCTAssertEqual(strip.total, "$6.00")
        XCTAssertTrue(strip.label.hasSuffix("3 of 5 days"))
        let row = try XCTUnwrap(snapshot.spendRows.first)
        XCTAssertEqual(row.spend, "3.0K · $6.00")
        XCTAssertEqual(row.work, "3 sessions · 2 sub-agents · 1h30 active")
        XCTAssertEqual(snapshot.projects.map(\.name), ["past"])
    }

    // MARK: A range reaching today

    /// A window that reaches today keeps the gauges: the pressure is now, and
    /// a window holding now is the one it belongs beside.
    func testARangeIncludingTodayKeepsTheGaugesAndDrawsNoSpendRows() throws {
        let picked = try span(-2, 0)
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(), period: .days(picked), span: reading(picked, filed: [-2, 0]), now: now)

        XCTAssertTrue(snapshot.includesToday)
        XCTAssertTrue(snapshot.spendRows.isEmpty)
        XCTAssertFalse(snapshot.gaugeRows.isEmpty)
        XCTAssertEqual(snapshot.strip?.rows.last?.isToday, true)
    }

    /// Today picked on the calendar is the `Today` preset, so one day is never
    /// read under two names, one of them lagging the tail.
    func testTodayPickedOnTheCalendarIsTheTodayPreset() throws {
        XCTAssertEqual(SissyModel.normalized(.days(try span(0, 0)), now: now), .preset(.today))
        XCTAssertEqual(
            SissyModel.normalized(.days(try span(-1, 0)), now: now), .days(try span(-1, 0)))
    }

    /// With no archive there is nothing to read a picked window from, and the
    /// panel reads today rather than a blank.
    func testAPickedWindowWithNoArchiveFallsBackToToday() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(history: [:]), period: .days(try span(-3, -3)), now: now)

        XCTAssertEqual(snapshot.period, .preset(.today))
        XCTAssertEqual(snapshot.cost, "$1.00")
    }

    /// In the moment after launch the frame carries no windows until the
    /// engine's first rollup lands. With the archive kept, a chosen window
    /// stands and reads as the dash rather than as today's figure under its
    /// name; a picked one still reads its own span.
    func testAChosenWindowWaitsForTheFirstRollupRatherThanReadingToday() throws {
        let picked = try span(-3, -3)
        let week = UsagePanelSnapshot.make(
            frame: frame(history: [:]), period: .preset(.sevenDays), archiveKept: true, now: now)
        let day = UsagePanelSnapshot.make(
            frame: frame(history: [:]), period: .days(picked), archiveKept: true,
            span: reading(picked, filed: [-3]), now: now)

        XCTAssertEqual(week.period, .preset(.sevenDays))
        XCTAssertEqual(week.cost, "—")
        XCTAssertEqual(week.tokens, "—")
        XCTAssertTrue(week.projects.isEmpty)
        XCTAssertEqual(day.period, .days(picked))
        XCTAssertEqual(day.cost, "$2.00")
    }

    // MARK: Projects

    /// Under seven days the projects block and its page read the week from the
    /// archive, with what named no repository as the page's residue, where
    /// they used to read today under a week's headline.
    func testProjectsFollowSevenDays() throws {
        let week = Self.archive(
            projects: [
                ProjectTotals(path: "/work/alpha", tokens: 2_000_000, cost: Decimal(30)),
                ProjectTotals(path: "/work/beta", tokens: 400_000, cost: Decimal(10)),
            ],
            unattributed: UsageSpend(tokens: 100_000, cost: Decimal(string: "1.5") ?? 0))
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(history: week), period: .preset(.sevenDays), now: now)
        let page = UsagePanelSnapshot.projectsPage(
            frame: frame(history: week), provider: nil, period: snapshot.period,
            window: snapshot.window)

        XCTAssertEqual(snapshot.projects.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(snapshot.projectCount, 2)
        XCTAssertEqual(page.rows.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(page.residue?.cost, "$1.50")
        XCTAssertTrue(page.subtitle.hasPrefix("7 days · 2 projects"))
    }

    /// The `Today` preset keeps the live day buckets, which run ahead of the
    /// archive's copy of today.
    func testTodayKeepsTheLiveProjects() {
        let snapshot = UsagePanelSnapshot.make(frame: frame(), period: .preset(.today), now: now)

        XCTAssertEqual(snapshot.projects.map(\.name), ["today"])
    }

    // MARK: Sessions

    /// The Sessions tab reads a picked window from its own rollup.
    func testSessionsReadAPickedWindow() throws {
        let picked = try span(-6, -2)
        let rollup = reading(picked, filed: [-6]).rollup
        let block = UsagePanelSnapshot.makeAgents(frame(), window: rollup, now: now)

        XCTAssertEqual(
            block.window(for: .days(picked))?.byProvider.first?.counts,
            AgentCounts(sessions: 3, agents: 2))
        XCTAssertNil(block.window(for: .days(try span(-5, -2))))
    }

    /// A picked window the archive holds no day of counts nothing, so the
    /// tab draws the absence the headline does rather than zeros.
    func testSessionsDrawNoCountsForAPickedWindowWithNoReading() throws {
        let picked = try span(-6, -2)
        let empty = reading(picked, filed: []).rollup
        let block = UsagePanelSnapshot.makeAgents(frame(), window: empty, now: now)

        XCTAssertNil(block.window(for: .days(picked)))
    }

    // MARK: Calendar

    /// A month lands each day under its weekday, flags the days still to come,
    /// and ignores a reading of another month.
    func testTheCalendarMonthPlacesItsDaysAndIgnoresAnotherMonthsReading() throws {
        let month = try XCTUnwrap(calendar.dateInterval(of: .month, for: now)?.start)
        let thisMonth = try XCTUnwrap(UsageDaySpan.month(containing: month, now: now))
        let grid = try XCTUnwrap(
            CalendarMonth.make(month: month, reading: reading(thisMonth, filed: [0]), now: now))
        let stale = try XCTUnwrap(
            CalendarMonth.make(
                month: month, reading: reading(try span(-40, -40), filed: [-40]), now: now))

        let weekday = calendar.component(.weekday, from: month)
        XCTAssertEqual(grid.leading, (weekday - calendar.firstWeekday + 7) % 7)
        XCTAssertEqual(grid.cells.count, calendar.range(of: .day, in: .month, for: month)?.count)
        XCTAssertEqual(grid.cells.first { $0.isToday }?.cost, Decimal(2))
        XCTAssertEqual(
            grid.cells.filter(\.isFuture).count,
            grid.cells.count - calendar.component(.day, from: now))
        XCTAssertNil(stale.caption.firstIndex(of: "·"))
        XCTAssertTrue(stale.cells.allSatisfy { $0.cost == nil })
    }
}
