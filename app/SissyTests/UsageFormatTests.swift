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

    func testWindowLabelNamesTheSessionWindowInHours() {
        XCTAssertEqual(UsageFormat.windowLabel(minutes: 300), "5h")
    }

    func testWindowLabelNamesTheWeeklyWindowInDays() {
        XCTAssertEqual(UsageFormat.windowLabel(minutes: 10080), "7d")
    }

    func testWindowLabelFallsBackToMinutesForAnUnevenWindow() {
        XCTAssertEqual(UsageFormat.windowLabel(minutes: 90), "90m")
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
