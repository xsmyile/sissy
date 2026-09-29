import XCTest

@testable import Sissy

/// The latest event each forge reader takes out of its vendor's feed, and the
/// line the row words it as.
///
/// The rows below are trimmed from the real feeds, read 2026-09-28 from
/// `api.github.com/users/<login>/events` and a self-hosted GitLab 19.3's
/// `/api/v4/events`: the keys and the shapes are the ones those replies carry,
/// down to the pull request GitHub trims to its number on a merge.
final class ForgeEventTests: XCTestCase {
    private static func rows(_ json: String) throws -> [[String: Any]] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    }

    private static func instant(_ text: String) throws -> Date {
        try XCTUnwrap(UsageReaderShared.parseTimestamp(text))
    }

    // MARK: GitHub

    /// The feed as it was read: newest-processed first, which is not newest
    /// first, with the branch bookkeeping around a pull request in between.
    private static let gitHubFeed = """
        [
        {"type":"PullRequestEvent","created_at":"2026-09-28T21:24:12Z",
         "repo":{"name":"xsmyile/sissy"},"payload":{"action":"opened","number":290,
         "pull_request":{"number":290}}},
        {"type":"PushEvent","created_at":"2026-09-28T10:34:21Z",
         "repo":{"name":"radonforge/try-on-buddy"},
         "payload":{"ref":"refs/heads/ios-edit-profile","head":"bbe37f3"}},
        {"type":"DeleteEvent","created_at":"2026-09-28T21:30:00Z",
         "repo":{"name":"xsmyile/sissy"},"payload":{"ref":"tagline-rethink","ref_type":"branch"}},
        {"type":"CreateEvent","created_at":"2026-09-28T21:29:00Z",
         "repo":{"name":"xsmyile/sissy"},"payload":{"ref":"forge-sections","ref_type":"branch"}}
        ]
        """

    /// **The newest by the vendor's stamp, never the first row**, and never a
    /// branch created or deleted, which is bookkeeping rather than work.
    func testGitHubTakesTheNewestWorkByStampRatherThanByFeedOrder() throws {
        let events = try Self.rows(Self.gitHubFeed).compactMap(GitHubActivityFeed.event)
        XCTAssertEqual(events.count, 2)
        let newest = try XCTUnwrap(ForgeEvent.newest(events))
        XCTAssertEqual(newest.action, .opened)
        XCTAssertEqual(newest.target, "#290")
        XCTAssertEqual(newest.repository, "sissy")
        XCTAssertEqual(newest.at, try Self.instant("2026-09-28T21:24:12Z"))
    }

    /// The feed files a merge two ways: the `merged` action it was measured
    /// answering with, and the documented `closed` with the flag on the pull
    /// request. A `closed` without the flag is a request closed unmerged.
    func testGitHubReadsAMergeInEitherShapeAndNotAClosedRequest() throws {
        let rows = try Self.rows(
            """
            [
            {"type":"PullRequestEvent","created_at":"2026-09-28T21:08:14Z",
             "repo":{"name":"radonforge/morphy.lol"},
             "payload":{"action":"merged","number":41,"pull_request":{"number":41}}},
            {"type":"PullRequestEvent","created_at":"2026-09-28T21:09:00Z",
             "repo":{"name":"radonforge/morphy.lol"},
             "payload":{"action":"closed","number":42,"pull_request":{"number":42,"merged":true}}},
            {"type":"PullRequestEvent","created_at":"2026-09-28T21:10:00Z",
             "repo":{"name":"radonforge/morphy.lol"},
             "payload":{"action":"closed","number":43,"pull_request":{"number":43}}}
            ]
            """)
        let events = rows.map(GitHubActivityFeed.event)
        XCTAssertEqual(events[0]?.action, .merged)
        XCTAssertEqual(events[0]?.target, "#41")
        XCTAssertEqual(events[1]?.action, .merged)
        XCTAssertEqual(events[1]?.target, "#42")
        XCTAssertNil(events[2])
    }

    /// A comment on a pull request's conversation is filed against its issue,
    /// and a review comment against the pull request; both read as the number
    /// the user would type.
    func testGitHubCommentsAndReviewsNameWhatTheyWereLeftOn() throws {
        let rows = try Self.rows(
            """
            [
            {"type":"IssueCommentEvent","created_at":"2026-09-28T09:00:00Z",
             "repo":{"name":"xsmyile/sissy"},"payload":{"action":"created","issue":{"number":102}}},
            {"type":"PullRequestReviewCommentEvent","created_at":"2026-09-28T09:01:00Z",
             "repo":{"name":"xsmyile/sissy"},
             "payload":{"action":"created","pull_request":{"number":286}}},
            {"type":"PullRequestReviewEvent","created_at":"2026-09-28T09:02:00Z",
             "repo":{"name":"xsmyile/sissy"},
             "payload":{"action":"created","pull_request":{"number":286}}},
            {"type":"IssuesEvent","created_at":"2026-09-28T09:03:00Z",
             "repo":{"name":"xsmyile/sissy"},"payload":{"action":"opened","issue":{"number":492}}},
            {"type":"IssuesEvent","created_at":"2026-09-28T09:04:00Z",
             "repo":{"name":"xsmyile/sissy"},"payload":{"action":"labeled","issue":{"number":492}}},
            {"type":"PullRequestReviewEvent","created_at":"2026-09-28T09:05:00Z",
             "repo":{"name":"xsmyile/sissy"},
             "payload":{"action":"dismissed","pull_request":{"number":286}}}
            ]
            """)
        let events = rows.map(GitHubActivityFeed.event)
        XCTAssertEqual(events[0]?.action, .commented)
        XCTAssertEqual(events[0]?.target, "#102")
        XCTAssertEqual(events[1]?.action, .commented)
        XCTAssertEqual(events[1]?.target, "#286")
        XCTAssertEqual(events[2]?.action, .reviewed)
        XCTAssertEqual(events[3]?.action, .openedIssue)
        XCTAssertEqual(events[3]?.target, "#492")
        XCTAssertNil(events[4], "a label is not work")
        XCTAssertNil(events[5], "a dismissed review is not one the account left")
    }

    /// A push names its branch, not its ref; a tag is named as one, which is
    /// what tells it apart from a branch of the same name.
    func testGitHubAPushNamesItsBranch() throws {
        let rows = try Self.rows(
            """
            [
            {"type":"PushEvent","created_at":"2026-09-28T20:51:46Z",
             "repo":{"name":"xsmyile/sissy"},"payload":{"ref":"refs/heads/master"}},
            {"type":"PushEvent","created_at":"2026-09-28T20:52:00Z",
             "repo":{"name":"xsmyile/sissy"},"payload":{"ref":"refs/tags/v0.2.9"}}
            ]
            """)
        let events = rows.map(GitHubActivityFeed.event)
        XCTAssertEqual(events[0]?.action, .pushed)
        XCTAssertEqual(events[0]?.target, "master")
        XCTAssertEqual(events[1]?.target, "tag v0.2.9")
    }

    /// `github.com` answers on its own API host; an Enterprise install under
    /// `/api/v3` on the host itself, which is the REST half of the rule the
    /// GraphQL endpoint is on.
    func testGitHubEventsURLFollowsTheHost() throws {
        let dotCom = try XCTUnwrap(
            GitHubActivityFeed.eventsURL(.gitHub(host: "github.com"), login: "xsmyile"))
        XCTAssertEqual(
            dotCom.absoluteString, "https://api.github.com/users/xsmyile/events?per_page=100")
        let enterprise = try XCTUnwrap(
            GitHubActivityFeed.eventsURL(.gitHub(host: "github.example.com"), login: "xsmyile"))
        XCTAssertEqual(
            enterprise.absoluteString,
            "https://github.example.com/api/v3/users/xsmyile/events?per_page=100")
    }

    // MARK: GitLab

    /// The feed around a merge as 19.3 files it: the branch deleted after the
    /// merge is the newest row, and it is not work.
    private static let gitLabFeed = """
        [
        {"action_name":"deleted","created_at":"2026-09-28T19:15:36.611Z","project_id":562,
         "target_type":"Project","target_iid":562,"target_title":"geweb",
         "push_data":{"action":"removed","ref_type":"branch","ref":"fix/test","commit_count":0}},
        {"action_name":"pushed to","created_at":"2026-09-28T19:15:35.034Z","project_id":562,
         "target_type":"Project","target_iid":562,"target_title":"geweb",
         "push_data":{"action":"pushed","ref_type":"branch","ref":"next","commit_count":2}},
        {"action_name":"accepted","created_at":"2026-09-28T19:15:34.927Z","project_id":562,
         "target_type":"MergeRequest","target_iid":16,"target_title":"test: fissata l'ora"}
        ]
        """

    func testGitLabSkipsTheDeletedBranchAndTakesTheNewestWork() throws {
        let body = Data(Self.gitLabFeed.utf8)
        let newest = try XCTUnwrap(GitLabActivityFeed.latest(in: body))
        XCTAssertEqual(newest.event.action, .pushed)
        XCTAssertEqual(newest.event.target, "next")
        XCTAssertNil(newest.event.repository, "the feed names the project by number")
        XCTAssertEqual(newest.project, 562)
    }

    /// `target_iid` is the request only on a request's own row: a push files
    /// the project's id there and a comment the note's, so a comment is read
    /// through the note it carries.
    func testGitLabNamesRequestsAndCommentsInItsOwnNotation() throws {
        let rows = try Self.rows(
            """
            [
            {"action_name":"accepted","created_at":"2026-09-28T19:15:34Z","project_id":562,
             "target_type":"MergeRequest","target_iid":16},
            {"action_name":"opened","created_at":"2026-09-28T19:00:00Z","project_id":562,
             "target_type":"Issue","target_iid":1},
            {"action_name":"commented on","created_at":"2026-09-28T18:00:00Z","project_id":562,
             "target_type":"Note","target_iid":15360,
             "note":{"noteable_type":"MergeRequest","noteable_iid":2}},
            {"action_name":"approved","created_at":"2026-09-28T17:00:00Z","project_id":562,
             "target_type":"MergeRequest","target_iid":16},
            {"action_name":"closed","created_at":"2026-09-28T16:00:00Z","project_id":562,
             "target_type":"Issue","target_iid":168}
            ]
            """)
        let events = rows.map { GitLabActivityFeed.event($0)?.event }
        XCTAssertEqual(events[0]?.action, .merged)
        XCTAssertEqual(events[0]?.target, "!16")
        XCTAssertEqual(events[1]?.action, .openedIssue)
        XCTAssertEqual(events[1]?.target, "#1")
        XCTAssertEqual(events[2]?.action, .commented)
        XCTAssertEqual(events[2]?.target, "!2")
        XCTAssertEqual(events[3]?.action, .reviewed)
        XCTAssertNil(events[4])
    }

    /// A tag push reads as GitHub's does, rather than as a branch of the name.
    func testGitLabNamesATagPushAsATag() throws {
        let rows = try Self.rows(
            """
            [{"action_name":"pushed new","created_at":"2026-09-28T19:00:00Z","project_id":562,
              "target_type":"Project","target_iid":562,
              "push_data":{"action":"created","ref_type":"tag","ref":"v1.4.0","commit_count":0}}]
            """)
        XCTAssertEqual(GitLabActivityFeed.event(rows[0])?.event.target, "tag v1.4.0")
    }

    // MARK: Across polls

    private static func event(at text: String, repository: String? = "sissy") throws -> ForgeEvent {
        ForgeEvent(action: .pushed, target: "master", repository: repository, at: try instant(text))
    }

    /// A feed that failed, or filed late, leaves the row's event standing
    /// rather than taking the line off or putting an older one back.
    func testTheRowsEventStandsAgainstAMissingOrOlderOne() throws {
        let row = try Self.event(at: "2026-09-28T21:00:00Z")
        let older = try Self.event(at: "2026-09-28T10:00:00Z")
        XCTAssertEqual(ForgeEvent.merged(nil, over: row), row)
        XCTAssertEqual(ForgeEvent.merged(older, over: row), row)
        let newer = try Self.event(at: "2026-09-28T22:00:00Z")
        XCTAssertEqual(ForgeEvent.merged(newer, over: row), newer)
        XCTAssertEqual(ForgeEvent.merged(newer, over: nil), newer)
    }

    /// The same event arriving without its repository, a GitLab project
    /// lookup that failed, keeps the name the row already had.
    func testTheSameEventWithoutItsRepositoryKeepsTheRowsName() throws {
        let row = try Self.event(at: "2026-09-28T21:00:00Z", repository: "geweb")
        let unnamed = try Self.event(at: "2026-09-28T21:00:00Z", repository: nil)
        XCTAssertEqual(ForgeEvent.merged(unnamed, over: row)?.repository, "geweb")
    }

    /// The feed rides the widest window's own header read, so asking for it
    /// is a longer page on a request already made, never a request of its own.
    func testGitLabAsksForAPageOnlyWhereTheFeedIsWanted() throws {
        let gitLab = ForgeConnection(kind: .gitLab, host: "gitlab.example.com")
        let now = try Self.instant("2026-09-28T12:00:00Z")
        let page = try XCTUnwrap(
            GitLabActivityFeed.eventsURL(
                gitLab, period: .all, now: now, rows: GitLabActivityFeed.latestPage))
        XCTAssertTrue(page.absoluteString.contains("per_page=\(GitLabActivityFeed.latestPage)"))
        let count = try XCTUnwrap(GitLabActivityFeed.eventsURL(gitLab, period: .all, now: now))
        XCTAssertTrue(count.absoluteString.contains("per_page=1"))
        XCTAssertEqual(
            GitLabActivityFeed.projectURL(gitLab, id: 562)?.absoluteString,
            "https://gitlab.example.com/api/v4/projects/562")
    }

    /// A project the second request could not name keeps what the event had.
    func testANameThatDidNotArriveKeepsTheOneTheEventHad() throws {
        let at = try Self.instant("2026-09-28T12:00:00Z")
        let event = ForgeEvent(action: .pushed, target: "next", repository: "geweb", at: at)
        XCTAssertEqual(event.named(nil).repository, "geweb")
        XCTAssertEqual(event.named("tanuki").repository, "tanuki")
    }

    // MARK: Wording

    /// Both forges' events read in one vocabulary, in the vendor's own
    /// reference, and a verb with nothing to name stands alone.
    func testTheLineReadsTheSameOnEitherForge() throws {
        let now = try Self.instant("2026-09-28T12:00:00Z")
        let minutes = { (count: Double) in now.addingTimeInterval(-count * 60) }
        let line = { (event: ForgeEvent) in
            UsageFormat.forgeEventDone(event) + UsageFormat.forgeEventTail(event, now: now)
        }
        XCTAssertEqual(
            line(
                ForgeEvent(action: .pushed, target: "next", repository: "tanuki", at: minutes(25))),
            "pushed to next · tanuki · 25m ago")
        XCTAssertEqual(
            line(
                ForgeEvent(action: .merged, target: "!41", repository: "tanuki", at: minutes(3))),
            "merged !41 · tanuki · 3m ago")
        XCTAssertEqual(
            line(
                ForgeEvent(action: .opened, target: "#290", repository: "sissy", at: minutes(16))),
            "opened #290 · sissy · 16m ago")
        XCTAssertEqual(
            line(
                ForgeEvent(action: .commented, target: nil, repository: nil, at: minutes(0))),
            "commented · just now")
    }
}
