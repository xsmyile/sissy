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
    /// negative age; the footer's job is to say the reading is live.
    func testAgeAheadOfTheClockReadsAsJustNow() {
        XCTAssertEqual(UsageFormat.age(-3), "just now")
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
}
