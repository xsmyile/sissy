import XCTest

@testable import Sissy

/// The forge readers, the poll around them, and the row they become.
///
/// The two payloads below are the real replies, recorded 2026-09-17 from the
/// documents this build generates — not hand-written approximations of them.
/// Both were sent to the live APIs and answered; what is pinned here is that
/// the parser reads back what they carry and that the generator keeps producing
/// the query shape they answered.
final class ForgeActivityTests: XCTestCase {
    /// Local noon on the day everything here was measured, so the window
    /// arithmetic is exercised against the dates the live queries used.
    private static let measuredDay: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 17
        components.hour = 12
        return Calendar.current.date(from: components)!
    }()

    private static let gitHubReply = """
        {"data":{"viewer":{"login":"xsmyile",
        "contribToday":{"contributionCalendar":{"totalContributions":314}},
        "contribWeek":{"contributionCalendar":{"totalContributions":761}},
        "contribMonth":{"contributionCalendar":{"totalContributions":997}},
        "contribAll":{"contributionCalendar":{"totalContributions":4126}}},
        "mergedToday":{"issueCount":25},"mergedWeek":{"issueCount":152},
        "mergedMonth":{"issueCount":205},"mergedAll":{"issueCount":400}}}
        """

    private static let gitLabReply = """
        {"data":{"currentUser":{"username":"team-user",
        "mergedToday":{"count":11},"mergedWeek":{"count":87},
        "mergedMonth":{"count":129},"mergedAll":{"count":519}}}}
        """

    private static let gitHub = ForgeConnection.gitHub()
    private static let gitLab = ForgeConnection(kind: .gitLab, host: "gitlab.example.com")

    private func payload(_ json: String) throws -> [String: Any] {
        let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return try XCTUnwrap(root?["data"] as? [String: Any])
    }

    // MARK: The windows

    /// The forge rows sit under the money and follow the same control, so they
    /// have to count the same days: `days - 1` before the start of today,
    /// inclusive, and `all` unbounded. Any drift here puts two answers under
    /// one label.
    func testWindowStartsMatchTheArchivesOwnConvention() {
        let day = Self.measuredDay
        let calendar = Calendar.current
        XCTAssertEqual(
            ForgeWindow.start(of: .today, now: day), calendar.startOfDay(for: day))
        XCTAssertEqual(
            ForgeWindow.start(of: .sevenDays, now: day),
            calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: day)))
        XCTAssertEqual(
            ForgeWindow.start(of: .thirtyDays, now: day),
            calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: day)))
        XCTAssertNil(ForgeWindow.start(of: .all, now: day))
    }

    /// GitLab's `after` names a calendar day, so it is rendered in the calendar
    /// the start was computed in. Rendering it in UTC put every window a day
    /// early east of Greenwich — the start of 2026-09-17 came out `2026-09-16`,
    /// a day more than the figure above it is over.
    func testTheDayFilterRendersTheLocalDayRatherThanTheUTCInstant() throws {
        let start = try XCTUnwrap(ForgeWindow.start(of: .today, now: Self.measuredDay))
        XCTAssertEqual(ForgeWindow.day.string(from: start), "2026-09-17")
    }

    /// GitHub reads a bare date as midnight **UTC**, so the merge qualifier
    /// carries this Mac's own offset. Measured 2026-09-17 from Europe/Rome: the
    /// same window asked from 14:00+02:00 answered 11 where 14:00+00:00
    /// answered 6, so the offset is honoured and dropping it silently moves the
    /// boundary — east of Greenwich the first hours of the local day fall out of
    /// Today while the contributions figure beside them keeps them.
    func testTheMergeQualifierCarriesTheLocalOffsetRatherThanABareDate() throws {
        let start = try XCTUnwrap(ForgeWindow.start(of: .today, now: Self.measuredDay))
        let rendered = ForgeWindow.timestamp.string(from: start)
        XCTAssertTrue(rendered.hasPrefix("2026-09-17T00:00:00"), rendered)
        XCTAssertEqual(ForgeWindow.timestamp.date(from: rendered), start)
        XCTAssertFalse(GitHubActivityFeed.document(now: Self.measuredDay).contains("merged:>=2026-09-17 "))
    }

    // MARK: GitHub

    func testGitHubReplyReadsBackEveryFigureAndTheAccountThatAnswered() throws {
        let reading = try GitHubActivityFeed.parse(
            payload(Self.gitHubReply), connection: Self.gitHub, now: Self.measuredDay)
        XCTAssertEqual(reading.login, "xsmyile")
        XCTAssertEqual(reading.contributions(for: .today), 314)
        XCTAssertEqual(reading.contributions(for: .sevenDays), 761)
        XCTAssertEqual(reading.contributions(for: .thirtyDays), 997)
        XCTAssertEqual(reading.contributions(for: .all), 4126)
        XCTAssertEqual(reading.merged(for: .today), 25)
        XCTAssertEqual(reading.merged(for: .all), 400)
        XCTAssertNil(reading.failure)
    }

    /// GitHub's contributions query refuses a range wider than a year, so its
    /// widest figure is twelve months where the merge count beside it is every
    /// one ever. The row has to be able to say so.
    func testGitHubMarksItsWidestContributionWindowAsBoundedToAYear() throws {
        let reading = try GitHubActivityFeed.parse(
            payload(Self.gitHubReply), connection: Self.gitHub, now: Self.measuredDay)
        XCTAssertTrue(reading.activity.contributionsBoundedToOneYear)
    }

    /// A reply that named the account and no figure at all is a shape this
    /// build does not understand. Reading it as a quiet day would report zero
    /// contributions on a Mac that simply cannot parse the answer.
    func testGitHubReplyWithNoFiguresIsMalformedRatherThanAQuietDay() throws {
        let bare = try payload(
            """
            {"data":{"viewer":{"login":"xsmyile"}}}
            """)
        XCTAssertThrowsError(
            try GitHubActivityFeed.parse(bare, connection: Self.gitHub, now: Self.measuredDay)
        ) { error in
            XCTAssertEqual(error as? ForgeReadFailure, .malformed)
        }
    }

    func testGitHubReplyWithNoAccountIsMalformed() throws {
        let anonymous = try payload(
            """
            {"data":{"viewer":{"contribToday":{"contributionCalendar":{"totalContributions":1}}}}}
            """)
        XCTAssertThrowsError(
            try GitHubActivityFeed.parse(anonymous, connection: Self.gitHub, now: Self.measuredDay))
    }

    /// Pins the query the live API answered on 2026-09-17, because the shape is
    /// the part a refactor can break silently: a document that no longer asks
    /// for the day it means still returns 200.
    func testGitHubDocumentAsksForTheMeasuredWindows() throws {
        let document = GitHubActivityFeed.document(now: Self.measuredDay)
        XCTAssertTrue(document.contains("mergedToday: search"))
        let today = try XCTUnwrap(ForgeWindow.start(of: .today, now: Self.measuredDay))
        let month = try XCTUnwrap(ForgeWindow.start(of: .thirtyDays, now: Self.measuredDay))
        XCTAssertTrue(
            document.contains(
                "is:pr author:@me is:merged merged:>=\(ForgeWindow.timestamp.string(from: today))"),
            document)
        XCTAssertTrue(
            document.contains(
                "is:pr author:@me is:merged merged:>=\(ForgeWindow.timestamp.string(from: month))"))
        XCTAssertTrue(document.contains("contributionCalendar { totalContributions }"))
        XCTAssertTrue(document.contains("viewer { login"))
        // `all` names no range at all, which is how the widest figure is asked
        // for without tripping the one-year refusal.
        XCTAssertTrue(document.contains("contribAll: contributionsCollection {"))
        XCTAssertFalse(document.contains("mergedAll: search(query: \"is:pr author:@me is:merged merged"))
    }

    /// `github.com` answers on its own API host; an Enterprise install answers
    /// under `/api` on the host itself.
    func testGitHubEndpointFollowsTheHost() throws {
        XCTAssertEqual(
            GitHubActivityFeed.endpoint(host: "github.com")?.absoluteString,
            "https://api.github.com/graphql")
        XCTAssertEqual(
            GitHubActivityFeed.endpoint(host: "github.example.com")?.absoluteString,
            "https://github.example.com/api/graphql")
    }

    // MARK: GitLab

    func testGitLabReplyReadsBackTheMergeCountsAndTheAccount() throws {
        let counts = try payload(Self.gitLabReply)
        let user = try XCTUnwrap(counts["currentUser"] as? [String: Any])
        XCTAssertEqual(user["username"] as? String, "team-user")
        let today = try XCTUnwrap(user[ForgeAlias.merged(.today)] as? [String: Any])
        XCTAssertEqual(today["count"] as? Int, 11)
        let all = try XCTUnwrap(user[ForgeAlias.merged(.all)] as? [String: Any])
        XCTAssertEqual(all["count"] as? Int, 519)
    }

    func testGitLabDocumentScopesEachWindowAndLeavesTheWidestUnbounded() {
        let document = GitLabActivityFeed.document(now: Self.measuredDay)
        XCTAssertTrue(document.contains("currentUser { username"))
        XCTAssertTrue(document.contains("authoredMergeRequests(state: merged, mergedAfter:"))
        XCTAssertTrue(document.contains("mergedAll: authoredMergeRequests(state: merged) { count }"))
    }

    /// `after` is exclusive, measured: `after=2026-09-17` answered `x-total: 0`
    /// on a day that had 95 events. So a window starting on a day names the day
    /// before it, and the widest window names none.
    func testGitLabEventsURLNamesTheDayBeforeTheWindowStarts() throws {
        let today = try XCTUnwrap(
            GitLabActivityFeed.eventsURL(Self.gitLab, period: .today, now: Self.measuredDay))
        XCTAssertTrue(today.absoluteString.contains("after=2026-09-16"), today.absoluteString)
        XCTAssertTrue(today.absoluteString.contains("per_page=1"))
        let week = try XCTUnwrap(
            GitLabActivityFeed.eventsURL(Self.gitLab, period: .sevenDays, now: Self.measuredDay))
        XCTAssertTrue(week.absoluteString.contains("after=2026-09-10"), week.absoluteString)
        let everything = try XCTUnwrap(
            GitLabActivityFeed.eventsURL(Self.gitLab, period: .all, now: Self.measuredDay))
        XCTAssertFalse(everything.absoluteString.contains("after="))
    }

    // MARK: Connections

    func testHostIsTakenOutOfWhateverWasPasted() {
        XCTAssertEqual(ForgeConnection.host(from: " GitLab.Example.com "), "gitlab.example.com")
        XCTAssertEqual(
            ForgeConnection.host(from: "https://gitlab.example.com/"), "gitlab.example.com")
        XCTAssertEqual(
            ForgeConnection.host(from: "http://gitlab.example.com/dashboard"),
            "gitlab.example.com")
    }

    /// The id carries the kind as well as the host, so one host serving two
    /// forges is two connections and a removal by name cannot take the wrong
    /// one.
    func testConnectionIdNamesBothTheKindAndTheHost() {
        XCTAssertEqual(Self.gitHub.id, "github:github.com")
        XCTAssertEqual(Self.gitLab.id, "gitlab:gitlab.example.com")
    }
}
