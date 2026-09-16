import XCTest

@testable import Sissy

final class UsagePanelSnapshotTests: XCTestCase {
    /// The day's scalars are the slices summed unless a test says otherwise,
    /// the way the engine builds one: a frame whose headline disagrees with
    /// its own rows cannot happen outside a fixture.
    private func frame(
        providers: [ProviderSlice],
        burn: Double? = 1500,
        history: [UsagePeriod: UsageHistoryRollup] = [:],
        projects: [ProjectTotals] = []
    ) -> FrameData {
        FrameData(
            tokens: providers.reduce(0) { $0 + $1.tokens },
            cost: providers.reduce(Decimal(0)) { $0 + $1.cost },
            burn: burn,
            providers: providers,
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
        planTier: String? = nil,
        credits: ProviderCredits? = nil,
        account: ProviderAccount? = nil
    ) -> ProviderSlice {
        ProviderSlice(
            id: id,
            tokens: tokens,
            cost: Decimal(string: cost)!,
            windows: windows,
            plan: plan,
            planTier: planTier,
            credits: credits,
            account: account
        )
    }

    private func credits(
        used: Int,
        cap: Int,
        isEnabled: Bool = true
    ) -> ProviderCredits {
        ProviderCredits(
            isEnabled: isEnabled,
            unit: .money(currency: "EUR", exponent: 2),
            usedMinor: used,
            capMinor: cap,
            observedAt: Date(timeIntervalSince1970: 1_789_303_000)
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
        XCTAssertEqual(snapshot.providers.first?.windows.map(\.label), ["Session", "Weekly"])
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

    // MARK: Pace

    /// The mark's whole job: a window that has spent less than the clock has
    /// is ahead, and the caption has to say so in the words the colour does.
    func testAWindowUnderEvenConsumptionReportsAReserve() throws {
        let row = try paceRow(minutes: 300, usedPercent: 20, elapsedFraction: 0.5)

        XCTAssertEqual(row.pace?.deltaPercent, -30)
        XCTAssertEqual(row.pace?.isOverPace, false)
        XCTAssertEqual(try XCTUnwrap(row.pace?.expectedFraction), 0.5, accuracy: 0.001)
    }

    func testAWindowOverEvenConsumptionReportsADeficit() throws {
        let row = try paceRow(minutes: 300, usedPercent: 80, elapsedFraction: 0.5)

        XCTAssertEqual(row.pace?.deltaPercent, 30)
        XCTAssertEqual(row.pace?.isOverPace, true)
    }

    /// The rate is one turn's tokens over a few minutes this early, which
    /// extrapolates to a week's spend before lunch. A mark that swings red on
    /// the first message is worse than no mark.
    func testAWindowInItsFirstMinutesCarriesNoPace() throws {
        let row = try paceRow(minutes: 10080, usedPercent: 1, elapsedFraction: 0.02)

        XCTAssertNil(row.pace)
    }

    /// Under pace means the rate outlives the window, so there is no run-out
    /// to name — and the row already prints the reset.
    func testAWindowThatOutlivesItsResetNamesNoRunOut() throws {
        let row = try paceRow(minutes: 300, usedPercent: 20, elapsedFraction: 0.5)

        XCTAssertNil(row.pace?.runsOutAt)
    }

    /// Half the window gone and 80% of it spent: the remaining 20% lasts a
    /// quarter of the time the first 80% took, which is 37.5 minutes of the
    /// 150 still on the clock.
    func testAWindowSpendingFasterThanItRefillsProjectsARunOut() throws {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let row = try paceRow(
            minutes: 300, usedPercent: 80, elapsedFraction: 0.5, now: now)

        let runsOut = try XCTUnwrap(row.pace?.runsOutAt)
        XCTAssertEqual(runsOut.timeIntervalSince(now), 37.5 * 60, accuracy: 1)
    }

    /// A window past 100% has no headroom left to project, and a reading in
    /// the past is not a projection the caption can count down to.
    func testAnExhaustedWindowRunsOutNow() throws {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let row = try paceRow(
            minutes: 300, usedPercent: 104, elapsedFraction: 0.5, now: now)

        XCTAssertEqual(row.pace?.runsOutAt, now)
    }

    /// A window whose reset has passed projects nothing: there is no elapsed
    /// time left in a period that has ended, and a mark drawn over it would
    /// place the reading inside a window it no longer measures.
    func testAWindowPastItsResetCarriesNoPace() throws {
        let row = try rolledOverRow()

        XCTAssertNil(row.pace)
    }

    /// The row survives the reset rather than vanishing with it. Codex answers
    /// only on its own turns, so dropping it took the session row off the page
    /// for as long as nobody used the CLI — with the weekly beside it still
    /// drawn, and its caption implying the block was current.
    func testAWindowPastItsResetKeepsItsRowAndSaysItRolledOver() throws {
        let row = try rolledOverRow()

        XCTAssertTrue(row.hasRolledOver)
        XCTAssertEqual(row.label, "Session")
    }

    /// The reading is withheld, not zeroed: the vendor has not answered for
    /// the new period, and a bar at zero would be Sissy answering for it.
    func testARolledOverWindowIsCaptionedRatherThanMeasured() throws {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let row = try rolledOverRow(now: now)

        let caption = try XCTUnwrap(UsageFormat.windowCaption(row, now: now))
        XCTAssertTrue(caption.hasPrefix("rolled over "), caption)
        XCTAssertTrue(caption.hasSuffix("awaiting a reading"), caption)
        XCTAssertFalse(caption.contains("resets"), caption)
    }

    /// A period that has ended is not the pressure anyone is under now, so it
    /// cannot take the emphasis on the page or the Overview's one gauge.
    func testARolledOverWindowNeverBinds() throws {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let rolled = try XCTUnwrap(
            UsageWindow(minutes: 300, usedPercent: 90, resetsAt: now.addingTimeInterval(-60)))
        let live = try XCTUnwrap(
            UsageWindow(minutes: 10_080, usedPercent: 12, resetsAt: now.addingTimeInterval(3600)))
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 1000, "1.00", windows: [rolled, live])]),
            now: now
        )
        let windows = try XCTUnwrap(snapshot.providers.first?.windows)

        XCTAssertEqual(UsagePanelSnapshot.binding(windows)?.minutes, 10_080)
    }

    /// Every window rolled over is no binding window at all, which is the dash
    /// the Overview already draws for a provider that has answered nothing —
    /// never the least stale of several dead readings.
    func testAllWindowsRolledOverLeaveNoBinding() throws {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let session = try XCTUnwrap(
            UsageWindow(minutes: 300, usedPercent: 90, resetsAt: now.addingTimeInterval(-60)))
        let weekly = try XCTUnwrap(
            UsageWindow(minutes: 10_080, usedPercent: 12, resetsAt: now.addingTimeInterval(-3600)))
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 1000, "1.00", windows: [session, weekly])]),
            now: now
        )
        let windows = try XCTUnwrap(snapshot.providers.first?.windows)

        XCTAssertEqual(windows.count, 2)
        XCTAssertNil(UsagePanelSnapshot.binding(windows))
    }

    private func rolledOverRow(
        now: Date = Date(timeIntervalSince1970: 1_789_000_000)
    ) throws -> UsagePanelSnapshot.WindowRow {
        let window = try XCTUnwrap(
            UsageWindow(
                minutes: 300, usedPercent: 50, resetsAt: now.addingTimeInterval(-60)))
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 1000, "1.00", windows: [window])]),
            now: now
        )
        return try XCTUnwrap(snapshot.providers.first?.windows.first)
    }

    private func paceRow(
        minutes: Int,
        usedPercent: Double,
        elapsedFraction: Double,
        now: Date = Date(timeIntervalSince1970: 1_789_000_000)
    ) throws -> UsagePanelSnapshot.WindowRow {
        let duration = Double(minutes) * 60
        let window = try XCTUnwrap(
            UsageWindow(
                minutes: minutes,
                usedPercent: usedPercent,
                resetsAt: now.addingTimeInterval(duration * (1 - elapsedFraction))
            ))
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 1000, "1.00", windows: [window])]),
            now: now
        )
        return try XCTUnwrap(snapshot.providers.first?.windows.first)
    }

    // MARK: Account

    func testTheAccountRowCarriesTheOrganisationUnderTheAddress() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [
                slice(
                    "claude-code", 1000, "1.00",
                    account: ProviderAccount(email: "someone@example.com", organization: "Radonforge"))
            ])
        )
        XCTAssertEqual(snapshot.providers.first?.account?.organization, "Radonforge")
    }

    /// The badge above the line already says the seat, so an account that
    /// answered for nothing else is a line with nothing on it.
    func testAnAccountCarryingOnlyASeatDrawsNoRow() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [
                slice("claude-code", 1000, "1.00", account: ProviderAccount(seat: "team_tier_1"))
            ])
        )
        XCTAssertNil(snapshot.providers.first?.account)
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

    /// Documentation and the view both promise "shortest first", and the view
    /// dims every row after the leading one. Codex publishes its buckets in
    /// `primary`/`secondary` order, which is not that order, so a weekly
    /// window could take the emphasis from the session one that binds first.
    func testWindowsAreDrawnShortestFirstWhateverOrderTheyArrivedIn() throws {
        let reset = Date().addingTimeInterval(3600)
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [
                slice(
                    "codex", 1000, "1.00",
                    windows: [
                        try XCTUnwrap(UsageWindow(minutes: 10_080, usedPercent: 20, resetsAt: reset)),
                        try XCTUnwrap(UsageWindow(minutes: 300, usedPercent: 10, resetsAt: reset)),
                    ])
            ]))

        XCTAssertEqual(snapshot.providers.first?.windows.map(\.id), ["300-", "10080-"])
    }

    // MARK: Totals

    func testTheHeadlineIsTheDaysTotalAcrossEveryProvider() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [
                slice("claude-code", 722_000_000, "478.20"),
                slice("codex", 14_300_000, "14.36"),
            ])
        )
        XCTAssertEqual(snapshot.tokens, "736.3M")
        XCTAssertEqual(snapshot.cost, "$492.56")
    }

    /// A day nothing has been spent on has no rate, and the headline says so
    /// by leaving the clause out rather than printing a pace of zero.
    func testADayWithNoSpendCarriesNoBurn() {
        XCTAssertNil(UsagePanelSnapshot.make(frame: frame(providers: [], burn: nil)).burn)
        XCTAssertEqual(
            UsagePanelSnapshot.make(frame: frame(providers: [], burn: 1500)).burn, "1.5K")
    }

    /// A provider that has spent nothing today keeps its row: the row is also
    /// where its plan, its account and its rate-limit gauges are drawn, and
    /// none of those stop existing because the day's total is zero. The recap
    /// above the rows is what counts the ones that were used.
    func testAnIdleProviderKeepsItsRowAndIsNotCountedAsUsed() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [
                slice("claude-code", 1000, "1.00"),
                slice("codex", 0, "0", plan: "plus"),
            ])
        )
        XCTAssertEqual(snapshot.providers.map(\.id), ["claude-code", "codex"])
        XCTAssertEqual(snapshot.providers.last?.plan, "Plus")
        XCTAssertEqual(snapshot.usedToday, 1)
    }

    // MARK: Credits

    /// The money halves are asserted on their wording rather than their digits:
    /// a currency formatter answers in the machine's locale, and a test that
    /// pinned "€58.95" would pass in one region and fail in the next.
    func testCreditsRowCarriesThePercentAndBothAmounts() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [
                slice("claude-code", 100, "1.00", credits: credits(used: 5895, cap: 10_000))
            ])
        )
        let row = try XCTUnwrap(snapshot.providers.first?.credits)
        XCTAssertEqual(row.percent, 59)
        XCTAssertEqual(try XCTUnwrap(row.fraction), 0.5895, accuracy: 0.0001)
        XCTAssertFalse(row.capReached)
        XCTAssertTrue(row.amount.contains(" of "), "the cap is missing from the headline")
    }

    /// A spend with no ceiling still answers what was spent, but nothing that
    /// would imply a ceiling: no percentage, no bar, no amount left.
    func testUncappedCreditsNameNoPercentAndNoCap() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("claude-code", 100, "1.00", credits: credits(used: 5895, cap: 0))])
        )
        let row = try XCTUnwrap(snapshot.providers.first?.credits)
        XCTAssertNil(row.percent)
        XCTAssertNil(row.fraction)
        XCTAssertFalse(row.amount.contains(" of "))
        XCTAssertFalse(row.caption.contains("left"))
    }

    /// Codex answers for what is left and for neither a spend nor a cap, so it
    /// fails every test written for the question Anthropic answers — and still
    /// has the figure someone opens this section for.
    func testABalanceOnlyReadingLeadsOnTheBalance() throws {
        let row = try XCTUnwrap(balanceRow(0))

        XCTAssertEqual(row.amount, "0 credits")
        XCTAssertNil(row.percent)
        XCTAssertNil(row.fraction)
        XCTAssertFalse(row.capReached)
    }

    /// A count is a quantity, not money: it keeps the decimals it has and
    /// prints none it does not, and it is never given a currency — `"0"` with a
    /// `$` in front of it is a figure Sissy made up.
    ///
    /// The fraction is asserted through the same formatter rather than as
    /// `"12.5"`, for the reason the money halves above are: a number formatter
    /// answers in the machine's locale, and this one writes `12,5`.
    func testACreditCountIsWordedAsAQuantity() throws {
        let half = Decimal(string: "12.5")!.formatted(.number.precision(.fractionLength(0...2)))
        XCTAssertEqual(try XCTUnwrap(balanceRow(1250)).amount, "\(half) credits")
        XCTAssertEqual(try XCTUnwrap(balanceRow(100)).amount, "1 credit")
        XCTAssertEqual(try XCTUnwrap(balanceRow(0)).amount, "0 credits")
    }

    /// The prepaid clause belongs beside a spend. With the balance already the
    /// headline it would print the same figure twice on one row.
    func testABalanceOnlyCaptionIsItsAgeAlone() throws {
        let row = try XCTUnwrap(balanceRow(0))

        XCTAssertFalse(row.caption.contains("prepaid"))
        XCTAssertFalse(row.caption.contains("left"))
    }

    /// No spend, no cap and no balance is a source that answered nothing, and
    /// a row of zeroes would be Sissy answering for it.
    func testAReadingThatNamesNoFigureGetsNoRow() {
        let empty = ProviderCredits(
            isEnabled: true, unit: .credits, usedMinor: nil, capMinor: nil,
            observedAt: Date(timeIntervalSince1970: 1_789_303_000))
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 100, "1.00", credits: empty)])
        )

        XCTAssertNil(snapshot.providers.first?.credits)
    }

    private func balanceRow(_ balanceMinor: Int) -> UsagePanelSnapshot.CreditsRow? {
        let credits = ProviderCredits(
            isEnabled: true, unit: .credits, usedMinor: nil, capMinor: nil,
            observedAt: Date(timeIntervalSince1970: 1_789_303_000), balanceMinor: balanceMinor)
        return UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 100, "1.00", credits: credits)])
        ).providers.first?.credits
    }

    func testCreditsAtTheCapSaySoInsteadOfNamingWhatIsLeft() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [
                slice("claude-code", 100, "1.00", credits: credits(used: 10_000, cap: 10_000))
            ])
        )
        let row = try XCTUnwrap(snapshot.providers.first?.credits)
        XCTAssertTrue(row.capReached)
        XCTAssertTrue(row.caption.hasPrefix("Cap reached"))
    }

    /// Which is every account that has never turned credits on, and a section
    /// that renders the same sentence forever is a row nobody reads.
    func testNoCreditsRowWhenNothingWasSpentAgainstNoCap() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("claude-code", 100, "1.00", credits: credits(used: 0, cap: 0))])
        )
        XCTAssertNil(snapshot.providers.first?.credits)
    }

    func testNoCreditsRowWhenTheVendorReportsTheFacilityOff() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [
                slice("claude-code", 100, "1.00", credits: credits(used: 5895, cap: 10_000, isEnabled: false))
            ])
        )
        XCTAssertNil(snapshot.providers.first?.credits)
    }

    // MARK: Provider rows

    func testRowsKeepTheWireOrderAndCarryDisplayNames() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("claude-code", 1, "1.00"), slice("codex", 1, "1.00")])
        )
        XCTAssertEqual(snapshot.providers.map(\.name), ["Claude", "Codex"])
    }

    // MARK: The headline's window

    /// The whole point of the control: the number under it is the archive's for
    /// the window selected, not the day's.
    func testTheHeadlineIsTheSelectedWindowsOwnTotal() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 10, "1.00")], history: archive()),
            period: .sevenDays,
            now: Self.now
        )

        XCTAssertEqual(snapshot.period, .sevenDays)
        XCTAssertEqual(snapshot.tokens, "2.5M")
        XCTAssertEqual(snapshot.cost, "$41.50")
    }

    /// Today is never rolled up from the archive: it is the live totals the
    /// frame already carries, which is what stops the number the panel is opened
    /// for from going slower than it was before the control existed.
    func testTodayIsTheLiveTotalAndNotTheArchivesCopyOfIt() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 10, "1.00")], history: archive()),
            period: .today,
            now: Self.now
        )

        XCTAssertEqual(snapshot.tokens, "10")
        XCTAssertEqual(snapshot.cost, "$1.00")
    }

    /// An average over thirty days is not a pace, so the slot it would take goes
    /// to how far back the archive actually reaches.
    func testThePaceIsOnTodayAloneAndCoverageTakesItsPlace() {
        let short = archive(earliestOffset: -2)
        let today = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 10, "1.00")], history: short),
            period: .today, now: Self.now)
        let week = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 10, "1.00")], history: short),
            period: .sevenDays, now: Self.now)

        XCTAssertNotNil(today.burn)
        XCTAssertNil(today.coverage)
        XCTAssertNil(week.burn)
        XCTAssertNotNil(week.coverage)
    }

    /// No archive, no control — and the headline stays on today rather than
    /// rendering a window nothing answers for.
    func testWithNoArchiveThereIsOnlyTodayAndNoControl() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(providers: [slice("codex", 10, "1.00")]),
            period: .thirtyDays,
            now: Self.now
        )

        XCTAssertEqual(snapshot.periods, [.today])
        XCTAssertEqual(snapshot.period, .today)
        XCTAssertEqual(snapshot.cost, "$1.00")
    }

    /// A preference outliving the archive it was set against falls back rather
    /// than rendering a blank, the same way a page pointed at a gone account does.
    func testAPeriodTheFrameCannotAnswerFallsBackToToday() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(
                providers: [slice("codex", 10, "1.00")],
                history: [.sevenDays: rollup(.sevenDays, earliestOffset: -6)]),
            period: .all,
            now: Self.now
        )

        XCTAssertEqual(snapshot.period, .today)
    }

    private static let now = Date()

    private func archive(earliestOffset: Int = -6) -> [UsagePeriod: UsageHistoryRollup] {
        Dictionary(
            uniqueKeysWithValues: UsagePeriod.archived.map {
                ($0, rollup($0, earliestOffset: earliestOffset))
            })
    }

    private func rollup(_ period: UsagePeriod, earliestOffset: Int) -> UsageHistoryRollup {
        UsageHistoryRollup(
            period: period,
            earliestDay: Calendar.current.date(
                byAdding: .day, value: earliestOffset,
                to: Calendar.current.startOfDay(for: Self.now)),
            tokens: 2_500_000,
            cost: Decimal(string: "41.5")!)
    }
}
