import Foundation

/// A git forge Sissy can read an activity count from.
///
/// Two, because two is what the panel's project rows already mark: `ForgeMark`
/// matches a host *containing* `github` or `gitlab`, so a self-hosted GitLab is
/// the ordinary case rather than the exception. A third forge is a reader in
/// `ForgeActivityFeed` and a case here, not a redesign — nothing below this switches on the count
/// itself, only on which reader produces it.
enum ForgeKind: String, Sendable, Codable, Equatable, CaseIterable {
    case gitHub = "github"
    case gitLab = "gitlab"

    /// The vendor's own hosted instance, which is what the connect sheet's
    /// host field holds until the user types another. Picking a forge resets
    /// the field to it, so a GitLab token is never sent to `github.com`
    /// because the field still held the other forge's host.
    var defaultHost: String {
        switch self {
        case .gitHub: GitHubActivityFeed.dotComHost
        case .gitLab: GitLabActivityFeed.dotComHost
        }
    }
}

/// One of the readings a forge row carries beside its contribution total.
///
/// The contribution total is deliberately not among them: it is the section's
/// own figure, so a row with it switched off would be a row of nothing under
/// a heading that is about it. These are the ones a user may not care
/// about — and switching one off is not only a rendering choice, because a
/// reading nobody looks at must not be fetched either. On GitHub the three
/// counters change nothing but the size of a reply already being made; on
/// GitLab each of them is four requests a poll. `latest` is the one that is not
/// a count: GitHub answers it with a request of its own, GitLab with one more.
enum ForgeCounter: String, Sendable, Codable, CaseIterable {
    case merged
    case issues
    case comments
    /// The newest thing the account did on the forge, as `ForgeEvent`.
    case latest

    /// Every counter, which is what a build with nothing configured reads.
    static let all = Set(allCases)
}

/// What one forge account did, per period, in the vendor's own arithmetic.
///
/// **The figures are the vendor's and are never summed across vendors.**
/// GitHub answers with its own contribution-graph total — measured 2026-09-17,
/// 128 for a day whose itemised commits, issues and pull requests came to 56,
/// the other 72 being `restrictedContributionsCount`, the private-repository
/// work the breakdown will not name. GitLab has no equivalent Sissy can read:
/// its `users/<name>/calendar.json` answered 200 with `{}` on a self-hosted
/// 19.3 instance the same day, so the count here is the number of events
/// GitLab recorded for the user, which is push, merge-request, issue and
/// comment activity. Two vendors counting two things is two readings; adding
/// them would invent a third, which is the rule `ProviderCredits` already
/// holds for money in two currencies.
///
/// A period is absent rather than zero when it could not be read. The whole
/// reading fails together in practice — one request answers every period — but
/// a vendor that starts refusing one window must not report it as a quiet day.
struct ForgeActivity: Sendable, Equatable {
    /// The vendor's own activity total, by the window the panel is showing.
    let contributions: [UsagePeriod: Int]
    /// Pull requests or merge requests this account authored and had merged in
    /// the window. Authored rather than merged-by: it is the figure the user
    /// recognises from their own profile, and "merged by me" on a team counts
    /// other people's work.
    let merged: [UsagePeriod: Int]
    /// Issues this account opened in the window.
    ///
    /// Opened rather than open: every other figure on the row is something
    /// that happened inside the window the control names, and a count of what
    /// is open right now would be the one reading on the block that did not
    /// move when the window did. What is still on this account's plate is a
    /// state, and a state belongs beside the work rather than inside a period.
    ///
    /// Read from each vendor's own search rather than from the contribution
    /// breakdown beside it: measured 2026-09-17, GitHub's
    /// `totalIssueContributions` answered 2 for a day whose search answered 7,
    /// the difference being the private repositories the breakdown folds into
    /// `restrictedContributionsCount` without itemising.
    let issues: [UsagePeriod: Int]
    /// Comments this account wrote in the window.
    ///
    /// **Neither forge publishes this as a count, and the two stand in
    /// opposite relations to the figure beside them.** A comment is an event
    /// GitLab records, so it comes off the same `/api/v4/events` header the
    /// contributions do and is a *breakdown* of that number — measured
    /// 2026-09-18, 14 of one week's 525 events. GitHub counts no comment as a
    /// contribution at all: measured the same day, 2026-08-07 read 14
    /// contributions against a breakdown of 14 commits and nothing else, on a
    /// day that carried a comment, and 2026-08-24 read 23 against 20+1+2 on
    /// another. So there the figure is disjoint from its neighbour, and it is
    /// counted from the comments themselves — see
    /// `GitHubActivityFeed.commentCounts`, which is also why a GitHub window
    /// can be absent here while the three beside it are answered.
    ///
    /// What neither vendor can be asked for is the same set: GitHub's covers
    /// comments on issues and on pull request conversations (measured, 86 and
    /// 14 of one page of 100) and cannot reach review comments left on a diff,
    /// there being no connection on `User` that returns them. GitLab's is
    /// whatever it filed under `commented`. Two vendors counting two things is
    /// two readings, which is the rule this whole type is already on.
    let comments: [UsagePeriod: Int]
    /// Whether `contributions[.all]` is the vendor's whole record or a year of
    /// it. GitHub's contributions query takes a range and refuses one wider
    /// than a year, so `all` there is the last twelve months while `merged`
    /// beside it is every one ever — a difference the row has to be able to
    /// say, since `All` is the one window a user reads as "everything".
    let contributionsBoundedToOneYear: Bool
    /// The windows whose contribution figure is a floor rather than a count.
    ///
    /// GitLab stops counting at `GitLabActivityFeed.countCeiling`: past it the
    /// events endpoint answers without `x-total`, so the widest window of an
    /// account that has worked for months used to come back with no figure at
    /// all. The ceiling is what the reply still proves, and the row says so as
    /// `10k+` rather than a dash.
    var contributionsAtLeast: Set<UsagePeriod> = []
    /// The same, for the comment count, which comes off the same header.
    var commentsAtLeast: Set<UsagePeriod> = []

    static let empty = Self(
        contributions: [:], merged: [:], issues: [:], comments: [:],
        contributionsBoundedToOneYear: false)
}

/// The newest thing an account did on its forge, out of the vendor's own event
/// feed.
///
/// **A state rather than a count, so it follows no window.** Every figure
/// beside it is over the period the header names; this is the last push,
/// request or comment whenever it happened, and the row dates it instead.
///
/// **Five verbs for both vendors, in the vendor's own reference.** GitHub files
/// `PushEvent`, `PullRequestEvent`, `IssuesEvent` and the comment and review
/// events; GitLab files `pushed to`, `opened`, `accepted`, `commented on` and
/// `approved`. Both come down to the same five actions, so a row reads the same
/// whichever forge it is on, while `target` keeps each vendor's own name for the
/// thing: `#290` for a GitHub pull request, `!41` for a GitLab merge request, a
/// branch for a push. What neither is taken for is the rest of the feed —
/// measured 2026-09-28, the newest GitLab event of the day was a branch
/// `deleted` after its merge, and GitHub files a `CreateEvent` and a
/// `DeleteEvent` around every pull request, none of which is work.
struct ForgeEvent: Sendable, Equatable {
    enum Action: Sendable, Equatable {
        case pushed
        case opened
        case merged
        case openedIssue
        case commented
        case reviewed
    }

    let action: Action
    /// The branch a push went to, or the request or issue acted on in the
    /// vendor's own notation. Nil where the vendor named neither.
    let target: String?
    /// The repository's own short name, nil where the vendor did not say.
    let repository: String?
    /// When the vendor says it happened.
    let at: Date

    /// The newest of `events`, by the vendor's own stamp rather than by feed
    /// order.
    ///
    /// **Not the first row.** Measured 2026-09-28 on GitHub's user feed, a
    /// push stamped 10:34 UTC was listed second, above a merge at 21:08 and a
    /// push at 21:07: the feed is filed as events are processed, and GitHub
    /// processes some hours late. The newest stamp is what the row is about.
    static func newest(_ events: [Self]) -> Self? {
        events.max { $0.at < $1.at }
    }

    /// What a fresh reading's event and the one already on the row come to.
    ///
    /// **The request that reads it can fail while the counters do not**, and
    /// a reading that arrives replaces the one before it whole. Taken as it
    /// came, a feed that answered `5xx` once, or a GitLab project lookup that
    /// timed out, took the line off the row, or its repository off the line,
    /// for one poll in every such round. So the newer stamp wins, the row's
    /// event stands where the fresh one is missing or older, which is also a
    /// GitHub feed filing late, and a fresh event that is the same one without
    /// its repository keeps the name the row already had.
    static func merged(_ fresh: Self?, over previous: Self?) -> Self? {
        guard let fresh else { return previous }
        guard let previous else { return fresh }
        if previous.at > fresh.at { return previous }
        let same =
            previous.at == fresh.at && previous.action == fresh.action
            && previous.target == fresh.target
        return same && fresh.repository == nil ? fresh.named(previous.repository) : fresh
    }

    /// A tag as a push target names it, the same on both forges.
    static func tag(_ name: String) -> String { "tag " + name }

    /// The same event with the repository a later request named, keeping the
    /// one it had where that request named none.
    func named(_ name: String?) -> Self {
        Self(action: action, target: target, repository: name ?? repository, at: at)
    }
}

/// One forge connection's last reading, or the fact that there is not one.
///
/// The login is on the reading rather than on the connection, and that is the
/// measured half of this type: measured 2026-09-17, `~/.config/gh/hosts.yml`
/// named one account while the token in `gh`'s own keychain item answered as a
/// different one. A username taken from a CLI's configuration is therefore a
/// guess about whose numbers these are, where the one the API answers with is
/// the account that produced them. It is also why the row prints it: it is the
/// only thing on the line that says whose figures those are.
struct ForgeActivityReading: Sendable, Equatable, Identifiable {
    /// The connection this answers for, which is its `ForgeConnection.id`.
    let id: String
    let kind: ForgeKind
    /// The connection's `ForgeConnection.address`: the host, with the port
    /// and path an instance off the default needs to be told apart by.
    let host: String
    /// Who the token turned out to belong to, nil for a connection that has
    /// never answered.
    let login: String?
    let activity: ForgeActivity
    /// When Sissy read it, never a stamp from the payload. The same rule
    /// `ProviderStatusMonitor` follows: a vendor's own timestamp moves on
    /// events rather than on polls, so dating a row from it tells a healthy
    /// account it has not been heard from in months.
    let readAt: Date
    /// Why there is no current figure, nil on a reading that worked.
    ///
    /// A reading that has failed keeps whatever it last had — the age growing
    /// is the signal — so this sits beside the figures rather than replacing
    /// them, and a row with both says what it knows and how old it is.
    let failure: ForgeReadFailure?
    /// The newest thing the account did, nil where it is switched off, the
    /// feed held nothing worth naming, or the feed could not be read.
    ///
    /// Absent rather than a failure of the reading: it rides a request of its
    /// own, and a feed that would not answer must not throw away the counters
    /// the document before it already carried. A failed round keeps the
    /// previous one along with the figures, for the reason those are kept.
    var latest: ForgeEvent?

    /// A connection that has answered nothing at all. Distinct from a zero:
    /// a day with no contributions is a reading, and this is the absence of
    /// one, so the row prints why instead of `0`.
    static func unavailable(
        _ connection: ForgeConnection, failure: ForgeReadFailure, at when: Date = Date()
    ) -> Self {
        Self(
            id: connection.id, kind: connection.kind, host: connection.address, login: nil,
            activity: .empty, readAt: when, failure: failure)
    }

    /// Whether a fetch has ever worked for this connection, which is what
    /// makes `readAt` an age rather than a timestamp.
    ///
    /// The login is the evidence: it is the account the vendor answered as, so
    /// only a reading that arrived carries one, and a failure keeps the
    /// previous one along with the figures. It has to be asked, because
    /// `unavailable` stamps `readAt` with the attempt — and re-stamps it every
    /// round until one works — so a row built from it would say a connection
    /// that has never once answered was read a moment ago.
    var hasEverRead: Bool { login != nil }

    /// Whether this reading has a figure for the window the panel is showing.
    /// A connection whose token was accepted but whose window came back empty
    /// is still a reading; one that never answered is not.
    func hasFigures(for period: UsagePeriod) -> Bool {
        contributions(for: period) != nil || merged(for: period) != nil
            || issues(for: period) != nil || comments(for: period) != nil
    }

    func contributions(for period: UsagePeriod) -> Int? { activity.contributions[period] }
    /// Whether `contributions(for:)` is a floor the vendor stopped counting
    /// at rather than the whole count.
    func contributionsAreAFloor(for period: UsagePeriod) -> Bool {
        activity.contributionsAtLeast.contains(period)
    }
    /// Whether `comments(for:)` is a floor rather than the whole count.
    func commentsAreAFloor(for period: UsagePeriod) -> Bool {
        activity.commentsAtLeast.contains(period)
    }
    func merged(for period: UsagePeriod) -> Int? { activity.merged[period] }
    func issues(for period: UsagePeriod) -> Int? { activity.issues[period] }
    func comments(for period: UsagePeriod) -> Int? { activity.comments[period] }
}

/// Why a forge would not answer.
///
/// Worded rather than a status code, because every one of these has a different
/// thing the user can do about it and the row is where they read it. The
/// vendor's refusal is kept separate from a network that could not be reached:
/// this user's own GitLab resolves publicly and routes over a tunnel interface
/// (measured 2026-09-17), so "off the VPN" is an ordinary daily state
/// and must never render as a quiet day.
enum ForgeReadFailure: Error, Sendable, Equatable {
    /// The token was refused. A connection in this state is not retried on the
    /// ordinary cadence — there is nothing to wait for but a new token.
    case unauthorized
    /// The vendor asked for less traffic.
    case rateLimited
    /// The host could not be reached at all.
    case unreachable
    /// It answered, with something this build cannot read.
    case malformed
    /// The forge sent the request to another host, which either refused it or
    /// was not followed. `SissyHTTP` drops the token on the way off the
    /// origin, so a refusal there says nothing about the token, and reported
    /// as `unauthorized` it would park a connection behind a replacement the
    /// user does not need. An SSO proxy in front of a self-hosted forge is the
    /// case this names.
    case redirected
    /// There is no token filed for this connection.
    case noCredential
    /// There is one and the keychain would not hand it over.
    ///
    /// Its own case rather than `noCredential`, and the distinction is the one
    /// `AGENTS.md` records for the Claude credential: a suppressed read of an
    /// item whose grant has gone stale answers without anybody having been
    /// asked, and that happens on every re-signed build. Reported as a missing
    /// token it would park a connection that is working and leave no way back
    /// but re-pasting a token that was never the problem.
    case credentialUnreadable

    /// Whether polling again on the ordinary cadence can change the answer.
    ///
    /// A refused token and a missing one both need the user — reconnecting the
    /// host is what replaces either — so the loop stops spending a request on
    /// them every five minutes. Everything else is worth asking again,
    /// including a keychain that would not answer: the grant can come back
    /// without the user doing anything at all.
    var needsTheUser: Bool {
        switch self {
        case .unauthorized, .noCredential: true
        case .rateLimited, .unreachable, .malformed, .redirected, .credentialUnreadable: false
        }
    }
}
