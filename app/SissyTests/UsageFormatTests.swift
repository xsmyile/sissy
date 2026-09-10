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
    /// negative age; the footer's job is to say the daemon is alive.
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
