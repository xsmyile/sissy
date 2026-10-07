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
        "contribToday":{"contributionCalendar":{"totalContributions":128}},
        "contribWeek":{"contributionCalendar":{"totalContributions":704}},
        "contribMonth":{"contributionCalendar":{"totalContributions":1009}},
        "contribAll":{"contributionCalendar":{"totalContributions":4138}}},
        "mergedToday":{"issueCount":28},"issuesToday":{"issueCount":7},
        "mergedWeek":{"issueCount":155},"issuesWeek":{"issueCount":58},
        "mergedMonth":{"issueCount":208},"issuesMonth":{"issueCount":80},
        "mergedAll":{"issueCount":403},"issuesAll":{"issueCount":188}}}
        """

    /// A comment page in the shape the live document brings one back, with
    /// stamps either side of the measured day's own windows: two on the day
    /// itself, one inside the week, one inside the month and one far outside
    /// every bounded window. The oldest `updatedAt` is 2026-05-30, which is
    /// what lets the page prove it covers all three.
    private static func gitHubComments(
        hasNextPage: Bool = true, total: Int = 133, nodes: String? = nil
    ) -> String {
        let rows =
            nodes
                ?? """
                {"createdAt":"2026-09-17T15:00:00Z","updatedAt":"2026-09-17T15:00:00Z"},
                {"createdAt":"2026-09-17T09:00:00Z","updatedAt":"2026-09-17T09:00:00Z"},
                {"createdAt":"2026-09-13T09:00:00Z","updatedAt":"2026-09-13T09:00:00Z"},
                {"createdAt":"2026-08-30T09:00:00Z","updatedAt":"2026-08-30T09:00:00Z"},
                {"createdAt":"2026-05-30T21:02:42Z","updatedAt":"2026-05-30T21:02:42Z"}
                """
        return """
            "comments":{"totalCount":\(total),
            "pageInfo":{"hasNextPage":\(hasNextPage)},"nodes":[\(rows)]}
            """
    }

    /// The GitHub reply with a comment page on it, which is what the live
    /// document actually answers with.
    private static func gitHubReplyWithComments(_ comments: String) -> String {
        gitHubReply.replacingOccurrences(
            of: "\"contribAll\":{\"contributionCalendar\":{\"totalContributions\":4138}}}",
            with:
                "\"contribAll\":{\"contributionCalendar\":{\"totalContributions\":4138}},\(comments)}"
        )
    }

    private static let gitLabReply = """
        {"data":{"currentUser":{"username":"davide",
        "mergedToday":{"count":15},"mergedWeek":{"count":91},
        "mergedMonth":{"count":133},"mergedAll":{"count":523}}}}
        """

    private static let gitLabIssuesReply = """
        {"data":{"issuesToday":{"count":17},"issuesWeek":{"count":54},
        "issuesMonth":{"count":62},"issuesAll":{"count":285}}}
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

    /// A window's date is rendered in the calendar the start was computed in.
    /// Rendering it in UTC put every window a day early east of Greenwich: the
    /// start of 2026-09-17 came out `2026-09-16`, a day more than the figure
    /// above it is over.
    func testTheDayFilterRendersTheLocalDayRatherThanTheUTCInstant() throws {
        let start = try XCTUnwrap(ForgeWindow.start(of: .today, now: Self.measuredDay))
        XCTAssertEqual(ForgeWindow.dayName(start), "2026-09-17")
    }

    /// GitHub's contribution calendar reads an argument as a date, so a window
    /// is named by its local **date** at midnight `Z`.
    ///
    /// The regression this pins cost the row a whole extra day: measured
    /// 2026-09-17 from Europe/Rome, the local midnight rendered as the instant
    /// it is — `2026-09-16T22:00:00Z` — answered 326 contributions where the
    /// profile's own square for the 17th read 128, and 773 over seven days
    /// where the seven squares came to 704. Asked from noon or 23:00 on the
    /// 17th it still answers 128, which is what proves the bucket is the day.
    func testEveryWindowIsAskedForAtMidnightUTCOfItsOwnLocalDate() throws {
        let today = try XCTUnwrap(ForgeWindow.start(of: .today, now: Self.measuredDay))
        let week = try XCTUnwrap(ForgeWindow.start(of: .sevenDays, now: Self.measuredDay))
        XCTAssertEqual(ForgeWindow.vendorDay(today), "2026-09-17T00:00:00Z")
        XCTAssertEqual(ForgeWindow.vendorDay(week), "2026-09-11T00:00:00Z")
    }

    /// Just after local midnight east of Greenwich, every document asks for
    /// today from the local midnight.
    ///
    /// Measured 2026-10-07 from Europe/Rome: pull requests opened at 00:34
    /// local time are counted by GitHub under the local date, and its search
    /// counted 15 merges from the Rome midnight against 5 from midnight `Z`.
    /// Through 0.3.3 these documents left today out until 02:00.
    func testJustAfterMidnightEveryDocumentAsksForTodayFromTheLocalMidnight() throws {
        let rome = try Self.calendar("Europe/Rome")
        let night = try Self.instant(hour: 1, minute: 1, in: rome)
        let midnight = "2026-09-18T22:00:00Z"

        let gitHub = GitHubActivityFeed.document(now: night, calendar: rome)
        XCTAssertTrue(
            gitHub.contains(
                "contribToday: contributionsCollection(from: \"2026-09-19T00:00:00Z\", to: \"2026-09-19T23:59:59Z\")"
            ),
            gitHub)
        XCTAssertTrue(gitHub.contains("merged:>=\(midnight)"), gitHub)
        XCTAssertTrue(gitHub.contains("created:>=\(midnight)"), gitHub)

        let merged = GitLabActivityFeed.document(now: night, calendar: rome)
        XCTAssertTrue(
            merged.contains(
                "mergedToday: authoredMergeRequests(state: merged, mergedAfter: \"\(midnight)\")"), merged)
        let issues = GitLabActivityFeed.issuesDocument(now: night, calendar: rome)
        XCTAssertTrue(issues.contains("createdAfter: \"\(midnight)\""), issues)

        let events = try XCTUnwrap(
            GitLabActivityFeed.eventsURL(
                Self.gitLab,
                from: ForgeWindow.start(of: .today, now: night, calendar: rome).map {
                    GitLabDaySplit(start: $0).midnight
                }))
        XCTAssertTrue(events.absoluteString.contains("after=2026-09-18"), events.absoluteString)
    }

    /// East of Greenwich the local day starts before GitLab's UTC day of the
    /// same date, so the header counts from the next UTC midnight and the two
    /// hours before it are added from the feed, newest first.
    func testEastOfGreenwichTheStretchBeforeTheUTCMidnightIsAdded() throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-06T22:00:00Z"))
        let split = GitLabDaySplit(start: start)
        XCTAssertTrue(split.adds)
        XCTAssertEqual(ForgeWindow.instant(split.midnight), "2026-10-07T00:00:00Z")
        XCTAssertEqual(split.sliver.duration, 2 * 3600)
        let url = try XCTUnwrap(GitLabActivityFeed.sliverURL(Self.gitLab, split: split, page: 1))
        let query = url.absoluteString
        XCTAssertTrue(query.contains("after=2026-10-05"), query)
        XCTAssertTrue(query.contains("before=2026-10-07"), query)
        XCTAssertTrue(query.contains("sort=desc"), query)
    }

    /// West of Greenwich the local day starts after the UTC one, so the header
    /// counts from that UTC midnight and the hours before the start come off,
    /// oldest first.
    func testWestOfGreenwichTheStretchAfterTheUTCMidnightIsTakenOff() throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-07T07:00:00Z"))
        let split = GitLabDaySplit(start: start)
        XCTAssertFalse(split.adds)
        XCTAssertEqual(ForgeWindow.instant(split.midnight), "2026-10-07T00:00:00Z")
        XCTAssertEqual(split.sliver.duration, 7 * 3600)
        let query = try XCTUnwrap(GitLabActivityFeed.sliverURL(Self.gitLab, split: split, page: 2))
            .absoluteString
        XCTAssertTrue(query.contains("after=2026-10-06"), query)
        XCTAssertTrue(query.contains("sort=asc"), query)
        XCTAssertTrue(query.contains("page=2"), query)
    }

    /// A page counts only the rows inside the stretch, and is the last one
    /// asked for once it reaches past it in the order it was read.
    func testTheStretchCountsItsOwnRowsAndStopsPastIt() throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions.insert(.withFractionalSeconds)
        let stamp = { (text: String) in try XCTUnwrap(iso.date(from: text)) }
        let start = try stamp("2026-10-06T22:00:00.000Z")
        let east = GitLabDaySplit(start: start)
        let newestFirst = try [
            "2026-10-06T23:59:59.999Z", "2026-10-06T22:46:18.076Z", "2026-10-06T22:00:00.000Z",
            "2026-10-06T21:59:59.999Z", "2026-10-06T20:00:00.000Z",
        ].map(stamp)
        XCTAssertEqual(east.tally(newestFirst).count, 3)
        XCTAssertTrue(east.tally(newestFirst).finished)
        XCTAssertFalse(east.tally(Array(newestFirst.prefix(3))).finished)

        let west = GitLabDaySplit(start: try stamp("2026-10-07T07:00:00.000Z"))
        let oldestFirst = try [
            "2026-10-07T00:00:00.000Z", "2026-10-07T06:59:59.999Z", "2026-10-07T07:00:00.000Z",
        ].map(stamp)
        XCTAssertEqual(west.tally(oldestFirst).count, 2)
        XCTAssertTrue(west.tally(oldestFirst).finished)
    }

    /// A short page is not the last one: GitLab drops the events the token may
    /// not see after paginating, so only an empty `x-next-page` ends the feed.
    func testOnlyTheNextPageHeaderEndsTheStretch() throws {
        XCTAssertFalse(GitLabActivityFeed.isLastPage(try Self.eventsReply(["x-next-page": "2"])))
        XCTAssertTrue(GitLabActivityFeed.isLastPage(try Self.eventsReply(["x-next-page": ""])))
        XCTAssertTrue(GitLabActivityFeed.isLastPage(try Self.eventsReply([:])))
    }

    /// A count moved by a stretch keeps its kind: a floor stays a floor.
    func testACountMovedByAStretchKeepsItsKind() {
        XCTAssertEqual(ForgeEventCount.exact(533).adding(-4), .exact(529))
        XCTAssertEqual(ForgeEventCount.atLeast(10_000).adding(16), .atLeast(10_016))
        XCTAssertNil(ForgeEventCount.exact(2).adding(-5))
    }

    private static func calendar(_ identifier: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: identifier))
        return calendar
    }

    /// The measured night, in whichever zone is asked for: 2026-09-19, the day
    /// the closed window was measured on.
    private static func instant(hour: Int, minute: Int, in calendar: Calendar) throws -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 19
        components.hour = hour
        components.minute = minute
        return try XCTUnwrap(calendar.date(from: components))
    }

    /// No document may carry an instant that is not a day boundary: a
    /// contribution date is a local date written at midnight or at the last
    /// second `Z`, and every other instant is a local midnight.
    ///
    /// Asserted by scanning rather than by naming the strings, and in a zone
    /// pinned east of Greenwich, because a test written where local midnight
    /// *is* midnight UTC passes either mistake straight through: CI runs in UTC.
    func testNoDocumentCarriesAnInstantThatIsNotADayBoundary() throws {
        let rome = try Self.calendar("Europe/Rome")
        let stamp = try NSRegularExpression(pattern: "\\d{4}-\\d{2}-\\d{2}T[^\"\\s.]*")
        let now = try Self.instant(hour: 12, minute: 0, in: rome)
        let documents = [
            GitHubActivityFeed.document(now: now, calendar: rome),
            GitLabActivityFeed.document(now: now, calendar: rome),
            GitLabActivityFeed.issuesDocument(now: now, calendar: rome),
        ]
        for document in documents {
            let range = NSRange(document.startIndex..., in: document)
            let matches = stamp.matches(in: document, range: range)
            XCTAssertFalse(matches.isEmpty, document)
            for match in matches {
                let found = try XCTUnwrap(Range(match.range, in: document).map { String(document[$0]) })
                let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: found), found)
                let isDate = found.hasSuffix("T00:00:00Z") || found.hasSuffix("T23:59:59Z")
                XCTAssertTrue(isDate || rome.startOfDay(for: instant) == instant, found)
            }
        }
    }

    // MARK: GitHub

    func testGitHubReplyReadsBackEveryFigureAndTheAccountThatAnswered() throws {
        let reading = try GitHubActivityFeed.parse(
            payload(Self.gitHubReply), connection: Self.gitHub, now: Self.measuredDay)
        XCTAssertEqual(reading.login, "xsmyile")
        XCTAssertEqual(reading.contributions(for: .today), 128)
        XCTAssertEqual(reading.contributions(for: .sevenDays), 704)
        XCTAssertEqual(reading.contributions(for: .thirtyDays), 1009)
        XCTAssertEqual(reading.contributions(for: .all), 4138)
        XCTAssertEqual(reading.merged(for: .today), 28)
        XCTAssertEqual(reading.merged(for: .all), 403)
        XCTAssertEqual(reading.issues(for: .today), 7)
        XCTAssertEqual(reading.issues(for: .all), 188)
        XCTAssertNil(reading.failure)
    }

    // MARK: GitHub comments

    /// GitHub totals no comment counter, so the windows are cut out of one
    /// page of the account's own comments — and that page has to land on the
    /// same day boundary the query strings beside it carry.
    ///
    /// Measured 2026-09-18 on the live account: one page answered 0 today, 44
    /// over seven days and 71 over thirty, which is exactly what reading all
    /// 133 answers. The fixture is that arithmetic in miniature.
    func testGitHubCutsEveryWindowOutOfTheOneCommentPage() throws {
        let reading = try GitHubActivityFeed.parse(
            payload(Self.gitHubReplyWithComments(Self.gitHubComments())),
            connection: Self.gitHub, now: Self.measuredDay)
        XCTAssertEqual(reading.comments(for: .today), 2)
        XCTAssertEqual(reading.comments(for: .sevenDays), 3)
        XCTAssertEqual(reading.comments(for: .thirtyDays), 4)
        // The widest window is the connection's own total, which is exact
        // however far short the page falls.
        XCTAssertEqual(reading.comments(for: .all), 133)
    }

    /// A comment created before a window but edited inside it does not enter
    /// it: the page is *ordered* by `updatedAt` because that is the only order
    /// the connection offers, and it is *counted* by `createdAt` because that
    /// is when the comment was written.
    func testACommentEditedInsideTheWindowIsCountedWhereItWasWritten() throws {
        let edited = Self.gitHubComments(
            nodes: """
                {"createdAt":"2026-01-04T09:00:00Z","updatedAt":"2026-09-17T15:00:00Z"},
                {"createdAt":"2025-11-02T09:00:00Z","updatedAt":"2026-05-30T21:02:42Z"}
                """)
        let reading = try GitHubActivityFeed.parse(
            payload(Self.gitHubReplyWithComments(edited)),
            connection: Self.gitHub, now: Self.measuredDay)
        XCTAssertEqual(reading.comments(for: .today), 0)
        XCTAssertEqual(reading.comments(for: .sevenDays), 0)
        XCTAssertEqual(reading.comments(for: .thirtyDays), 0)
    }

    /// **The page carries its own proof of coverage, and a window it cannot
    /// prove is absent rather than a lower bound.**
    ///
    /// Nodes come back newest-updated first and nothing can be created after
    /// it was updated, so once the oldest `updatedAt` on the page precedes a
    /// window's start, no comment left unread can fall inside it. Here the page
    /// stops on the measured day itself with more behind it, so only `all` —
    /// which is the connection's own total — can still be answered.
    func testAWindowThePageCannotProveIsAbsentRatherThanAnUnderCount() throws {
        let truncated = Self.gitHubComments(
            nodes: """
                {"createdAt":"2026-09-17T15:00:00Z","updatedAt":"2026-09-17T15:00:00Z"},
                {"createdAt":"2026-09-17T09:00:00Z","updatedAt":"2026-09-17T09:00:00Z"}
                """)
        let reading = try GitHubActivityFeed.parse(
            payload(Self.gitHubReplyWithComments(truncated)),
            connection: Self.gitHub, now: Self.measuredDay)
        XCTAssertNil(reading.comments(for: .today))
        XCTAssertNil(reading.comments(for: .sevenDays))
        XCTAssertNil(reading.comments(for: .thirtyDays))
        XCTAssertEqual(reading.comments(for: .all), 133)
    }

    /// A page with nothing behind it proves every window, however short it is
    /// — there is nothing left that could fall into one.
    func testAPageWithNothingBehindItAnswersEveryWindow() throws {
        let whole = Self.gitHubComments(
            hasNextPage: false, total: 2,
            nodes: """
                {"createdAt":"2026-09-17T15:00:00Z","updatedAt":"2026-09-17T15:00:00Z"},
                {"createdAt":"2026-09-17T09:00:00Z","updatedAt":"2026-09-17T09:00:00Z"}
                """)
        let reading = try GitHubActivityFeed.parse(
            payload(Self.gitHubReplyWithComments(whole)),
            connection: Self.gitHub, now: Self.measuredDay)
        XCTAssertEqual(reading.comments(for: .today), 2)
        XCTAssertEqual(reading.comments(for: .thirtyDays), 2)
        XCTAssertEqual(reading.comments(for: .all), 2)
    }

    /// A `hasNextPage` this build cannot read means *unread*, not *read*.
    ///
    /// The flag's whole job is to say whether anything is missing, so a flag
    /// that is itself missing has to be taken as a yes — defaulted the other
    /// way, a page of two comments would have reported an exact 2 for every
    /// window on an account holding 133.
    func testAnUnreadableHasNextPageIsTakenAsMoreToCome() throws {
        let noFlag = """
            "comments":{"totalCount":133,"pageInfo":{},
            "nodes":[{"createdAt":"2026-09-17T15:00:00Z","updatedAt":"2026-09-17T15:00:00Z"}]}
            """
        let reading = try GitHubActivityFeed.parse(
            payload(Self.gitHubReplyWithComments(noFlag)),
            connection: Self.gitHub, now: Self.measuredDay)
        XCTAssertNil(reading.comments(for: .today))
        XCTAssertNil(reading.comments(for: .thirtyDays))
        XCTAssertEqual(reading.comments(for: .all), 133)
    }

    /// A node whose stamps will not parse takes every bounded window with it.
    ///
    /// Dropping it quietly would remove it from the tally *and* from the
    /// oldest-`updatedAt` the coverage proof rests on, so the page would still
    /// look proven while being one comment short — a lower bound wearing an
    /// exact figure's clothes, which is the one thing this counter must not do.
    func testANodeThatWillNotParseTakesEveryBoundedWindowWithIt() throws {
        let unparseable = Self.gitHubComments(
            nodes: """
                {"createdAt":"2026-09-17T15:00:00Z","updatedAt":"2026-09-17T15:00:00Z"},
                {"createdAt":"not a date","updatedAt":"not a date"},
                {"createdAt":"2026-05-30T21:02:42Z","updatedAt":"2026-05-30T21:02:42Z"}
                """)
        let reading = try GitHubActivityFeed.parse(
            payload(Self.gitHubReplyWithComments(unparseable)),
            connection: Self.gitHub, now: Self.measuredDay)
        XCTAssertNil(reading.comments(for: .today))
        XCTAssertNil(reading.comments(for: .sevenDays))
        XCTAssertNil(reading.comments(for: .thirtyDays))
        XCTAssertEqual(reading.comments(for: .all), 133)
    }

    /// The boundary is strict: a page reaching back only as far as a window's
    /// own start does not prove it, because a comment created on that instant
    /// and never edited would sit just outside the page.
    func testAPageReachingOnlyToTheBoundaryDoesNotProveThatWindow() throws {
        let week = try XCTUnwrap(ForgeWindow.start(of: .sevenDays, now: Self.measuredDay))
        let boundary = ForgeWindow.instant(week)
        let toTheEdge = Self.gitHubComments(
            nodes: """
                {"createdAt":"2026-09-17T15:00:00Z","updatedAt":"2026-09-17T15:00:00Z"},
                {"createdAt":"\(boundary)","updatedAt":"\(boundary)"}
                """)
        let reading = try GitHubActivityFeed.parse(
            payload(Self.gitHubReplyWithComments(toTheEdge)),
            connection: Self.gitHub, now: Self.measuredDay)
        XCTAssertNil(reading.comments(for: .sevenDays))
        // The day above it is proven, because the page reaches past its start.
        XCTAssertEqual(reading.comments(for: .today), 1)
    }

    /// A `nodes` that will not read as an array of objects is not an empty
    /// page.
    ///
    /// GraphQL answers a partial failure by putting a null where the field
    /// should be, so reading that as "no comments, page complete" would publish
    /// a confident 0 for every window out of a reply that carried nothing —
    /// and `hasNextPage: false` beside it is exactly the shape that makes the
    /// zero look proven.
    func testANullNodesFieldIsNotAnEmptyPage() throws {
        let nulled = """
            "comments":{"totalCount":133,"pageInfo":{"hasNextPage":false},"nodes":null}
            """
        let reading = try GitHubActivityFeed.parse(
            payload(Self.gitHubReplyWithComments(nulled)),
            connection: Self.gitHub, now: Self.measuredDay)
        XCTAssertNil(reading.comments(for: .today))
        XCTAssertNil(reading.comments(for: .sevenDays))
        XCTAssertNil(reading.comments(for: .thirtyDays))
        XCTAssertEqual(reading.comments(for: .all), 133)
    }

    /// A genuinely empty page with nothing behind it is still a reading of
    /// zero, which is what the case above must not be confused with.
    func testAnEmptyPageWithNothingBehindItIsAReadingOfZero() throws {
        let empty = """
            "comments":{"totalCount":0,"pageInfo":{"hasNextPage":false},"nodes":[]}
            """
        let reading = try GitHubActivityFeed.parse(
            payload(Self.gitHubReplyWithComments(empty)),
            connection: Self.gitHub, now: Self.measuredDay)
        XCTAssertEqual(reading.comments(for: .today), 0)
        XCTAssertEqual(reading.comments(for: .thirtyDays), 0)
        XCTAssertEqual(reading.comments(for: .all), 0)
    }

    /// A window's date is read off a Gregorian calendar whatever the system
    /// calendar is.
    ///
    /// Taking the components off the system calendar put a Mac whose calendar
    /// is Buddhist five centuries into the future: 2026-09-18 came out as a
    /// date in 2569, which every reading falls before.
    func testTheDateIsAlwaysGregorianWhateverTheSystemCalendarIs() throws {
        let start = try XCTUnwrap(ForgeWindow.start(of: .today, now: Self.measuredDay))
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = Calendar.current.timeZone
        XCTAssertEqual(ForgeWindow.dayName(start, calendar: buddhist), "2026-09-17")
        XCTAssertEqual(ForgeWindow.vendorDay(start, calendar: buddhist), "2026-09-17T00:00:00Z")
    }

    /// A reply with no comment block at all keeps the three counters beside
    /// it: the page is the newest thing on this document and an account or a
    /// build that answers nothing for it has not stopped answering for the
    /// rest.
    func testAReplyWithNoCommentPageStillCarriesTheOtherCounters() throws {
        let reading = try GitHubActivityFeed.parse(
            payload(Self.gitHubReply), connection: Self.gitHub, now: Self.measuredDay)
        XCTAssertNil(reading.comments(for: .today))
        XCTAssertNil(reading.comments(for: .all))
        XCTAssertEqual(reading.contributions(for: .today), 128)
        XCTAssertEqual(reading.merged(for: .today), 28)
    }

    /// The page rides in the same `viewer` the contributions do, which is what
    /// keeps the fourth counter at no extra request — measured 2026-09-18, the
    /// document still costs 1 point of 5000 an hour with it on. It also must
    /// not carry a date: `UPDATED_AT` is an order, not a window.
    func testGitHubDocumentAsksForTheCommentPageInsideTheSameViewer() {
        let document = GitHubActivityFeed.document(now: Self.measuredDay)
        XCTAssertTrue(document.contains("viewer {"), document)
        XCTAssertTrue(
            document.contains(
                "comments: issueComments(first: \(GitHubActivityFeed.commentPage),"
                    + " orderBy: {field: UPDATED_AT, direction: DESC})"), document)
        XCTAssertTrue(document.contains("totalCount pageInfo { hasNextPage }"), document)
        XCTAssertTrue(document.contains("nodes { createdAt updatedAt }"), document)
    }

    /// The instant the comment counting compares against is the one the
    /// searches beside it name, or the row would answer two windows under one
    /// label.
    func testTheCountingBoundaryIsTheSameInstantTheQueryStringsName() throws {
        let week = try XCTUnwrap(ForgeWindow.start(of: .sevenDays, now: Self.measuredDay))
        let document = GitHubActivityFeed.document(now: Self.measuredDay)
        XCTAssertTrue(document.contains("merged:>=\(ForgeWindow.instant(week))"), document)
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
        XCTAssertTrue(document.contains("issuesToday: search"))
        let today = try XCTUnwrap(ForgeWindow.start(of: .today, now: Self.measuredDay))
        let month = try XCTUnwrap(ForgeWindow.start(of: .thirtyDays, now: Self.measuredDay))
        XCTAssertTrue(
            document.contains(
                "is:pr author:@me is:merged merged:>=\(ForgeWindow.instant(today))"),
            document)
        XCTAssertTrue(
            document.contains(
                "is:pr author:@me is:merged merged:>=\(ForgeWindow.instant(month))"))
        XCTAssertTrue(
            document.contains(
                "contribToday: contributionsCollection(from: \"\(ForgeWindow.vendorDay(today))\","
                    + " to: \"\(ForgeWindow.vendorDayEnd(Self.measuredDay))\")"),
            document)
        // Two windows on one row is what the day form exists to stop, so the
        // issue search is scoped by the same string as the merge beside it and
        // by its own qualifier — a pull request enters the merge count when it
        // is merged, an issue the opened count when it is created.
        XCTAssertTrue(
            document.contains("is:issue author:@me created:>=\(ForgeWindow.instant(today))"),
            document)
        XCTAssertTrue(document.contains("contributionCalendar { totalContributions }"))
        XCTAssertTrue(document.contains("viewer { login"))
        // `all` names no range at all, which is how the widest figure is asked
        // for without tripping the one-year refusal.
        XCTAssertTrue(document.contains("contribAll: contributionsCollection {"))
        XCTAssertFalse(document.contains("mergedAll: search(query: \"is:pr author:@me is:merged merged"))
        XCTAssertFalse(document.contains("issuesAll: search(query: \"is:issue author:@me created"))
    }

    /// `github.com` answers on its own API host; an Enterprise install answers
    /// under `/api` on the host itself.
    func testGitHubEndpointFollowsTheHost() throws {
        XCTAssertEqual(
            GitHubActivityFeed.endpoint(.gitHub(host: "github.com"))?.absoluteString,
            "https://api.github.com/graphql")
        XCTAssertEqual(
            GitHubActivityFeed.endpoint(.gitHub(host: "github.example.com"))?.absoluteString,
            "https://github.example.com/api/graphql")
    }

    // MARK: GitLab

    func testGitLabReplyReadsBackTheMergeCountsAndTheAccount() throws {
        let counts = try payload(Self.gitLabReply)
        let user = try XCTUnwrap(counts["currentUser"] as? [String: Any])
        XCTAssertEqual(user["username"] as? String, "davide")
        let today = try XCTUnwrap(user[ForgeAlias.merged(.today)] as? [String: Any])
        XCTAssertEqual(today["count"] as? Int, 15)
        let all = try XCTUnwrap(user[ForgeAlias.merged(.all)] as? [String: Any])
        XCTAssertEqual(all["count"] as? Int, 523)
    }

    func testGitLabDocumentScopesEachWindowAndLeavesTheWidestUnbounded() {
        let document = GitLabActivityFeed.document(now: Self.measuredDay)
        XCTAssertTrue(document.contains("currentUser { username"))
        XCTAssertTrue(document.contains("authoredMergeRequests(state: merged, mergedAfter:"))
        XCTAssertTrue(document.contains("mergedAll: authoredMergeRequests(state: merged) { count }"))
    }

    /// GitLab has no authored-issues field on `currentUser` — measured
    /// 2026-09-17 against 19.3, which answers `Field 'createdIssues' doesn't
    /// exist on type 'CurrentUser'` — so the count comes off the root `issues`
    /// field, filtered by the login the first document returned. **That login
    /// travels as a variable**: it is a name the vendor supplied, and a name
    /// spliced into a query string is a forge deciding what Sissy asks for.
    func testGitLabIssuesDocumentTakesTheAuthorAsAVariableRatherThanSplicingIt() {
        let document = GitLabActivityFeed.issuesDocument(now: Self.measuredDay)
        XCTAssertTrue(document.hasPrefix("query($author: String!)"), document)
        XCTAssertTrue(document.contains("issues(authorUsername: $author, createdAfter:"))
        XCTAssertTrue(document.contains("issuesAll: issues(authorUsername: $author) { count }"))
    }

    func testGitLabIssuesReplyReadsBackEveryWindow() throws {
        let counts = try payload(Self.gitLabIssuesReply)
        for (period, expected) in [
            (UsagePeriod.today, 17), (.sevenDays, 54), (.thirtyDays, 62), (.all, 285),
        ] {
            let block = try XCTUnwrap(counts[ForgeAlias.issues(period)] as? [String: Any])
            XCTAssertEqual(block["count"] as? Int, expected)
        }
    }

    /// `after` is exclusive, measured: `after=2026-09-17` answered `x-total: 0`
    /// on a day that had 95 events. So a window starting on a day names the day
    /// before it, and the widest window names none.
    func testGitLabEventsURLNamesTheDayBeforeTheWindowStarts() throws {
        let today = try XCTUnwrap(
            GitLabActivityFeed.eventsURL(
                Self.gitLab,
                from: ForgeWindow.start(of: .today, now: Self.measuredDay).map {
                    GitLabDaySplit(start: $0).midnight
                }))
        XCTAssertTrue(today.absoluteString.contains("after=2026-09-16"), today.absoluteString)
        XCTAssertTrue(today.absoluteString.contains("per_page=1"))
        let week = try XCTUnwrap(
            GitLabActivityFeed.eventsURL(
                Self.gitLab,
                from: ForgeWindow.start(of: .sevenDays, now: Self.measuredDay).map {
                    GitLabDaySplit(start: $0).midnight
                }))
        XCTAssertTrue(week.absoluteString.contains("after=2026-09-10"), week.absoluteString)
        let everything = try XCTUnwrap(
            GitLabActivityFeed.eventsURL(Self.gitLab, from: nil))
        XCTAssertFalse(everything.absoluteString.contains("after="))
    }

    private static func eventsReply(_ headers: [String: String]) throws -> HTTPURLResponse {
        try XCTUnwrap(
            HTTPURLResponse(
                url: try XCTUnwrap(URL(string: "https://gitlab.example.com/api/v4/events")),
                statusCode: 200, httpVersion: nil, headerFields: headers))
    }

    func testGitLabReadsTheCountOffTheTotalHeader() throws {
        XCTAssertEqual(
            GitLabActivityFeed.count(of: try Self.eventsReply(["x-total": "986", "x-next-page": "2"])),
            .exact(986))
    }

    /// Past ten thousand GitLab drops `x-total` and keeps paginating, so a
    /// reply with a next page and no total is the ceiling as a floor rather
    /// than no figure.
    func testGitLabPastItsCeilingIsAFloorRatherThanNothing() throws {
        XCTAssertEqual(
            GitLabActivityFeed.count(of: try Self.eventsReply(["x-next-page": "2"])),
            .atLeast(GitLabActivityFeed.countCeiling))
    }

    /// A reply carrying neither says nothing, and stays absent rather than
    /// becoming a floor it does not prove.
    func testGitLabWithNeitherHeaderHasNoCount() throws {
        XCTAssertNil(GitLabActivityFeed.count(of: try Self.eventsReply([:])))
        XCTAssertNil(GitLabActivityFeed.count(of: try Self.eventsReply(["x-next-page": ""])))
    }

    /// GitLab files a comment as an event, so the comment count is the very
    /// same header read with one filter on it — same window, same exclusive
    /// `after`, so the figure is a part of the contributions beside it rather
    /// than a second reading of a different period.
    func testGitLabAsksForCommentsOnTheSameWindowAsTheEventsBesideThem() throws {
        let plain = try XCTUnwrap(
            GitLabActivityFeed.eventsURL(
                Self.gitLab,
                from: ForgeWindow.start(of: .sevenDays, now: Self.measuredDay).map {
                    GitLabDaySplit(start: $0).midnight
                }))
        let commented = try XCTUnwrap(
            GitLabActivityFeed.eventsURL(
                Self.gitLab,
                from: ForgeWindow.start(of: .sevenDays, now: Self.measuredDay).map {
                    GitLabDaySplit(start: $0).midnight
                },
                action: GitLabActivityFeed.commentedAction))
        XCTAssertFalse(plain.absoluteString.contains("action="))
        XCTAssertTrue(commented.absoluteString.contains("action=commented"), commented.absoluteString)
        XCTAssertTrue(commented.absoluteString.contains("after=2026-09-10"))
        XCTAssertTrue(commented.absoluteString.contains("per_page=1"))
    }

    // MARK: The counters a row carries

    /// An absent switch is an on one, so a `server.json` written before a
    /// counter existed does not read as that counter being switched off.
    func testAnAbsentSwitchIsAnOnOne() {
        XCTAssertEqual(ForgeCounters.defaults.enabled, ForgeCounter.all)
        var some = ForgeCounters.defaults
        some[.comments] = false
        XCTAssertEqual(some.enabled, [.merged, .issues, .latest, .actions])
        some[.comments] = true
        XCTAssertEqual(some.enabled, ForgeCounter.all)
    }

    /// **A counter switched off is not asked for.** On GitHub that is only a
    /// smaller reply, but it is the same document either way — so the test
    /// that matters is that the fields are gone, not that a request was saved.
    func testGitHubAsksForNothingAboutACounterThatIsOff() {
        let only = GitHubActivityFeed.document(now: Self.measuredDay, counters: [.merged])
        XCTAssertTrue(only.contains("mergedToday: search"), only)
        XCTAssertFalse(only.contains("issuesToday: search"), only)
        XCTAssertFalse(only.contains("comments: issueComments"), only)
        // The contribution total has no switch, so it survives all of them.
        XCTAssertTrue(only.contains("contribToday: contributionsCollection"), only)
        XCTAssertTrue(only.contains("viewer { login"), only)
    }

    /// With every counter off the document is still a valid reading of the
    /// contribution totals, which is the one figure that has no switch.
    func testGitHubStillAsksForTheContributionsWithEveryCounterOff() {
        let bare = GitHubActivityFeed.document(now: Self.measuredDay, counters: [])
        XCTAssertFalse(bare.contains("search("), bare)
        XCTAssertFalse(bare.contains("issueComments"), bare)
        XCTAssertTrue(bare.contains("contribAll: contributionsCollection {"), bare)
    }

    /// GitLab's merged document empties out, but the query itself stays: it is
    /// also what names the account, and the row's login comes off it.
    func testGitLabKeepsTheAccountQueryWithTheMergedCounterOff() {
        let off = GitLabActivityFeed.document(now: Self.measuredDay, counters: [.comments])
        XCTAssertTrue(off.contains("currentUser { username"), off)
        XCTAssertFalse(off.contains("authoredMergeRequests"), off)
    }

    // MARK: Connections

    /// The id carries the kind as well as the host, so one host serving two
    /// forges is two connections and a removal by name cannot take the wrong
    /// one.
    func testConnectionIdNamesBothTheKindAndTheHost() {
        XCTAssertEqual(Self.gitHub.id, "github:github.com")
        XCTAssertEqual(Self.gitLab.id, "gitlab:gitlab.example.com")
    }

    // MARK: What a 403 means

    private func reply(_ headers: [String: String]) throws -> HTTPURLResponse {
        try XCTUnwrap(
            HTTPURLResponse(
                url: XCTUnwrap(URL(string: "https://api.github.com/graphql")), statusCode: 403,
                httpVersion: nil, headerFields: headers))
    }

    /// GitHub answers `403` to a refused token and to a throttled one alike,
    /// and only the headers tell them apart. A secondary limit leaves the
    /// hourly quota untouched and sends a retry deadline instead, so reading
    /// the remaining count alone filed it as a refusal — which parks the
    /// connection and stops the cadence asking again at all.
    func testASecondaryRateLimitIsNotARefusedToken() throws {
        XCTAssertTrue(ForgeActivityFeed.askedToSlowDown(try reply(["Retry-After": "60"])))
        XCTAssertTrue(
            ForgeActivityFeed.askedToSlowDown(try reply(["X-RateLimit-Remaining": "0"])))
    }

    /// A refusal with quota to spare and no deadline on it is the token, which
    /// is the one of these the user has to act on.
    func testARefusalWithQuotaLeftIsTheToken() throws {
        XCTAssertFalse(
            ForgeActivityFeed.askedToSlowDown(try reply(["X-RateLimit-Remaining": "4987"])))
        XCTAssertFalse(ForgeActivityFeed.askedToSlowDown(try reply([:])))
    }

    private static let graphQLEndpoint = "https://gitlab.example.com/api/graphql"

    private func answer(
        _ status: Int, from url: String, headers: [String: String] = [:]
    ) throws -> HTTPURLResponse {
        try XCTUnwrap(
            HTTPURLResponse(
                url: XCTUnwrap(URL(string: url)), statusCode: status, httpVersion: nil,
                headerFields: headers))
    }

    /// A refusal from the host the request was addressed to is the token.
    func testARefusalFromTheForgeItselfIsTheToken() throws {
        let failure = ForgeActivityFeed.failure(
            of: try answer(401, from: Self.graphQLEndpoint),
            addressedTo: URL(string: Self.graphQLEndpoint))
        XCTAssertEqual(failure, .unauthorized)
    }

    /// A refusal from another host came after a redirect that dropped the
    /// token on the way, so it says nothing about the token and must not park
    /// the connection behind a replacement the user does not need.
    func testARefusalFromTheHostARedirectReachedIsNotTheToken() throws {
        let failure = ForgeActivityFeed.failure(
            of: try answer(401, from: "https://sso.example.net/login"),
            addressedTo: URL(string: Self.graphQLEndpoint))
        XCTAssertEqual(failure, .redirected)
        XCTAssertFalse(ForgeReadFailure.redirected.needsTheUser)
    }

    /// A throttling header from the host a redirect reached is that host's
    /// quota, not the forge's, so it is a redirect before it is a slow-down.
    func testARetryDeadlineFromTheHostARedirectReachedIsNotTheForgesLimit() throws {
        let failure = ForgeActivityFeed.failure(
            of: try answer(403, from: "https://sso.example.net/login", headers: ["Retry-After": "60"]),
            addressedTo: URL(string: Self.graphQLEndpoint))
        XCTAssertEqual(failure, .redirected)
    }

    /// The same deadline from the forge itself is the forge asking for less
    /// traffic.
    func testARetryDeadlineFromTheForgeItselfIsARateLimit() throws {
        let failure = ForgeActivityFeed.failure(
            of: try answer(403, from: Self.graphQLEndpoint, headers: ["Retry-After": "60"]),
            addressedTo: URL(string: Self.graphQLEndpoint))
        XCTAssertEqual(failure, .rateLimited)
    }

    /// A redirect `SissyHTTP` refused to follow reaches the feed as the 3xx
    /// itself, which is the same answer as a refusal from another host.
    func testARedirectTheSessionRefusedIsReportedAsOne() throws {
        let failure = ForgeActivityFeed.failure(
            of: try answer(307, from: Self.graphQLEndpoint),
            addressedTo: URL(string: Self.graphQLEndpoint))
        XCTAssertEqual(failure, .redirected)
    }

    func testAnAnswerFromTheForgeIsNoFailure() throws {
        XCTAssertNil(
            ForgeActivityFeed.failure(
                of: try answer(200, from: Self.graphQLEndpoint),
                addressedTo: URL(string: Self.graphQLEndpoint)))
    }

    /// `SissyHTTP` throws a reply from another host rather than handing it
    /// over, and that is the same answer as a refusal from one: never the
    /// token's, so never a connection parked behind a replacement.
    func testAReplyFromAnotherHostThrownByTheSessionIsARedirect() {
        XCTAssertEqual(
            ForgeActivityFeed.failure(thrown: SissyHTTP.LeftItsOrigin(status: 401)), .redirected)
    }

    func testAnyOtherErrorFromTheSessionIsAForgeOutOfReach() {
        XCTAssertEqual(ForgeActivityFeed.failure(thrown: URLError(.timedOut)), .unreachable)
    }

    // MARK: What a probe answers

    private func probeFailure(_ read: () throws -> String) -> ForgeReadFailure? {
        do {
            _ = try read()
            return nil
        } catch {
            return error as? ForgeReadFailure
        }
    }

    func testAGitHubProbeAnswersTheViewersLogin() throws {
        XCTAssertEqual(
            try GitHubActivityFeed.login(fromProbe: ["viewer": ["login": "davide"]]), "davide")
    }

    /// A `currentUser: null` on a 200 is a request GitLab served as nobody.
    /// That is the token, and the connect sheet has to say so rather than
    /// that the host is not GitLab.
    func testAGitLabProbeWithNoCurrentUserIsARefusedToken() {
        XCTAssertEqual(
            probeFailure { try GitLabActivityFeed.username(from: ["currentUser": NSNull()]) },
            .unauthorized)
    }

    func testAGitHubProbeWithNoViewerIsARefusedToken() {
        XCTAssertEqual(
            probeFailure { try GitHubActivityFeed.login(fromProbe: ["viewer": NSNull()]) },
            .unauthorized)
    }

    func testAGitLabProbeAnswersTheUsername() throws {
        XCTAssertEqual(
            try GitLabActivityFeed.username(from: ["currentUser": ["username": "davide"]]), "davide")
    }

    /// A reply that names no user field at all is not a forge of this kind
    /// answering, which is the host or the forge picked, not the token.
    func testAProbeReplyWithoutTheUserFieldIsMalformed() {
        XCTAssertEqual(probeFailure { try GitLabActivityFeed.username(from: [:]) }, .malformed)
        XCTAssertEqual(probeFailure { try GitHubActivityFeed.login(fromProbe: [:]) }, .malformed)
    }
}
