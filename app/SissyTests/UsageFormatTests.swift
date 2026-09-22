import XCTest

@testable import Sissy

final class UsageFormatTests: XCTestCase {
    func testATurnUnderAMinuteReadsInSeconds() {
        XCTAssertEqual(UsageFormat.turnDuration(milliseconds: 59_999), "59s")
    }

    func testALongTurnKeepsItsSeconds() {
        XCTAssertEqual(UsageFormat.turnDuration(milliseconds: 329_844), "5m 29s")
    }

    func testACacheShareReadsToATenthOfAPoint() {
        XCTAssertEqual(UsageFormat.cacheShare(0.9812), "98.1%")
    }

    /// One fresh token in a window must not print as a perfect cache.
    func testACacheShareShortOfWholeNeverReadsAsAHundred() {
        XCTAssertEqual(UsageFormat.cacheShare(0.99999), "99.9%")
    }

    func testAgeUnderFiveSecondsReadsAsJustNow() {
        XCTAssertEqual(UsageFormat.age(4), "just now")
    }

    func testAgeInSecondsRoundsToTheNearestSecond() {
        XCTAssertEqual(UsageFormat.age(41.4), "41s ago")
    }

    func testAgeCrossesToMinutesAtSixtySeconds() {
        XCTAssertEqual(UsageFormat.age(60), "1m ago")
    }

    func testAgeCrossesToHoursAtSixtyMinutes() {
        XCTAssertEqual(UsageFormat.age(3600), "1h ago")
    }

    func testAgeTruncatesTowardsTheUnitJustPassed() {
        XCTAssertEqual(UsageFormat.age(119), "1m ago")
    }

    /// A frame whose timestamp is ahead of this Mac's clock must not render a
    /// negative age; the line's job is to say the reading is live.
    func testAgeAheadOfTheClockReadsAsJustNow() {
        XCTAssertEqual(UsageFormat.age(-3), "just now")
    }

    func testReadingDatesTheReadingWhileNothingIsInFlight() {
        XCTAssertEqual(
            UsageFormat.reading(age: 41, holding: nil, refreshing: false), "updated 41s ago")
    }

    /// The hold trails the age so that a clause which comes and goes cannot
    /// shove the one that is always there: the line is left-aligned, and a
    /// leading hold moves "updated" sideways every time it appears or gains a
    /// unit.
    func testReadingTrailsTheHoldBehindTheAge() {
        XCTAssertEqual(
            UsageFormat.reading(age: 41, holding: 900, refreshing: false),
            "updated 41s ago · awake " + UsageFormat.held(900))
    }

    /// A refresh re-reads the provider, not the power assertion, so the hold
    /// stays put while the age goes.
    func testRefreshingKeepsTheHoldAndDropsOnlyTheAge() {
        XCTAssertEqual(
            UsageFormat.reading(age: 41, holding: 900, refreshing: true),
            "refreshing… · awake " + UsageFormat.held(900))
    }

    /// The age goes away while a refresh is running rather than ticking on
    /// beside the word: it is about to be replaced, and a reading that says
    /// both is contradicting itself.
    func testReadingDropsTheAgeWhileRefreshing() {
        XCTAssertEqual(
            UsageFormat.reading(age: 41, holding: nil, refreshing: true), "refreshing…")
    }

    /// The status item's line names the hold and how long it has run, from
    /// the same stopwatch the panel prints, so the two cannot disagree about
    /// a duration the user can see in both places at once.
    func testTheMenuHoldLineNamesTheHoldAndItsDuration() {
        XCTAssertEqual(
            UsageFormat.keepAwakeHolding(900), "Keep awake · holding " + UsageFormat.held(900))
    }

    func testProvidersRecapCountsTheDayAgainstWhatIsMetered() {
        XCTAssertEqual(UsageFormat.providersRecap(used: 1, metering: 2), "1 of 2 used today")
    }

    /// With one provider the recap restates the single row under it, which is
    /// a line that costs space and answers nothing.
    func testProvidersRecapStaysQuietForASingleProvider() {
        XCTAssertNil(UsageFormat.providersRecap(used: 1, metering: 1))
    }

    func testHeldUnderAMinuteSaysSoRatherThanCountingSeconds() {
        XCTAssertEqual(UsageFormat.held(59), "<1m")
    }

    func testHeldTruncatesToWholeMinutes() {
        XCTAssertEqual(UsageFormat.held(12 * 60 + 45), "12m")
    }

    func testHeldKeepsBothUnitsPastTheHour() {
        XCTAssertEqual(UsageFormat.held(3600 + 12 * 60), "1h 12m")
    }

    func testHeldDropsAnEmptyMinutePart() {
        XCTAssertEqual(UsageFormat.held(3 * 3600), "3h")
    }

    /// A hold stamped a moment ahead of this Mac's clock must not count
    /// backwards — the control is reporting a Mac that is being held now.
    func testHeldAheadOfTheClockStaysBelowAMinute() {
        XCTAssertEqual(UsageFormat.held(-30), "<1m")
    }

    func testCountdownKeepsBothUnitsAcrossDays() {
        XCTAssertEqual(UsageFormat.countdown(2 * 86400 + 15 * 3600), "2d 15h")
    }

    func testCountdownDropsAnEmptyHourPart() {
        XCTAssertEqual(UsageFormat.countdown(3 * 86400), "3d")
    }

    func testCountdownFallsBackToHoursAndMinutes() {
        XCTAssertEqual(UsageFormat.countdown(16 * 3600 + 31 * 60), "16h 31m")
    }

    func testCountdownUnderAnHourIsMinutesAlone() {
        XCTAssertEqual(UsageFormat.countdown(48 * 60), "48m")
    }

    func testTheUsedReadingPrintsTheVendorsOwnFigure() {
        XCTAssertEqual(UsageFormat.windowPercent(86, as: .used), "86%")
    }

    func testTheLeftReadingSubtractsTheVendorsFigureFromTheWindow() {
        XCTAssertEqual(UsageFormat.windowPercent(86, as: .left), "14%")
    }

    /// A vendor can report past its own ceiling. Read from the spent end that
    /// overshoot is the honest figure; read from the other end it would be a
    /// negative headroom, which is not a quantity anyone is owed.
    func testAWindowPastItsCeilingKeepsTheOvershootAndFloorsTheHeadroom() {
        XCTAssertEqual(UsageFormat.windowPercent(105, as: .used), "105%")
        XCTAssertEqual(UsageFormat.windowPercent(105, as: .left), "0%")
    }

    /// The row prints the bare figure because the bar beside it names the
    /// axis; the tooltip has room for the word and no bar.
    func testTheTooltipReadingCarriesTheWordTheRowLeavesToTheBar() {
        XCTAssertEqual(UsageFormat.windowReading(86, as: .used), "86% used")
        XCTAssertEqual(UsageFormat.windowReading(86, as: .left), "14% left")
    }

    func testPaceCaptionWordsAReserveThatLastsUntilTheReset() {
        XCTAssertEqual(
            UsageFormat.paceCaption(deltaPercent: -30, runsOutAt: nil),
            "30% in reserve · Lasts until reset"
        )
    }

    func testPaceCaptionWordsADeficitWithItsRunOut() {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        XCTAssertEqual(
            UsageFormat.paceCaption(
                deltaPercent: 28,
                runsOutAt: now.addingTimeInterval(86400 + 48 * 60),
                now: now
            ),
            "28% in deficit · Runs out in 1d"
        )
    }

    /// "0% in reserve" is a measurement of nothing; the caption has a word for
    /// sitting on the mark.
    func testPaceCaptionOnTheMarkSaysSoRatherThanZero() {
        XCTAssertEqual(
            UsageFormat.paceCaption(deltaPercent: 0, runsOutAt: nil),
            "On pace · Lasts until reset"
        )
    }

    /// A run-out already behind us cannot be counted down to.
    func testPaceCaptionPastTheRunOutSaysTheHeadroomIsGone() {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        XCTAssertEqual(
            UsageFormat.paceCaption(deltaPercent: 54, runsOutAt: now, now: now),
            "54% in deficit · Out of headroom"
        )
    }

    /// The row leads with the label now, so the two periods both vendors
    /// meter get the word they are known by rather than their length.
    func testWindowLabelNamesTheSessionWindow() {
        XCTAssertEqual(UsageFormat.windowLabel(minutes: 300), "Session")
    }

    func testWindowLabelNamesTheWeeklyWindow() {
        XCTAssertEqual(UsageFormat.windowLabel(minutes: 10080), "Weekly")
    }

    /// A window that meters one model says which, so two weekly windows do
    /// not read as one.
    func testWindowLabelCarriesTheScope() {
        XCTAssertEqual(
            UsageFormat.windowLabel(minutes: 10080, scope: "Fable"), "Weekly · Fable")
    }

    func testWindowLabelFallsBackToMinutesForAnUnevenWindow() {
        XCTAssertEqual(UsageFormat.windowLabel(minutes: 90), "90m")
    }

    /// The seat is what turns a plan nobody distinguishes into the one the
    /// account actually pays for.
    func testAKnownTeamSeatWordsTheBadge() {
        XCTAssertEqual(
            UsageFormat.plan("team", tier: "max_5x", seat: "team_tier_1")?.label, "Team Premium")
        XCTAssertEqual(
            UsageFormat.plan("team", tier: nil, seat: "team_standard")?.label, "Team Standard")
    }

    /// The property that makes the seat map safe to keep where every other
    /// vendor token here is derived: an unknown seat costs a word, never a
    /// wrong one, and never a release.
    func testASeatThisBuildDoesNotKnowLeavesThePlanAlone() {
        XCTAssertEqual(UsageFormat.plan("team", tier: nil, seat: "team_tier_9")?.label, "Team")
    }

    func testASeatCannotRenameAPlanItDoesNotBelongTo() {
        XCTAssertEqual(UsageFormat.plan("pro", tier: nil, seat: "team_tier_1")?.label, "Pro")
    }

    /// The seat replaces the label and nothing else: a Team seat metered at
    /// Max 5x still says so where it said so before.
    func testTheTierSurvivesAWordedSeat() {
        XCTAssertEqual(
            UsageFormat.plan("team", tier: "max_5x", seat: "team_tier_1")?.tier, "Max 5x")
    }

    /// Every notice names what to do. The one state Sissy cannot fix offers
    /// no control rather than a button that would do nothing.
    func testALapsedGrantOffersTheOneClickThatRecoversIt() {
        let notice = UsageFormat.limitsNotice(.needsAuthorization, provider: ProviderID.claudeCode)
        XCTAssertEqual(notice?.action, "Allow")
    }

    func testARefusalOffersARetryRatherThanNothing() {
        XCTAssertEqual(
            UsageFormat.limitsNotice(.refused, provider: ProviderID.claudeCode)?.action, "Try again")
    }

    func testACLIThatIsNotSignedInOffersNoControl() {
        let notice = UsageFormat.limitsNotice(.signedOut, provider: ProviderID.claudeCode)
        XCTAssertNotNil(notice?.message)
        XCTAssertNil(notice?.action)
    }

    /// The common case, and the reason a row that is fine says nothing: one
    /// that explains itself every time is one nobody reads when it matters.
    func testWorkingLimitsSayNothing() {
        XCTAssertNil(UsageFormat.limitsNotice(.quiet, provider: ProviderID.claudeCode))
    }

    /// Every sentence in a notice names something — the CLI that is signed
    /// out, the vendor that is refusing, the sign-in that has ended — so a row
    /// saying another vendor's words sends somebody to fix the wrong thing.
    func testANoticeIsWordedForTheProviderItIsOn() throws {
        let signedOut = try XCTUnwrap(
            UsageFormat.limitsNotice(.signedOut, provider: ProviderID.codex))
        XCTAssertTrue(signedOut.message.contains("Codex"), signedOut.message)
        XCTAssertFalse(signedOut.message.contains("Claude"), signedOut.message)

        let expired = try XCTUnwrap(
            UsageFormat.limitsNotice(.sessionExpired, provider: ProviderID.codex))
        XCTAssertTrue(expired.message.contains("OpenAI"), expired.message)
        XCTAssertEqual(expired.kind, .link)

        let blocked = try XCTUnwrap(
            UsageFormat.limitsNotice(
                .rateLimited(until: Date(timeIntervalSince1970: 0)), provider: ProviderID.codex))
        XCTAssertTrue(blocked.message.hasPrefix("OpenAI"), blocked.message)
    }

    // MARK: An empty limits block

    /// Nothing to switch on any more, so an empty block is a reading that has
    /// not landed — and must not send anyone to a screen looking for a control
    /// that is not there.
    func testAnEmptyLimitsBlockNoLongerSendsYouToSettings() {
        let caption = UsageFormat.noWindowsCaption(ProviderID.claudeCode)
        XCTAssertFalse(caption.contains("Settings"))
        XCTAssertTrue(caption.contains("Waiting"))
    }

    func testCodexSaysItsLimitsArriveOnItsOwnTurns() {
        XCTAssertTrue(UsageFormat.noWindowsCaption(ProviderID.codex).contains("own turns"))
    }

    // MARK: Refresh

    /// The button must say which of the two actions it is before it is
    /// pressed: one of them raises a system permission dialog.
    func testRefreshWarnsThatClaudeMayAskForTheKeychain() {
        XCTAssertTrue(UsageFormat.refreshHelp(ProviderID.claudeCode).contains("keychain"))
    }

    /// No button can make a Codex limit arrive — they ride the CLI's own
    /// turns — so the tooltip promises the account and nothing more.
    func testRefreshOnCodexDoesNotPromiseFreshLimits() {
        let help = UsageFormat.refreshHelp(ProviderID.codex)
        XCTAssertTrue(help.contains("next Codex turn"))
        XCTAssertFalse(help.contains("keychain"))
    }

    func testPlanLabelCapitalisesAVendorToken() {
        XCTAssertEqual(UsageFormat.plan("plus", tier: nil)?.label, "Plus")
        XCTAssertEqual(UsageFormat.plan("max", tier: nil)?.label, "Max")
    }

    /// Derived rather than mapped, so a tier that ships after this release
    /// still reads as words instead of disappearing from the row.
    func testPlanLabelSpacesASnakeCaseTier() {
        XCTAssertEqual(UsageFormat.plan("edu_plus", tier: nil)?.label, "Edu Plus")
    }

    func testPlanLabelOfNoPlanIsNoLabel() {
        XCTAssertNil(UsageFormat.plan(nil, tier: nil))
    }

    func testPlanFoldsTheMultiplierWhenTheTierNamesItsOwnPlan() {
        let plan = UsageFormat.plan("max", tier: "max_20x")
        XCTAssertEqual(plan?.label, "Max 20x")
        XCTAssertNil(plan?.tier)
    }

    /// "Team 5x" is a plan nobody sells, so the seat keeps its own badge and
    /// the tier it is metered at becomes the tooltip.
    func testPlanKeepsTheTierApartWhenItNamesAnotherPlan() {
        let plan = UsageFormat.plan("team", tier: "max_5x")
        XCTAssertEqual(plan?.label, "Team")
        XCTAssertEqual(plan?.tier, "Max 5x")
    }

    func testPlanIgnoresATierThatOnlyRepeatsThePlan() {
        let plan = UsageFormat.plan("pro", tier: "pro")
        XCTAssertEqual(plan?.label, "Pro")
        XCTAssertNil(plan?.tier)
    }

    /// The multiplier is recognised by shape, so a suffix that is not one
    /// stays part of the tier's name rather than being read as "10 times".
    func testPlanTreatsANonMultiplierSuffixAsPartOfTheTier() {
        let plan = UsageFormat.plan("team", tier: "business_edu")
        XCTAssertEqual(plan?.label, "Team")
        XCTAssertEqual(plan?.tier, "Business Edu")
    }

    func testResetLabelCountsDownRatherThanNamingTheHour() throws {
        let clock = try fixedClock()
        let reset = try XCTUnwrap(clock.calendar.date(byAdding: .minute, value: 267, to: clock.now))

        XCTAssertEqual(UsageFormat.resetLabel(reset, now: clock.now), "in 4h 27m")
    }

    /// The window this was changed for: 2h 27m from its reset, on tomorrow's
    /// page of the calendar, where the weekday it used to print was the same
    /// two words a window six days out would get — a five-hour period read as
    /// a daily one. Measured 2026-09-18 at 23:52 on both providers at once.
    func testResetLabelSaysHowLongEvenAcrossMidnight() throws {
        let clock = try fixedClock(hour: 23)
        let reset = try XCTUnwrap(clock.calendar.date(byAdding: .minute, value: 147, to: clock.now))

        XCTAssertEqual(UsageFormat.resetLabel(reset, now: clock.now), "in 2h 27m")
    }

    /// The notice's deadline is worded "until", which takes a moment rather
    /// than a duration. The two were once the same call, and it read a
    /// deadline in whole days — measured, a 1800 s block beginning at 23:50
    /// said "until Fri", the same half-hour described as two days.
    func testARateLimitNoticeNamesATimeRatherThanADay() throws {
        let clock = try fixedClock(hour: 23)
        let until = try XCTUnwrap(
            clock.calendar.date(byAdding: .minute, value: 70, to: clock.now))

        let notice = try XCTUnwrap(
            UsageFormat.limitsNotice(.rateLimited(until: until), provider: ProviderID.claudeCode))

        XCTAssertEqual(
            notice.message,
            "Anthropic is not answering for limits until "
                + until.formatted(.dateTime.hour().minute())
        )
    }

    /// A weekly window answers in the same unit as the pace beside it, which
    /// is what lets "Runs out in 1d 9h · resets in 5d 14h" be read as one
    /// comparison instead of a duration and a date.
    func testResetLabelSpeaksTheSameUnitAsThePaceDaysOut() throws {
        let clock = try fixedClock()
        let reset = try XCTUnwrap(clock.calendar.date(byAdding: .minute, value: 8040, to: clock.now))

        XCTAssertEqual(UsageFormat.resetLabel(reset, now: clock.now), "in 5d 14h")
    }

    /// The caption is re-read on its own clock while `hasRolledOver` is frozen
    /// at the snapshot, so this is the only half that can notice the crossing.
    /// "in 0m" there would be the formatter saying a period is about to turn
    /// over when it already has, on a row that has stopped drawing its bar.
    func testResetLabelSaysNothingOnceTheResetIsPast() throws {
        let clock = try fixedClock()
        let reset = try XCTUnwrap(clock.calendar.date(byAdding: .second, value: -1, to: clock.now))

        XCTAssertNil(UsageFormat.resetLabel(reset, now: clock.now))
    }

    // MARK: Archive window

    /// The control beside the number already names the period, so a window the
    /// archive covers has nothing left to admit.
    func testAWindowTheArchiveReachesBackAcrossSaysNothing() throws {
        let clock = try fixedClock()
        let earliest = try XCTUnwrap(
            clock.calendar.date(byAdding: .day, value: -6, to: clock.now))
        XCTAssertNil(
            UsageFormat.periodCoverage(
                rollup(.sevenDays, earliest: earliest),
                now: clock.now, calendar: clock.calendar))
    }

    /// Three days of data under a "7 days" label is a daily average a reader
    /// computes wrong and cannot tell they did.
    func testAWindowTheArchiveFallsShortOfNamesItsFirstDay() throws {
        let clock = try fixedClock()
        let earliest = try XCTUnwrap(
            clock.calendar.date(byAdding: .day, value: -2, to: clock.now))
        XCTAssertEqual(
            UsageFormat.periodCoverage(
                rollup(.sevenDays, earliest: earliest),
                now: clock.now, calendar: clock.calendar),
            "since \(earliest.formatted(.dateTime.day().month(.abbreviated)))"
        )
    }

    /// `all` has no width to fall short of, so it always names its first day —
    /// without which the widest window is the one reading on the panel that
    /// never says what it covers.
    func testTheWidestWindowAlwaysNamesItsFirstDay() throws {
        let clock = try fixedClock()
        let earliest = try XCTUnwrap(
            clock.calendar.date(byAdding: .day, value: -400, to: clock.now))
        XCTAssertEqual(
            UsageFormat.periodCoverage(
                rollup(.all, earliest: earliest),
                now: clock.now, calendar: clock.calendar),
            "since \(earliest.formatted(.dateTime.day().month(.abbreviated)))"
        )
    }

    /// A window holding none of the archive's days has no first day to name,
    /// and the zero under it is a reading rather than a short one.
    func testAWindowHoldingNoDaysAdmitsNothing() throws {
        let clock = try fixedClock()
        XCTAssertNil(
            UsageFormat.periodCoverage(
                rollup(.sevenDays, earliest: nil),
                now: clock.now, calendar: clock.calendar))
    }

    /// The strip names its window whatever the archive holds, because nothing
    /// else on that surface says which days the bars are. Restored with the
    /// function: this branch deleted both while the headline was the only
    /// caller, and the day strip on `master` still needs the width said.
    func testAWindowTheArchiveReachesBackAcrossIsNamedByItsWidth() throws {
        let clock = try fixedClock()
        let earliest = try XCTUnwrap(
            clock.calendar.date(byAdding: .day, value: -6, to: clock.now))
        XCTAssertEqual(
            UsageFormat.historyWindowLabel(
                days: 7, earliestDay: earliest, now: clock.now, calendar: clock.calendar),
            "Last 7 days"
        )
    }

    /// Three days of data under a "Last 7 days" label is a daily average a
    /// reader computes wrong and cannot tell they did.
    func testAWindowTheArchiveFallsShortOfIsNamedByItsFirstDay() throws {
        let clock = try fixedClock()
        let earliest = try XCTUnwrap(
            clock.calendar.date(byAdding: .day, value: -2, to: clock.now))
        XCTAssertEqual(
            UsageFormat.historyWindowLabel(
                days: 7, earliestDay: earliest, now: clock.now, calendar: clock.calendar),
            "Since \(earliest.formatted(.dateTime.day().month(.abbreviated)))"
        )
    }

    /// An archive that holds nothing has no first day to name, so the window
    /// keeps its own width rather than printing a label with a hole in it.
    func testAWindowWithNoArchiveBehindItKeepsItsWidth() throws {
        let clock = try fixedClock()
        XCTAssertEqual(
            UsageFormat.historyWindowLabel(
                days: 7, earliestDay: nil, now: clock.now, calendar: clock.calendar),
            "Last 7 days"
        )
    }

    /// The two labels sit on one piece of arithmetic, so a window one of them
    /// calls short must never be whole to the other.
    func testBothLabelsAgreeOnWhetherAWindowIsShort() throws {
        let clock = try fixedClock()
        for offset in [-1, -6, -7, -30] {
            let earliest = try XCTUnwrap(
                clock.calendar.date(byAdding: .day, value: offset, to: clock.now))
            let named = UsageFormat.historyWindowLabel(
                days: 7, earliestDay: earliest, now: clock.now, calendar: clock.calendar)
            let admitted = UsageFormat.periodCoverage(
                rollup(.sevenDays, earliest: earliest),
                now: clock.now, calendar: clock.calendar)
            XCTAssertEqual(
                named.hasPrefix("Since"), admitted != nil,
                "the labels disagreed about a window starting \(offset) days back")
        }
    }

    private func rollup(_ period: UsagePeriod, earliest: Date?) -> UsageHistoryRollup {
        UsageHistoryRollup(period: period, earliestDay: earliest, tokens: 1, cost: 1)
    }

    /// A fixed instant in a fixed zone: "same calendar day" is a question the
    /// answer to which depends on both, so neither can come from the machine
    /// running the test.
    private func fixedClock(hour: Int = 10) throws -> (now: Date, calendar: Calendar) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: hour))
        )
        return (now, calendar)
    }

    // MARK: Keep awake

    /// Three surfaces list the modes from this one function — the panel
    /// button's menu, the status item's menu and Settings. That a mode is
    /// named at all is the compiler's job, since `keepAwakeTitle` switches
    /// exhaustively; what it cannot catch is two modes answering the same
    /// words, which renders a radio group nobody can choose from.
    func testNoTwoKeepAwakeModesShareAName() {
        let titles = KeepAwakeMode.allCases.map(UsageFormat.keepAwakeTitle)

        XCTAssertEqual(Set(titles).count, titles.count)
    }

    func testNoKeepAwakeModeIsNamedWithNothing() {
        XCTAssertFalse(KeepAwakeMode.allCases.map(UsageFormat.keepAwakeTitle).contains(where: \.isEmpty))
    }

    /// The button is a two-position switch over three modes, so the tooltip is
    /// the only thing that says which of the two armed ones a click is about
    /// to take — and that is the difference between a hold bounded by ten
    /// minutes of silence and one that runs for eight hours.
    func testTheOffTooltipNamesTheModeAClickWouldArm() {
        let automatic = UsageFormat.keepAwakeHelp(.off, arming: .auto)
        let always = UsageFormat.keepAwakeHelp(.off, arming: .on)

        XCTAssertTrue(automatic.contains(UsageFormat.keepAwakeTitle(.auto).lowercased()))
        XCTAssertTrue(always.contains(UsageFormat.keepAwakeTitle(.on).lowercased()))
        XCTAssertNotEqual(automatic, always)
    }

    /// The modes hang off a button with no chevron, so the tooltip is the
    /// affordance. A state that forgets to mention the gesture is a state
    /// where the choice is invisible again, which is the whole complaint the
    /// menu on the button answers.
    func testEveryKeepAwakeStateSaysWhereTheOtherModesAre() {
        let states = [
            KeepAwakeState.off,
            KeepAwakeState(mode: .on, active: true, since: Date(), coversScreen: true),
            KeepAwakeState(mode: .auto, active: true, since: Date()),
            KeepAwakeState(mode: .auto, active: false),
            KeepAwakeState(mode: .on, active: false),
        ]

        for state in states {
            XCTAssertTrue(
                UsageFormat.keepAwakeHelp(state, arming: .on).contains("right-click"),
                "\(state.mode)/\(state.active) points nowhere for the other modes")
        }
    }

    /// Every wording that claims the Mac stays up has to name the lid: closing
    /// a MacBook sleeps it under all three modes, and someone who finds that
    /// out from a lost overnight run blames Sissy for it.
    func testEveryKeepAwakeTooltipNamesTheLid() {
        let states = [
            KeepAwakeState.off,
            KeepAwakeState(mode: .on, active: true, since: Date()),
            KeepAwakeState(mode: .auto, active: true, since: Date(), coversScreen: true),
            KeepAwakeState(mode: .auto, active: false),
        ]

        for state in states {
            XCTAssertTrue(
                UsageFormat.keepAwakeHelp(state, arming: .on).contains("lid"),
                "\(state.mode)/\(state.active) promises a Mac that stays up without naming the lid")
        }
    }

    /// The switch reaches Claude Code's own credential, so the confirmation
    /// has to name the account rather than ask an abstract question.
    func testTheSwitchConfirmationNamesTheAccount() {
        XCTAssertEqual(
            ClaudeAccountSwitchCopy.confirmTitle("Radon Forge"),
            "Switch Claude Code to Radon Forge?")
        XCTAssertEqual(
            ClaudeAccountSwitchCopy.switching("Radon Forge"), "Switching to Radon Forge…")
    }

    /// Measured 2026-09-16: a `claude` that is already running rewrites the
    /// credential on its next token refresh and puts its own account back, so
    /// a switch made under an open session silently reverts within minutes.
    /// Sissy cannot prevent it — the slot belongs to the CLI — so the warning
    /// is the whole mitigation and it must not quietly go missing.
    func testTheSwitchConfirmationWarnsAboutAnOpenSession() {
        let body = ClaudeAccountSwitchCopy.confirmBody

        XCTAssertTrue(body.contains("already open"))
        XCTAssertTrue(body.contains("quit it first"))
    }
}
