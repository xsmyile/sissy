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

    func testWindowLabelNamesTheSessionWindowInHours() {
        XCTAssertEqual(UsageFormat.windowLabel(minutes: 300), "5h")
    }

    func testWindowLabelNamesTheWeeklyWindowInDays() {
        XCTAssertEqual(UsageFormat.windowLabel(minutes: 10080), "7d")
    }

    func testWindowLabelFallsBackToMinutesForAnUnevenWindow() {
        XCTAssertEqual(UsageFormat.windowLabel(minutes: 90), "90m")
    }

    func testResetLabelUsesAClockTimeWithinADay() {
        let now = Date()
        let soon = now.addingTimeInterval(3600)
        XCTAssertEqual(
            UsageFormat.resetLabel(soon, now: now),
            soon.formatted(.dateTime.hour().minute())
        )
    }

    func testResetLabelUsesAWeekdayBeyondADay() {
        let now = Date()
        let later = now.addingTimeInterval(3 * 86400)
        XCTAssertEqual(
            UsageFormat.resetLabel(later, now: now),
            later.formatted(.dateTime.weekday(.abbreviated))
        )
    }
}
