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
        XCTAssertTrue(query.contains("merged:2026-09-16T22:00:00Z..2026-09-17T21:59:59Z"))
        XCTAssertTrue(query.contains("created:2026-09-16T22:00:00Z..2026-09-17T21:59:59Z"))
        XCTAssertFalse(query.contains("merged:>="))
        XCTAssertFalse(query.contains("created:<"))
    }

    /// A past span's merges are those after its start less those after its
    /// end, because `mergedBefore` widens to the end of the UTC day.
    func testRangeBoundsEveryGitLabRequestOnTheLocalDays() throws {
        let query = ForgeSpanFeed.gitlabDocument(
            from: Self.from, to: Self.to, now: Self.now, counters: ForgeCounter.all, calendar: Self.calendar)
        XCTAssertTrue(
            query.contains(
                "merged: authoredMergeRequests(state: merged, mergedAfter: \"2026-09-16T22:00:00Z\")"))
        XCTAssertTrue(
            query.contains(
                "\(ForgeSpanFeed.mergedLaterAlias): authoredMergeRequests(state: merged, mergedAfter: \"2026-09-19T22:00:00Z\")"
            ))
        XCTAssertFalse(query.contains("mergedBefore"))
        let issues = ForgeSpanFeed.gitlabIssuesDocument(
            from: Self.from, to: Self.to, now: Self.now, calendar: Self.calendar)
        XCTAssertTrue(issues.contains("createdAfter: \"2026-09-16T22:00:00Z\""))
        XCTAssertTrue(issues.contains("createdBefore: \"2026-09-19T21:59:59.999Z\""))
        XCTAssertTrue(issues.contains("authorUsername: $author"))
    }

    /// A closed span whose second merge count did not come back has no
    /// figure: the first count alone is every merge since the start.
    func testAClosedGitLabSpanNeedsBothMergeCounts() {
        let both: [String: Any] = ["merged": ["count": 79], ForgeSpanFeed.mergedLaterAlias: ["count": 4]]
        XCTAssertEqual(ForgeSpanFeed.gitlabMerged(both, failures: [:], isOpen: false), .counted(.exact(75)))
        let missing: [String: Any] = ["merged": ["count": 79]]
        XCTAssertEqual(
            ForgeSpanFeed.gitlabMerged(missing, failures: [:], isOpen: false),
            .unavailable(.failure(.malformed)))
        XCTAssertEqual(ForgeSpanFeed.gitlabMerged(missing, failures: [:], isOpen: true), .counted(.exact(79)))
    }

    func testRangeEndingTodayCapsInstantFiltersAtNow() {
        let today = Self.date("2026-10-03T00:00:00+02:00")
        let github = ForgeSpanFeed.githubDocument(
            from: Self.from, to: today, now: Self.now, counters: ForgeCounter.all, calendar: Self.calendar)
        XCTAssertTrue(github.contains("to: \"2026-10-03T23:59:59Z\""))
        XCTAssertTrue(github.contains("merged:2026-09-16T22:00:00Z..2026-10-03T12:00:00Z"))
        let gitlab = ForgeSpanFeed.gitlabDocument(
            from: Self.from, to: today, now: Self.now, counters: ForgeCounter.all, calendar: Self.calendar)
        XCTAssertTrue(gitlab.contains("mergedAfter: \"2026-09-16T22:00:00Z\""))
        XCTAssertFalse(gitlab.contains(ForgeSpanFeed.mergedLaterAlias))
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
        let ranges = ForgeSpanFeed.contributionRanges(start: bounds.calendarStart, end: bounds.calendarEnd)
        XCTAssertGreaterThan(ranges.count, 3)
        XCTAssertEqual(ranges.first?.0, bounds.calendarStart)
        XCTAssertEqual(ranges.last?.1, bounds.calendarEnd)
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
        XCTAssertEqual(bounds.start, westDay)
        XCTAssertEqual(bounds.calendarStart, Self.date("2026-09-17T00:00:00Z"))
        var cairo = Calendar(identifier: .gregorian)
        cairo.timeZone = TimeZone(identifier: "Africa/Cairo")!
        let firstInstant = Self.date("2026-04-24T01:00:00+03:00")
        let dst = try XCTUnwrap(
            ForgeSpanFeed.bounds(
                from: firstInstant, to: firstInstant, now: Self.now, calendar: cairo))
        XCTAssertEqual(dst.start, firstInstant)
        XCTAssertEqual(dst.calendarStart, Self.date("2026-04-24T00:00:00Z"))
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
                        reason: .missingScope)
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

    func testStopAnswersAnExplicitAbsenceForConcurrentConnections() async throws {
        let began = LockedValue(false)
        let calls = LockedValue(0)
        let monitor = ForgeActivityMonitor(
            connections: [Self.github, Self.gitlab], token: { _, _ in .found("fixture") })
        let (from, to, now) = (Self.from, Self.to, Self.now)
        let task = Task { [monitor, calls, began] in
            try await monitor.readSpan(from: from, to: to, now: now) { _, _, _, _, _, _ in
                calls.update { $0 += 1 }
                began.store(true)
                try await Task.sleep(for: .seconds(10))
                throw ForgeReadFailure.unreachable
            }
        }
        while !began.load() { await Task.yield() }
        await monitor.stop()
        let readings = try await task.value
        XCTAssertEqual(readings.count, 2)
        XCTAssertTrue(readings.allSatisfy { $0.counters[.contributions] == .unavailable(.monitorChanged) })
        XCTAssertEqual(calls.load(), 2)
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
        XCTAssertLessThan(bounds.start, early)
        XCTAssertEqual(bounds.end, early)
        XCTAssertTrue(bounds.isOpen)
    }

    func testCancelledFetchIsNotCachedAndMissingTokenIsAbsent() async throws {
        let monitor = ForgeActivityMonitor(connections: [Self.github], token: { _, _ in .absent })
        let missing = try await monitor.readSpan(from: Self.from, to: Self.to, now: Self.now)
        XCTAssertEqual(missing.first?.counters[.contributions], .unavailable(.failure(.noCredential)))
        let active = ForgeActivityMonitor(connections: [Self.github], token: { _, _ in .found("fixture") })
        let began = LockedValue(false)
        let (from, to, now) = (Self.from, Self.to, Self.now)
        let task = Task { [active, began] in
            try await active.readSpan(from: from, to: to, now: now) { _, _, _, _, _, _ in
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
    func testFailedReadingsAreNeverCached() async throws {
        let calls = LockedValue(0)
        let monitor = ForgeActivityMonitor(connections: [Self.github], token: { _, _ in .found("fixture") })
        for _ in 0..<2 {
            _ = try await monitor.readSpan(from: Self.from, to: Self.to, now: Self.now) {
                connection, _, enabled, from, to, now in
                calls.update { $0 += 1 }
                return .unavailable(
                    connection, dates: (from, to), now: now, enabled: enabled,
                    reason: .failure(.unreachable))
            }
        }
        XCTAssertEqual(calls.load(), 2)
    }

    func testParkedAndRateLimitedPollsPreventSpanRequests() async throws {
        for failure in [ForgeReadFailure.unauthorized, .rateLimited] {
            let monitor = ForgeActivityMonitor(
                connections: [Self.github],
                fetch: { _, _, _, _ in throw failure }, token: { _, _ in .found("fixture") })
            _ = await monitor.refreshOnce {}
            let calls = LockedValue(0)
            let result = try await monitor.readSpan(from: Self.from, to: Self.to) {
                connection, _, enabled, from, to, now in
                calls.update { $0 += 1 }
                return .unavailable(
                    connection, dates: (from, to), now: now, enabled: enabled, reason: .missingScope)
            }
            XCTAssertEqual(calls.load(), 0)
            XCTAssertEqual(result.first?.counters[.contributions], .unavailable(.failure(failure)))
        }
    }

    func testEquivalentVendorDatesShareCacheAndInflightFetch() async throws {
        let local = Calendar.current
        let from = try XCTUnwrap(local.date(from: DateComponents(year: 2026, month: 9, day: 17)))
        let to = try XCTUnwrap(local.date(from: DateComponents(year: 2026, month: 9, day: 19)))
        let now = Self.now
        let calls = LockedValue(0)
        let began = LockedValue(false)
        let monitor = ForgeActivityMonitor(connections: [Self.github], token: { _, _ in .found("fixture") })
        let fetch:
            @Sendable (ForgeConnection, String, Set<ForgeCounter>, Date, Date, Date) async throws ->
                ForgeSpanReading = {
                    connection, _, enabled, from, to, now in
                    calls.update { $0 += 1 }
                    began.store(true)
                    try await Task.sleep(for: .milliseconds(100))
                    return .unavailable(
                        connection, dates: (from, to), now: now, enabled: enabled, reason: .missingScope)
                }
        let first = Task { [monitor, fetch] in
            try await monitor.readSpan(from: from, to: to, now: now, fetch: fetch)
        }
        while !began.load() { await Task.yield() }
        let second = Task { [monitor, fetch] in
            try await monitor.readSpan(
                from: from.addingTimeInterval(3600),
                to: to.addingTimeInterval(3600), now: now, fetch: fetch)
        }
        _ = try await first.value
        _ = try await second.value
        _ = try await monitor.readSpan(
            from: from.addingTimeInterval(7200),
            to: to.addingTimeInterval(7200), now: now, fetch: fetch)
        XCTAssertEqual(calls.load(), 1)
    }

    func testSpanEndingTodaySharesInflightFetchAndCacheAcrossCallTimes() async throws {
        let calls = LockedValue(0)
        let began = LockedValue(false)
        let monitor = ForgeActivityMonitor(connections: [Self.github], token: { _, _ in .found("fixture") })
        let fetch:
            @Sendable (ForgeConnection, String, Set<ForgeCounter>, Date, Date, Date) async throws ->
                ForgeSpanReading = {
                    connection, _, enabled, from, to, now in
                    calls.update { $0 += 1 }
                    began.store(true)
                    try await Task.sleep(for: .milliseconds(100))
                    return .unavailable(
                        connection, dates: (from, to), now: now, enabled: enabled, reason: .missingScope)
                }
        let now = Self.now
        let today = Calendar.current.startOfDay(for: now)
        let from = today.addingTimeInterval(-14 * 86400)
        let first = Task { [monitor, fetch] in
            try await monitor.readSpan(from: from, to: today, now: now, fetch: fetch)
        }
        while !began.load() { await Task.yield() }
        let second = Task { [monitor, fetch] in
            try await monitor.readSpan(from: from, to: today, now: now.addingTimeInterval(5), fetch: fetch)
        }
        _ = try await first.value
        _ = try await second.value
        _ = try await monitor.readSpan(from: from, to: today, now: now.addingTimeInterval(30), fetch: fetch)
        XCTAssertEqual(calls.load(), 1)
    }

    func testGraphQLRateLimitAnsweredWithA200PersistsItsDeadline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("refusals.json")
        let reset = Date().addingTimeInterval(1800).timeIntervalSince1970.rounded()
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: Self.github.root!, statusCode: 200,
                httpVersion: nil, headerFields: ["X-RateLimit-Reset": "\(Int(reset))"]))
        let store = ForgeRefusalStore(url: url)
        let healthy: [String: Any] = ["data": ["viewer": ["login": "vendor"]]]
        XCTAssertNil(
            ForgeActivityFeed.fileGraphQLRefusal(
                healthy, reply: response, url: Self.github.root, token: "fixture", store: store))
        XCTAssertNil(store.failure(url: Self.github.root, token: "fixture"))
        let refused: [String: Any] = [
            "errors": [["type": "RATE_LIMITED", "message": "API rate limit exceeded"]]
        ]
        XCTAssertEqual(
            ForgeActivityFeed.fileGraphQLRefusal(
                refused, reply: response, url: Self.github.root, token: "fixture", store: store),
            .rateLimited)
        let restored = ForgeRefusalStore(url: url)
        XCTAssertEqual(restored.failure(url: Self.github.root, token: "fixture"), .rateLimited)
        XCTAssertEqual(
            restored.deadline(url: Self.github.root, token: "fixture"), Date(timeIntervalSince1970: reset))
    }

    func testTodayAcceptsTimesWithinTheNamedDayAndLongSpansAreInvalid() throws {
        let today = Self.date("2026-10-03T12:00:00+02:00")
        XCTAssertNotNil(ForgeSpanFeed.bounds(from: today, to: today, now: Self.now, calendar: Self.calendar))
        XCTAssertNil(
            ForgeSpanFeed.bounds(
                from: Self.date("2000-01-01T00:00:00Z"), to: Self.to,
                now: Self.now, calendar: Self.calendar))
        XCTAssertTrue(ForgeSpanFeed.contributionRanges(start: Self.now, end: Self.from).isEmpty)
        let largest = ForgeSpanFeed.contributionRanges(
            start: Self.from, end: Self.from.addingTimeInterval(3650 * 86400 - 1))
        XCTAssertEqual(largest.count, 10)
        XCTAssertTrue(
            ForgeSpanFeed.contributionRanges(
                start: Self.from, end: Self.from.addingTimeInterval(3650 * 86400)
            ).isEmpty)
        let reading = try ForgeSpanFeed.parseGitHub(
            ["viewer": ["login": "vendor", "contrib0": ["contributionCalendar": ["totalContributions": 5]]]],
            connection: Self.github, dates: (today, today), now: Self.date("2026-10-03T01:00:00+02:00"),
            counters: [], calendar: Self.calendar)
        XCTAssertEqual(reading.counters[.contributions], .counted(.exact(5)))
    }

    func testParentGraphQLErrorsKeepTheirScopeReasonAndTypeWinsOverText() throws {
        for path in [["viewer"], ["viewer", "contributionsCollection"]] {
            let reply = try ForgeSpanFeed.decode([
                "data": ["viewer": ["login": "vendor"]],
                "errors": [["type": "INSUFFICIENT_SCOPES", "path": path]],
            ])
            let reading = try ForgeSpanFeed.parseGitHub(
                reply.data, failures: reply.failures,
                connection: Self.github, dates: (Self.from, Self.to), now: Self.now,
                counters: [], calendar: Self.calendar)
            XCTAssertEqual(reading.counters[.contributions], .unavailable(.missingScope))
        }
        let reply = try ForgeSpanFeed.decode([
            "data": [:],
            "errors": [
                ["type": "INTERNAL", "message": "scope lookup failed", "path": ["issues"]]
            ],
        ])
        XCTAssertEqual(reply.failures["issues"], .failure(.malformed))
    }

    func testDeadlineReturnsAbsenceForEverySlowConnection() async throws {
        let calls = LockedValue(0)
        let monitor = ForgeActivityMonitor(
            connections: [Self.github, Self.gitlab], token: { _, _ in .found("fixture") })
        let result = try await monitor.readSpan(
            from: Self.from, to: Self.to, now: Self.now, deadline: .milliseconds(100)
        ) {
            _, _, _, _, _, _ in
            calls.update { $0 += 1 }
            try await Task.sleep(for: .seconds(10))
            throw ForgeReadFailure.unreachable
        }
        XCTAssertEqual(calls.load(), 2)
        XCTAssertTrue(result.allSatisfy { $0.counters[.contributions] == .unavailable(.deadlineExceeded) })
    }

    func testRefusalPersistsPerCredentialAndRetryAfterIsHonoured() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("refusals.json")
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: Self.github.root!, statusCode: 429,
                httpVersion: nil, headerFields: ["Retry-After": "900"]))
        let until = ForgeRefusalStore.retryDeadline(response, now: Self.now)
        XCTAssertEqual(until, Self.now.addingTimeInterval(900))
        ForgeRefusalStore(url: url).record(
            .rateLimited, url: Self.github.root, token: "fixture", until: until)
        let restored = ForgeRefusalStore(url: url)
        XCTAssertEqual(restored.failure(url: Self.github.root, token: "fixture", now: Self.now), .rateLimited)
        XCTAssertNil(restored.failure(url: Self.github.root, token: "other", now: Self.now))
        XCTAssertNil(restored.failure(url: Self.github.root, token: "fixture", now: until))
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("fixture"))
    }

}
