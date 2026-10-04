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

    /// That reading as the panel holds it once it has landed for `span`
    /// picked on the calendar, the strip drawn from it.
    private func answer(_ span: UsageDaySpan, filed: [Int]) -> UsagePanelSnapshot.SpanAnswer {
        UsagePanelSnapshot.SpanAnswer(reading(span, filed: filed), period: .days(span), now: now)
    }

    // MARK: A picked day

    /// One past day is read from its own reading: the headline is that day's,
    /// the gauges give way to what each provider spent, and a single day draws
    /// no strip, which would be the figure above it as a rectangle.
    func testAPickedDayReadsItsOwnReadingAndHidesTheGauges() throws {
        let picked = try span(-3, -3)
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(), period: .days(picked), span: answer(picked, filed: [-3]), now: now)

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
            frame: frame(), period: .days(picked), span: answer(elsewhere, filed: [-4]), now: now)
        let empty = UsagePanelSnapshot.make(
            frame: frame(), period: .days(picked), span: answer(picked, filed: []), now: now)

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
            frame: frame(), period: .days(picked), span: answer(picked, filed: [-6, -4, -2]),
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
            frame: frame(), period: .days(picked), span: answer(picked, filed: [-2, 0]), now: now)

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
            span: answer(picked, filed: [-3]), now: now)

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

    // MARK: Wide windows

    /// The strip of `span` with one Claude day filed on each of `filed`.
    private func strip(_ span: UsageDaySpan, filed: [Int]) throws -> UsagePanelSnapshot.DayStrip {
        try XCTUnwrap(answer(span, filed: filed).strip)
    }

    /// Every bar's days, laid end to end, are the window's days: none left out
    /// and none counted twice.
    private func assertBarsTile(
        _ strip: UsagePanelSnapshot.DayStrip, _ span: UsageDaySpan, file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let keys = try strip.rows.flatMap { try XCTUnwrap($0.span).dayKeys }
        XCTAssertEqual(keys, span.dayKeys, file: file, line: line)
    }

    /// Up to the measured threshold a bar is a day, so the archive's default
    /// ninety days still draws one each.
    func testAWindowThatFitsDrawsABarADay() throws {
        let picked = try span(-89, 0)
        let strip = try strip(picked, filed: [-89, -1])

        XCTAssertEqual(DayBarGeometry.maxBars, 96)
        XCTAssertEqual(strip.rows.count, 90)
        XCTAssertTrue(strip.rows.allSatisfy { $0.span?.dayCount() == 1 })
        XCTAssertEqual(strip.rows.first?.title, UsageFormat.dayTitle(day(-89)))
        try assertBarsTile(strip, picked)
    }

    /// Past it a bar is a week, which the hover names by its two ends, and the
    /// bars still add up to the total under them.
    func testAWiderWindowDrawsABarAWeekNamedByItsDays() throws {
        let picked = try span(-199, 0)
        let strip = try strip(picked, filed: [-199, -150, -100, -3])

        XCTAssertLessThanOrEqual(strip.rows.count, DayBarGeometry.maxBars)
        XCTAssertGreaterThan(strip.rows.count, 96 / 7)
        let middle = try XCTUnwrap(strip.rows.dropFirst().first?.span)
        XCTAssertEqual(middle.dayCount(), 7)
        XCTAssertEqual(strip.rows.dropFirst().first?.title, UsageFormat.spanHeading(middle, now: now))
        XCTAssertEqual(strip.rows.compactMap(\.cost).reduce(0, +), Decimal(8))
        XCTAssertEqual(strip.total, "$8.00")
        try assertBarsTile(strip, picked)
    }

    /// Years of archive are a bar a month while the months fit, a whole month
    /// named by its name, and a bar a year past that.
    func testYearsOfArchiveDrawAMonthOrAYearABar() throws {
        let months = try span(-3 * 365, 0)
        let byMonth = try strip(months, filed: [-400])
        let decade = try span(-10 * 365, 0)
        let byYear = try strip(decade, filed: [-3000])

        let month = try XCTUnwrap(byMonth.rows.dropFirst().first)
        let first = try XCTUnwrap(month.span?.from)
        XCTAssertEqual(first, calendar.dateInterval(of: .month, for: first)?.start)
        XCTAssertFalse(month.title.contains(" to "), month.title)
        XCTAssertLessThanOrEqual(byMonth.rows.count, DayBarGeometry.maxBars)
        XCTAssertLessThanOrEqual(byYear.rows.count, 11)
        let year = try XCTUnwrap(byYear.rows.dropFirst().first)
        XCTAssertEqual(year.title.count, 4, year.title)
        try assertBarsTile(byMonth, months)
        try assertBarsTile(byYear, decade)
    }

    /// The strip comes with the answer it was drawn from, so a frame drawn
    /// over a reading that has not changed draws the same strip without
    /// building it again, and an answer for another period draws none.
    func testTheStripIsTheAnswersOwn() throws {
        let picked = try span(-6, -2)
        let held = answer(picked, filed: [-6, -4])
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(), period: .days(picked), span: held, now: now)
        let elsewhere = UsagePanelSnapshot.SpanAnswer(
            reading(picked, filed: [-6]), period: .preset(.sevenDays), now: now)
        let ignored = UsagePanelSnapshot.make(
            frame: frame(), period: .days(picked), span: elsewhere, now: now)

        XCTAssertEqual(snapshot.strip, held.strip)
        XCTAssertNil(ignored.strip)
        XCTAssertEqual(ignored.cost, "—")
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
