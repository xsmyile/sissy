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
}
