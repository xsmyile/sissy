import XCTest

@testable import Sissy

/// The counters under each project: what is asked, how a reply is split by
/// repository, and what is left absent rather than drawn short.
final class ForgeRepositoryActivityTests: XCTestCase {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)
    private static let end = start.addingTimeInterval(86_400)
    private static let bounds = ForgeSpanFeed.VendorBounds(
        start: start, end: end, isOpen: false, firstDay: "2027-01-15", lastDay: "2027-01-15",
        calendarStart: start, calendarEnd: end)
    private static let inside = ForgeWindow.instant(start.addingTimeInterval(60))
    private static let after = ForgeWindow.instant(end.addingTimeInterval(60))
    private static let blackbird = ForgeRepositoryID(host: "github.com", fullName: "xsmyile/Blackbird")

    func testAnIdentityIgnoresCase() {
        XCTAssertEqual(Self.blackbird, ForgeRepositoryID(host: "GitHub.com", fullName: "XSMYILE/blackbird"))
    }

    func testARepositoryNameTravelsAsAVariable() {
        let hostile = ForgeRepositoryID(host: "github.com", fullName: "a/b\") { x }")
        let document = ForgeRepositoryFeed.gitHubDocument(
            repositories: [hostile], bounds: Self.bounds, counters: [.merged, .issues], comments: false)

        XCTAssertFalse(document.query.contains("a/b"))
        XCTAssertTrue(document.variables["m0"]?.hasPrefix("repo:a/b") == true)
        XCTAssertTrue(document.variables["i0"]?.contains("is:issue author:@me") == true)
    }

    func testASwitchedOffCounterIsNotAskedFor() {
        let document = ForgeRepositoryFeed.gitHubDocument(
            repositories: [Self.blackbird], bounds: Self.bounds, counters: [.issues], comments: false)

        XCTAssertNil(document.variables["m0"])
        XCTAssertNotNil(document.variables["i0"])
        XCTAssertFalse(document.query.contains("issueComments"))
    }

    func testCommentsAreSplitByRepositoryInsideTheWindow() throws {
        let node: (String, String) -> [String: Any] = { stamp, name in
            ["createdAt": stamp, "updatedAt": stamp, "repository": ["nameWithOwner": name]]
        }
        let viewer: [String: Any] = [
            "comments": [
                "pageInfo": ["hasNextPage": false],
                "nodes": [
                    node(Self.after, "xsmyile/Blackbird"),
                    node(Self.inside, "xsmyile/Blackbird"),
                    node(Self.inside, "xsmyile/sissy"),
                ],
            ]
        ]

        XCTAssertEqual(
            ForgeRepositoryFeed.gitHubComments(viewer, bounds: Self.bounds)?.counts,
            ["xsmyile/blackbird": 1, "xsmyile/sissy": 1])
    }

    /// A page that stops inside the window could be missing any repository's
    /// comments, so every row loses the figure rather than a few reading short.
    func testACommentPageThatCannotProveTheWindowAnswersNothing() {
        let viewer: [String: Any] = [
            "comments": [
                "pageInfo": ["hasNextPage": true],
                "nodes": [
                    [
                        "createdAt": Self.inside, "updatedAt": Self.inside,
                        "repository": ["nameWithOwner": "xsmyile/sissy"],
                    ]
                ],
            ]
        ]

        XCTAssertNil(ForgeRepositoryFeed.gitHubComments(viewer, bounds: Self.bounds))
    }

    func testGitLabRowsAreCountedByTheirReferenceInsideTheWindow() throws {
        let row: (String, Int, String) -> [String: Any] = { stamp, project, reference in
            ["merged_at": stamp, "project_id": project, "references": ["full": reference]]
        }
        let tally = try XCTUnwrap(
            ForgeRepositoryFeed.tallyReferences(
                [
                    row(Self.inside, 1, "solutions/Gewi!12"),
                    row(Self.inside, 1, "solutions/gewi!13"),
                    row(Self.inside, 2, "group/sub/repo!1"),
                    row(Self.after, 3, "late/repo!1"),
                ],
                stamp: "merged_at", bounds: Self.bounds))

        XCTAssertEqual(tally.counts, ["solutions/gewi": 2, "group/sub/repo": 1])
        XCTAssertEqual(tally.projects[3], "late/repo", "a row outside the window still teaches its id")
    }

    func testAGitLabRowThatWillNotParseMakesTheCountAbsent() {
        XCTAssertNil(
            ForgeRepositoryFeed.tallyReferences(
                [["merged_at": Self.inside, "project_id": 1]], stamp: "merged_at", bounds: Self.bounds))
        XCTAssertThrowsError(
            try ForgeRepositoryFeed.tallyEvents(
                [["created_at": "not a date", "project_id": 1]], bounds: Self.bounds))
    }

    func testGitLabEventsAreCountedByProjectInsideTheWindow() throws {
        XCTAssertEqual(
            try ForgeRepositoryFeed.tallyEvents(
                [
                    ["created_at": Self.inside, "project_id": 7],
                    ["created_at": Self.inside, "project_id": 7],
                    ["created_at": Self.after, "project_id": 8],
                ], bounds: Self.bounds),
            [7: 2])
    }

    func testAnEventWithNoProjectIsSkippedRatherThanLosingTheCount() throws {
        XCTAssertEqual(
            try ForgeRepositoryFeed.tallyEvents(
                [
                    ["created_at": Self.inside, "project_id": 7],
                    ["created_at": Self.inside, "project_id": NSNull()],
                ], bounds: Self.bounds),
            [7: 1])
    }

    func testAnInstanceServedUnderAPathIsAskedWithoutIt() {
        let remote = ForgeRepositoryID(host: "example.com", fullName: "gitlab/group/proj")

        XCTAssertEqual(
            ForgeRepositoryFeed.onForge(remote, basePath: "/gitlab").fullName, "group/proj")
        XCTAssertEqual(ForgeRepositoryFeed.onForge(remote, basePath: nil), remote)
        XCTAssertEqual(ForgeRepositoryFeed.onForge(remote, basePath: "/other"), remote)
    }

    func testTwoSpellingsOfOneProjectBothGetTheAnswer() {
        let long = ForgeRepositoryID(host: "example.com", fullName: "gitlab/group/proj")
        let short = ForgeRepositoryID(host: "example.com", fullName: "group/proj")
        let figures = ForgeRepositoryCounts(merged: 2)

        let answers = ForgeRepositoryFeed.answers(
            [short: figures], for: [long, short], basePath: "/gitlab")

        XCTAssertEqual(answers, [long: figures, short: figures])
    }

    func testAVendorsOwnPageDrawsNoCounters() {
        let id = ForgeRepositoryID(host: "github.com", fullName: "xsmyile/sissy")
        let reading = ForgeRepositoryReading(
            kind: .gitHub, host: "github.com", counts: [id: ForgeRepositoryCounts(merged: 4)])
        let page = { (provider: String?) in
            UsagePanelSnapshot.ProjectsPage(
                provider: provider, rows: [self.row("sissy")], residue: nil, subtitle: "")
        }

        XCTAssertNotNil(UsagePanelSnapshot.projectCounters(page(nil), readings: [reading])["/sissy"])
        XCTAssertTrue(UsagePanelSnapshot.projectCounters(page("claude-code"), readings: [reading]).isEmpty)
    }

    /// Two instances on one host each answer for every repository on it, so the
    /// row takes the one that actually has the work.
    func testTwoInstancesOnOneHostAnswerWithTheOneThatHasTheRepository() {
        let id = ForgeRepositoryID(host: "github.com", fullName: "xsmyile/sissy")
        let counters = UsagePanelSnapshot.projectCounters(
            [row("sissy")],
            readings: [
                ForgeRepositoryReading(
                    kind: .gitHub, host: "github.com",
                    counts: [id: ForgeRepositoryCounts(merged: 0, issues: 0, comments: 0)]),
                ForgeRepositoryReading(
                    kind: .gitHub, host: "github.com",
                    counts: [id: ForgeRepositoryCounts(merged: 4, issues: 0, comments: 0)]),
            ])

        XCTAssertEqual(counters["/sissy"]?.first?.figure, "4")
    }

    func testAReadingThatLostACounterIsAskedAgainRatherThanCached() async throws {
        let calls = LockedValue(0)
        let sissy = ForgeRepositoryID(host: "github.com", fullName: "xsmyile/sissy")
        let monitor = ForgeActivityMonitor(
            connections: [ForgeConnection(kind: .gitHub, host: "github.com")],
            token: { _, _ in .found("fixture") })
        let fetch: ForgeActivityMonitor.RepositoryFetch = { _, _, _, _ in
            calls.update { $0 += 1 }
            return [sissy: ForgeRepositoryCounts(merged: nil, issues: 1)]
        }

        for _ in 0..<2 {
            _ = try await monitor.readRepositories(
                [sissy], from: Self.start, to: Self.start, now: Self.end, fetch: fetch)
        }

        XCTAssertEqual(calls.load(), 2)
    }

    func testARemoteKeepsItsWholePathForTheForge() throws {
        let nested = try XCTUnwrap(
            ProjectResolver.remote(ofRemoteURL: "git@gitlab.example.com:group/sub/repo.git"))

        XCTAssertEqual(nested.fullName, "group/sub/repo")
        XCTAssertEqual(nested.owner, "sub")
    }

    private func row(_ name: String, host: String = "github.com") -> UsagePanelSnapshot.ProjectRow {
        UsagePanelSnapshot.ProjectRow(
            id: "/\(name)", name: name, owner: "xsmyile",
            repository: .init(label: "xsmyile/\(name)", host: host, fullName: "xsmyile/\(name)", page: nil),
            tooltip: nil, tokens: "1", cost: "$1", share: 1, providers: [])
    }

    func testOnlyWhatHappenedIsDrawn() {
        let reading = ForgeRepositoryReading(
            kind: .gitHub, host: "github.com",
            counts: [
                ForgeRepositoryID(host: "github.com", fullName: "xsmyile/sissy"):
                    ForgeRepositoryCounts(merged: 36, issues: 0, comments: nil),
                ForgeRepositoryID(host: "github.com", fullName: "xsmyile/mizuhub"):
                    ForgeRepositoryCounts(merged: 0, issues: 0, comments: 0),
            ])

        let counters = UsagePanelSnapshot.projectCounters(
            [row("sissy"), row("mizuhub"), row("other", host: "gitlab.example.com")],
            readings: [reading])

        XCTAssertEqual(counters["/sissy"]?.map(\.counter), [.merged])
        XCTAssertEqual(counters["/sissy"]?.first?.figure, "36")
        XCTAssertNil(counters["/mizuhub"], "a quiet repository keeps the height it has")
        XCTAssertNil(counters["/other"])
    }

    func testEachConnectionIsAskedOnlyAboutItsHostAndTheAnswerIsCached() async throws {
        let calls = LockedValue(0)
        let sissy = ForgeRepositoryID(host: "github.com", fullName: "xsmyile/sissy")
        let monitor = ForgeActivityMonitor(
            connections: [
                ForgeConnection(kind: .gitHub, host: "github.com"),
                ForgeConnection(kind: .gitLab, host: "gitlab.example.com"),
            ],
            token: { _, _ in .found("fixture") })
        let fetch: ForgeActivityMonitor.RepositoryFetch = { connection, _, _, query in
            calls.update { $0 += 1 }
            XCTAssertEqual(connection.host, "github.com")
            XCTAssertEqual(query.repositories, [sissy])
            return [sissy: ForgeRepositoryCounts(merged: 1, issues: 0)]
        }

        let first = try await monitor.readRepositories(
            [sissy], from: Self.start, to: Self.start, now: Self.end, fetch: fetch)
        let second = try await monitor.readRepositories(
            [sissy], from: Self.start, to: Self.start, now: Self.end.addingTimeInterval(1), fetch: fetch)

        XCTAssertEqual(first.map(\.host), ["github.com"])
        XCTAssertEqual(first.first?.counts[sissy]?.merged, 1)
        XCTAssertEqual(second, first)
        XCTAssertEqual(calls.load(), 1)
    }
}
