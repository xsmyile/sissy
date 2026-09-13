import XCTest

@testable import Sissy

final class UsageFormatTests: XCTestCase {
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
        XCTAssertEqual(UsageFormat.reading(age: 41, refreshing: false), "updated 41s ago")
    }

    /// The age goes away while a refresh is running rather than ticking on
    /// beside the word: it is about to be replaced, and a reading that says
    /// both is contradicting itself.
    func testReadingDropsTheAgeWhileRefreshing() {
        XCTAssertEqual(UsageFormat.reading(age: 41, refreshing: true), "refreshing…")
    }

    /// The status item's line names the hold and how long it has run, from
    /// the same stopwatch the panel prints, so the two cannot disagree about
    /// a duration the user can see in both places at once.
    func testTheMenuHoldLineNamesTheHoldAndItsDuration() {
        XCTAssertEqual(
            UsageFormat.keepAwakeHolding(900), "Keep awake — holding · " + UsageFormat.held(900))
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

    func testWindowLabelNamesTheSessionWindowInHours() {
        XCTAssertEqual(UsageFormat.windowLabel(minutes: 300), "5h")
    }

    func testWindowLabelNamesTheWeeklyWindowInDays() {
        XCTAssertEqual(UsageFormat.windowLabel(minutes: 10080), "7d")
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
        let notice = UsageFormat.limitsNotice(.needsAuthorization)
        XCTAssertEqual(notice?.action, "Allow")
    }

    func testARefusalOffersARetryRatherThanNothing() {
        XCTAssertEqual(UsageFormat.limitsNotice(.refused)?.action, "Try again")
    }

    func testACLIThatIsNotSignedInOffersNoControl() {
        let notice = UsageFormat.limitsNotice(.signedOut)
        XCTAssertNotNil(notice?.message)
        XCTAssertNil(notice?.action)
    }

    /// The common case, and the reason a row that is fine says nothing: one
    /// that explains itself every time is one nobody reads when it matters.
    func testWorkingLimitsSayNothing() {
        XCTAssertNil(UsageFormat.limitsNotice(.quiet))
    }

    // MARK: Account line

    /// The order and the separator are ours; the date's own rendering is
    /// Foundation's and depends on the reader's locale, so the assertion
    /// stops where our decision does.
    func testTheAccountLineJoinsTheOrganisationAndTheRenewal() throws {
        let line = try XCTUnwrap(
            UsageFormat.accountDetails(
                organization: "Radonforge",
                renewsAt: Date(timeIntervalSince1970: 1_792_000_000),
                now: Date(timeIntervalSince1970: 1_789_000_000)))

        XCTAssertTrue(line.hasPrefix("Radonforge · renews "), line)
        XCTAssertGreaterThan(line.count, "Radonforge · renews ".count)
    }

    func testTheOrganisationStandsAloneWhenNoRenewalIsKnown() {
        XCTAssertEqual(
            UsageFormat.accountDetails(organization: "Radonforge", renewsAt: nil), "Radonforge")
    }

    /// The claim is read off a file the CLI refreshes on its own schedule, so
    /// a date already past is the ordinary case rather than a fact — and
    /// "renews 3 Aug" printed in September answers nothing.
    func testARenewalAlreadyPastIsDropped() {
        XCTAssertNil(
            UsageFormat.accountDetails(
                organization: nil, renewsAt: Date(timeIntervalSince1970: 1_700_000_000),
                now: Date(timeIntervalSince1970: 1_789_000_000)))
    }

    func testAVendorThatAnswersForNeitherHalfCarriesNoLine() {
        XCTAssertNil(UsageFormat.accountDetails(organization: nil, renewsAt: nil))
    }

    // MARK: An empty limits block

    /// A reading that has not landed and a module nobody switched on look
    /// identical from the frame, and only one of them is something to do
    /// about — telling a user to flip a switch they already flipped sends
    /// them to a screen that disagrees with the sentence.
    func testAnEmptyLimitsBlockSendsYouToTheSwitchOnlyWhenItIsOff() {
        XCTAssertTrue(
            UsageFormat.noWindowsCaption(ProviderID.claudeCode, limitsEnabled: false)
                .contains("Settings"))
        XCTAssertFalse(
            UsageFormat.noWindowsCaption(ProviderID.claudeCode, limitsEnabled: true)
                .contains("Settings"))
    }

    /// Codex has no such switch, so its sentence does not move.
    func testCodexSaysItsLimitsArriveOnItsOwnTurns() {
        let off = UsageFormat.noWindowsCaption(ProviderID.codex, limitsEnabled: false)
        XCTAssertEqual(off, UsageFormat.noWindowsCaption(ProviderID.codex, limitsEnabled: true))
        XCTAssertTrue(off.contains("own turns"))
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

    func testResetLabelUsesAClockTimeLaterToday() throws {
        let clock = try fixedClock()
        let reset = try XCTUnwrap(clock.calendar.date(byAdding: .hour, value: 4, to: clock.now))
        XCTAssertEqual(
            UsageFormat.resetLabel(reset, now: clock.now, calendar: clock.calendar),
            reset.formatted(.dateTime.hour().minute())
        )
    }

    /// The window that exposed the 24-hour horizon: three hours out, but on
    /// tomorrow's page of the calendar, where a bare clock time reads as a
    /// time this morning that has already passed.
    func testResetLabelUsesAWeekdayOnceTheResetIsNotToday() throws {
        let clock = try fixedClock(hour: 22)
        let reset = try XCTUnwrap(clock.calendar.date(byAdding: .hour, value: 3, to: clock.now))
        XCTAssertEqual(
            UsageFormat.resetLabel(reset, now: clock.now, calendar: clock.calendar),
            reset.formatted(.dateTime.weekday(.abbreviated))
        )
    }

    func testResetLabelUsesAWeekdayDaysOut() throws {
        let clock = try fixedClock()
        let reset = try XCTUnwrap(clock.calendar.date(byAdding: .day, value: 3, to: clock.now))
        XCTAssertEqual(
            UsageFormat.resetLabel(reset, now: clock.now, calendar: clock.calendar),
            reset.formatted(.dateTime.weekday(.abbreviated))
        )
    }

    // MARK: Archive window

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
}
