import XCTest

@testable import Sissy

/// The profile fragment's parse, the windows cut out of it, and the comparison
/// that tells a profile hiding private work.
///
/// The fragment below keeps the shape of the real one, recorded 2026-10-13 off
/// `github.com/users/<login>/contributions`: a heading carrying the total, a
/// `<td>` per square naming its date and id, and a `<tool-tip>` per square
/// naming that id and carrying the count.
final class GitHubProfileCalendarTests: XCTestCase {
    private static func fragment(header: String = "1,235", days: [(String, String)]) -> String {
        let cells = days.enumerated().map { index, day in
            """
            <td tabindex="0" data-ix="\(index)" aria-selected="false" style="width: 10px" \
            data-date="\(day.0)" id="contribution-day-component-\(index)-0" data-level="1" \
            role="gridcell" data-view-component="true" class="ContributionCalendar-day"></td>
            """
        }
        let tips = days.enumerated().map { index, day in
            """
            <tool-tip style="pointer-events: none;" id="tooltip-\(index)" \
            for="contribution-day-component-\(index)-0" popover="manual" data-direction="n" \
            data-type="label" data-view-component="true" class="sr-only position-absolute">\(day.1)</tool-tip>
            """
        }
        return """
            <div class="js-yearly-contributions">
                <h2 tabindex="-1" id="js-contribution-activity-description" class="f4 text-normal mb-2">
                  \(header)
                  contributions
                    in the last year
                </h2>
            <table>\(cells.joined(separator: "\n"))</table>
            \(tips.joined(separator: "\n"))
            </div>
            """
    }

    private static let threeDays = [
        ("2026-10-11", "No contributions on October 11th."),
        ("2026-10-12", "1 contribution on October 12th."),
        ("2026-10-13", "1,234 contributions on October 13th."),
    ]

    func testParseReadsEverySquareAgainstTheHeading() throws {
        XCTAssertEqual(
            try GitHubProfileCalendar.parse(Self.fragment(days: Self.threeDays)),
            ["2026-10-11": 0, "2026-10-12": 1, "2026-10-13": 1234])
    }

    func testParseRefusesSquaresThatDoNotAddUpToTheHeading() {
        XCTAssertThrowsError(
            try GitHubProfileCalendar.parse(Self.fragment(header: "1,236", days: Self.threeDays)))
    }

    func testParseRefusesASquareWhoseCountWillNotRead() {
        var days = Self.threeDays
        days[1].1 = "Une contribution le 12 octobre."
        XCTAssertThrowsError(try GitHubProfileCalendar.parse(Self.fragment(header: "1,234", days: days)))
    }

    func testParseRefusesAFragmentWithNoHeading() {
        let html = Self.fragment(days: Self.threeDays).replacingOccurrences(
            of: "js-contribution-activity-description", with: "something-else")
        XCTAssertThrowsError(try GitHubProfileCalendar.parse(html))
    }

    func testParseRefusesAPageWithNoSquares() {
        XCTAssertThrowsError(try GitHubProfileCalendar.parse(Self.fragment(header: "0", days: [])))
    }

    func testAWindowWithADayTheProfileDidNotDrawHasNoTotal() {
        let squares = GitHubProfileCalendar.Squares(
            days: ["2026-10-12": 1, "2026-10-13": 4], lastYearFrom: "2026-10-12")
        XCTAssertEqual(squares.total(from: "2026-10-12", through: "2026-10-13"), 5)
        XCTAssertEqual(squares.total(from: "2026-10-13", through: "2026-10-13"), 4)
        XCTAssertNil(squares.total(from: "2026-10-11", through: "2026-10-13"))
    }

    /// Measured 2026-10-13: over the 365 days to yesterday the profile read
    /// 6 956 and the token's calendar 6 833, so the profile is the figure.
    func testAProfileCountingAtLeastTheTokensWorkIsTheFigure() {
        let squares = GitHubProfileCalendar.Squares(days: [:], lastYearFrom: "2025-10-12")
        XCTAssertEqual(
            GitHubProfileCalendar.decide(squares, profileCount: 6956, tokenCount: 6833), squares)
        XCTAssertEqual(GitHubProfileCalendar.decide(squares, profileCount: 0, tokenCount: 0), squares)
        XCTAssertNil(GitHubProfileCalendar.decide(squares, profileCount: 2368, tokenCount: 6833))
    }

    func testDayNamesCrossAYearAndALeapDay() {
        XCTAssertEqual(
            GitHubProfileCalendar.dayNames(from: "2027-12-31", through: "2028-01-01"),
            ["2027-12-31", "2028-01-01"])
        XCTAssertEqual(
            GitHubProfileCalendar.dayNames(from: "2028-02-28", through: "2028-03-01"),
            ["2028-02-28", "2028-02-29", "2028-03-01"])
        XCTAssertEqual(GitHubProfileCalendar.dayNames(from: "2026-10-13", through: "2026-10-12"), [])
    }

    func testAYearIsAskedForAsTheWholeCalendarYear() {
        XCTAssertEqual(
            GitHubProfileCalendar.url(login: "xsmyile")?.absoluteString,
            "https://github.com/users/xsmyile/contributions")
        XCTAssertEqual(
            GitHubProfileCalendar.url(login: "xsmyile", year: 2024)?.absoluteString,
            "https://github.com/users/xsmyile/contributions?from=2024-01-01&to=2024-12-31")
    }

    /// The comparison runs over the 365 local days ending yesterday, asked of
    /// the token's calendar the way every other window is.
    func testTheComparisonIsTheYearToYesterdayInLocalDates() throws {
        var rome = Calendar(identifier: .gregorian)
        rome.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Rome"))
        let lateNight = try XCTUnwrap(
            rome.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 0, minute: 30)))
        XCTAssertEqual(
            GitHubProfileCalendar.checkField(now: lateNight, calendar: rome),
            "profileCheck: contributionsCollection(from: \"2025-10-14T00:00:00Z\","
                + " to: \"2026-10-13T23:59:59Z\") { contributionCalendar { totalContributions } }")
        XCTAssertTrue(
            GitHubActivityFeed.document(now: lateNight, calendar: rome).contains(
                "profileCheck: contributionsCollection(from: \"2025-10-14T00:00:00Z\""))
        XCTAssertEqual(
            GitHubProfileCalendar.tokenCount([
                "profileCheck": ["contributionCalendar": ["totalContributions": 6833]]
            ]), 6833)
        XCTAssertNil(GitHubProfileCalendar.tokenCount([:]))
    }

    /// An Enterprise install keeps the token's calendar as its figure, so its
    /// document carries no comparison to make.
    func testAnEnterpriseDocumentAsksForNoComparison() {
        let now = Date(timeIntervalSince1970: 1_791_921_600)
        XCTAssertFalse(
            GitHubActivityFeed.document(now: now, profileCheck: false).contains(
                GitHubProfileCalendar.checkAlias))
        XCTAssertFalse(
            ForgeSpanFeed.githubDocument(
                from: now, to: now, now: now, counters: [], profileCheck: false
            ).contains(GitHubProfileCalendar.checkAlias))
    }
}
