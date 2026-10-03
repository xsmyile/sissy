import XCTest

@testable import Sissy

/// Constructed vendor replies and requests verified 2026-10-03. No test uses
/// a credential or reaches the network.
final class ForgeSpanTests: XCTestCase {
    private static let github = ForgeConnection.gitHub()
    private static let gitlab = ForgeConnection(kind: .gitLab, host: "gitlab.example.com")
    private static let from = date("2026-09-17T00:00:00+02:00")
    private static let to = date("2026-09-19T00:00:00+02:00")
    private static let now = date("2026-10-03T12:00:00Z")
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        return calendar
    }

    private static func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    func testPastDayNamesOneUTCDayAndBoundsBothSearches() {
        let query = ForgeSpanFeed.githubDocument(
            from: Self.from, to: Self.from, now: Self.now, counters: ForgeCounter.all,
            calendar: Self.calendar)
        XCTAssertTrue(query.contains("from: \"2026-09-17T00:00:00Z\""))
        XCTAssertTrue(query.contains("to: \"2026-09-17T23:59:59Z\""))
        XCTAssertTrue(query.contains("merged:>=2026-09-17T00:00:00Z merged:<2026-09-18T00:00:00Z"))
        XCTAssertTrue(query.contains("created:>=2026-09-17T00:00:00Z created:<2026-09-18T00:00:00Z"))
    }

    func testRangeBoundsEveryGitLabRequest() throws {
        let query = ForgeSpanFeed.gitlabDocument(
            from: Self.from, to: Self.to, now: Self.now, counters: ForgeCounter.all, calendar: Self.calendar)
        XCTAssertTrue(query.contains("mergedAfter: \"2026-09-17T00:00:00Z\""))
        XCTAssertTrue(query.contains("mergedBefore: \"2026-09-20T00:00:00Z\""))
        let issues = ForgeSpanFeed.gitlabIssuesDocument(
            from: Self.from, to: Self.to, now: Self.now, calendar: Self.calendar)
        XCTAssertTrue(issues.contains("createdAfter: \"2026-09-17T00:00:00Z\""))
        XCTAssertTrue(issues.contains("createdBefore: \"2026-09-20T00:00:00Z\""))
        XCTAssertTrue(issues.contains("authorUsername: $author"))
        let url = try XCTUnwrap(
            ForgeSpanFeed.gitlabEventsURL(
                Self.gitlab, dates: (Self.from, Self.to), now: Self.now,
                action: GitLabActivityFeed.commentedAction, calendar: Self.calendar))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "after" }?.value, "2026-09-16")
        XCTAssertEqual(items.first { $0.name == "before" }?.value, "2026-09-20")
        XCTAssertEqual(items.first { $0.name == "action" }?.value, "commented")
        let request = ForgeActivityFeed.request(url, token: "fixture", header: "PRIVATE-TOKEN", scheme: nil)
        XCTAssertEqual(request.timeoutInterval, ForgeActivityFeed.requestTimeout)
    }

    func testRangeEndingTodayCapsInstantFiltersAtNow() {
        let today = Self.date("2026-10-03T00:00:00+02:00")
        let github = ForgeSpanFeed.githubDocument(
            from: Self.from, to: today, now: Self.now, counters: ForgeCounter.all, calendar: Self.calendar)
        XCTAssertTrue(github.contains("to: \"2026-10-03T12:00:00Z\""))
        XCTAssertTrue(github.contains("merged:<=2026-10-03T12:00:00Z"))
        let gitlab = ForgeSpanFeed.gitlabDocument(
            from: Self.from, to: today, now: Self.now, counters: ForgeCounter.all, calendar: Self.calendar)
        XCTAssertTrue(gitlab.contains("mergedBefore: \"2026-10-03T12:00:00Z\""))
    }

    func testOffCountersDoNotAppearInDocuments() {
        let github = ForgeSpanFeed.githubDocument(
            from: Self.from, to: Self.to, now: Self.now, counters: [], calendar: Self.calendar)
        XCTAssertTrue(github.contains("contributionsCollection"))
        XCTAssertFalse(github.contains("search("))
        XCTAssertFalse(github.contains("issueComments"))
        let gitlab = ForgeSpanFeed.gitlabDocument(
            from: Self.from, to: Self.to, now: Self.now, counters: [], calendar: Self.calendar)
        XCTAssertTrue(gitlab.contains("username"))
        XCTAssertFalse(gitlab.contains("authoredMergeRequests"))
    }

    func testMultiYearContributionsUseNonoverlappingYearSizedFields() {
        let from = Self.date("2023-09-17T00:00:00+02:00")
        let bounds = ForgeSpanFeed.bounds(from: from, to: Self.to, now: Self.now, calendar: Self.calendar)!
        let ranges = ForgeSpanFeed.contributionRanges(start: bounds.start, end: bounds.end)
        XCTAssertGreaterThan(ranges.count, 3)
        XCTAssertEqual(ranges.first?.0, bounds.start)
        XCTAssertEqual(ranges.last?.1, bounds.end)
        for index in ranges.indices {
            XCTAssertLessThan(ranges[index].1.timeIntervalSince(ranges[index].0), 365 * 86400)
            if index > 0 {
                XCTAssertEqual(ranges[index].0, ranges[index - 1].1.addingTimeInterval(1))
            }
        }
    }

    func testMappingAlsoWorksWestOfUTCAndAcrossMidnightDST() throws {
        var west = Calendar(identifier: .gregorian)
        west.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let westDay = Self.date("2026-09-17T00:00:00-07:00")
        let bounds = try XCTUnwrap(
            ForgeSpanFeed.bounds(
                from: westDay, to: westDay, now: Self.now, calendar: west))
        XCTAssertEqual(bounds.start, Self.date("2026-09-17T00:00:00Z"))
        var cairo = Calendar(identifier: .gregorian)
        cairo.timeZone = TimeZone(identifier: "Africa/Cairo")!
        let firstInstant = Self.date("2026-04-24T01:00:00+03:00")
        let dst = try XCTUnwrap(
            ForgeSpanFeed.bounds(
                from: firstInstant, to: firstInstant, now: Self.now, calendar: cairo))
        XCTAssertEqual(dst.start, Self.date("2026-04-24T00:00:00Z"))
    }

    func testGitHubParsesZeroAndCountsOnlyCommentsInsideSpan() throws {
        let payload: [String: Any] = [
            "viewer": [
                "login": "vendor-login", "contrib0": ["contributionCalendar": ["totalContributions": 0]],
                "comments": [
                    "pageInfo": ["hasNextPage": false],
                    "nodes": [
                        ["createdAt": "2026-09-16T23:59:59Z", "updatedAt": "2026-09-19T10:00:00Z"],
                        ["createdAt": "2026-09-17T00:00:00Z", "updatedAt": "2026-09-17T00:00:00Z"],
                        ["createdAt": "2026-09-19T23:59:59.500Z", "updatedAt": "2026-09-19T23:59:59.500Z"],
                        ["createdAt": "2026-09-20T00:00:00Z", "updatedAt": "2026-09-20T00:00:00Z"],
                    ],
                ],
            ],
            "merged": ["issueCount": 2], "issues": ["issueCount": 3],
        ]
        let reading = try ForgeSpanFeed.parseGitHub(
            payload, connection: Self.github,
            dates: (Self.from, Self.to), now: Self.now, counters: ForgeCounter.all, calendar: Self.calendar)
        XCTAssertEqual(reading.login, "vendor-login")
        XCTAssertEqual(reading.counters[.contributions], .counted(.exact(0)))
        XCTAssertEqual(reading.counters[.merged], .counted(.exact(2)))
        XCTAssertEqual(reading.counters[.issues], .counted(.exact(3)))
        XCTAssertEqual(reading.counters[.comments], .counted(.exact(2)))
    }

    func testIncompleteOrMalformedCommentPageIsAbsent() {
        let start = Self.date("2026-09-17T00:00:00Z")
        let end = Self.date("2026-09-20T00:00:00Z")
        let page: [String: Any] = [
            "comments": [
                "pageInfo": ["hasNextPage": true],
                "nodes": [
                    ["createdAt": "2026-09-18T12:00:00Z", "updatedAt": "2026-09-18T12:00:00Z"]
                ],
            ]
        ]
        XCTAssertEqual(ForgeSpanFeed.commentCount(page, start: start, end: end), .unavailable(.incomplete))
        XCTAssertEqual(
            ForgeSpanFeed.commentCount(["comments": ["nodes": NSNull()]], start: start, end: end),
            .unavailable(.failure(.malformed)))
    }

    func testPartialScopeErrorKeepsSuccessfulFiguresAndOffReasons() throws {
        let root: [String: Any] = [
            "data": [
                "viewer": [
                    "login": "vendor",
                    "contrib0":
                        ["contributionCalendar": ["totalContributions": 7]],
                ], "merged": NSNull(),
            ],
            "errors": [["type": "INSUFFICIENT_SCOPES", "path": ["merged"]]],
        ]
        let decoded = try ForgeSpanFeed.decode(root)
        let reading = try ForgeSpanFeed.parseGitHub(
            decoded.data, failures: decoded.failures,
            connection: Self.github, dates: (Self.from, Self.to), now: Self.now,
            counters: [.merged], calendar: Self.calendar)
        XCTAssertEqual(reading.counters[.contributions], .counted(.exact(7)))
        XCTAssertEqual(reading.counters[.merged], .unavailable(.missingScope))
        XCTAssertEqual(reading.counters[.issues], .unavailable(.switchedOff))
        XCTAssertEqual(reading.counters[.comments], .unavailable(.switchedOff))
        XCTAssertEqual(
            ForgeSpanFeed.count(["issues": ["count": 0]], alias: "issues", failures: [:]),
            .counted(.exact(0)))
        XCTAssertEqual(
            ForgeSpanFeed.count([:], alias: "issues", failures: ["issues": .missingScope]),
            .unavailable(.missingScope))
    }

    func testCacheIsPerConnectionAndDatesAndExpires() async throws {
        let calls = LockedValue(0)
        let monitor = ForgeActivityMonitor(
            connections: [Self.github, Self.gitlab], token: { _, _ in .found("fixture") })
        let fetch:
            @Sendable (ForgeConnection, String, Set<ForgeCounter>, Date, Date, Date) async throws ->
                ForgeSpanReading = {
                    connection, _, counters, from, to, now in
                    calls.update { $0 += 1 }
                    return .unavailable(
                        connection, dates: (from, to), now: now, enabled: counters,
                        reason: .failure(.unreachable))
                }
        let first = try await monitor.readSpan(from: Self.from, to: Self.to, now: Self.now, fetch: fetch)
        let cached = try await monitor.readSpan(
            from: Self.from, to: Self.to, now: Self.now.addingTimeInterval(1), fetch: fetch)
        XCTAssertEqual(first.map(\.id), [Self.github.id, Self.gitlab.id])
        XCTAssertEqual(first, cached)
        XCTAssertEqual(calls.load(), 2)
        _ = try await monitor.readSpan(from: Self.from, to: Self.from, now: Self.now, fetch: fetch)
        XCTAssertEqual(calls.load(), 4)
        _ = try await monitor.readSpan(
            from: Self.from, to: Self.to,
            now: Self.now.addingTimeInterval(ForgeActivityMonitor.spanCacheTTL), fetch: fetch)
        XCTAssertEqual(calls.load(), 6)
        XCTAssertTrue(monitor.currentReadings().isEmpty)
        await monitor.stop()
        _ = try await monitor.readSpan(from: Self.from, to: Self.to, now: Self.now, fetch: fetch)
        XCTAssertEqual(calls.load(), 8)
    }

    func testStopCancelsTheSpanBeforeAnotherConnectionIsFetched() async throws {
        let began = LockedValue(false)
        let calls = LockedValue(0)
        let monitor = ForgeActivityMonitor(
            connections: [Self.github, Self.gitlab], token: { _, _ in .found("fixture") })
        let task = Task {
            try await monitor.readSpan(from: Self.from, to: Self.to, now: Self.now) { _, _, _, _, _, _ in
                calls.update { $0 += 1 }
                began.store(true)
                try await Task.sleep(for: .seconds(10))
                throw ForgeReadFailure.unreachable
            }
        }
        while !began.load() { await Task.yield() }
        await monitor.stop()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(calls.load(), 1)
    }

    func testInvalidSpanDoesNotFetch() async throws {
        let reading = try await ForgeSpanFeed.read(
            Self.github, token: "fixture", counters: [],
            from: Self.to, to: Self.from, now: Self.now)
        XCTAssertEqual(reading.counters[.contributions], .unavailable(.invalidDates))
        XCTAssertEqual(reading.counters[.comments], .unavailable(.switchedOff))
        let today = Self.date("2026-10-03T00:00:00+02:00")
        let early = Self.date("2026-10-03T01:00:00+02:00")
        let bounds = try XCTUnwrap(
            ForgeSpanFeed.bounds(
                from: today, to: today, now: early,
                calendar: Self.calendar))
        XCTAssertGreaterThan(bounds.start, early)
    }

    func testCancelledFetchIsNotCachedAndMissingTokenIsAbsent() async throws {
        let monitor = ForgeActivityMonitor(connections: [Self.github], token: { _, _ in .absent })
        let missing = try await monitor.readSpan(from: Self.from, to: Self.to, now: Self.now)
        XCTAssertEqual(missing.first?.counters[.contributions], .unavailable(.failure(.noCredential)))
        let active = ForgeActivityMonitor(connections: [Self.github], token: { _, _ in .found("fixture") })
        let began = LockedValue(false)
        let task = Task {
            try await active.readSpan(from: Self.from, to: Self.to, now: Self.now) { _, _, _, _, _, _ in
                began.store(true)
                try await Task.sleep(for: .seconds(10))
                throw ForgeReadFailure.unreachable
            }
        }
        while !began.load() { await Task.yield() }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let calls = LockedValue(0)
        _ = try await active.readSpan(from: Self.from, to: Self.to, now: Self.now) {
            connection, _, enabled, from, to, now in
            calls.update { $0 += 1 }
            return .unavailable(
                connection, dates: (from, to), now: now, enabled: enabled,
                reason: .failure(.unreachable))
        }
        XCTAssertEqual(calls.load(), 1)
    }
}
