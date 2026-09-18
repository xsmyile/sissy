import Foundation

/// The windows the forge rows are read over, resolved the same way the archive
/// resolves its own.
///
/// One place for the arithmetic because the forge row sits under the money and
/// follows the same period control: a window that counted a different set of
/// days than the figure above it would put two answers under one label. The
/// rule is the archive's — the start is `days - 1` before the start of today,
/// inclusive, and `all` is unbounded.
enum ForgeWindow {
    static func start(of period: UsagePeriod, now: Date, calendar: Calendar = .current) -> Date? {
        guard let days = period.days else { return nil }
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: today) ?? today
    }

    /// A day in the `YYYY-MM-DD` form GitLab's `after` takes, in the **local**
    /// calendar.
    ///
    /// Local because `start` is a local start-of-day and this renders that same
    /// day, not the instant it happens to be in UTC. Formatting it in UTC put
    /// every window a day early east of Greenwich: measured, a start of
    /// 2026-09-17 00:00+02:00 rendered `2026-09-16`, which asks for a window
    /// one day wider than the one the money above it is over. The endpoint
    /// takes no time part, so a day in the user's own calendar is the closest
    /// this gets to the instant the rest of the block is over.
    /// `en_US_POSIX` so the digits are digits whatever the user's locale does
    /// to a calendar.
    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// The instant a vendor's own day bucket opens on the date a window starts
    /// on: that local date at midnight **UTC**.
    ///
    /// **Both forges count in whole UTC days, and neither takes an instant.**
    /// Measured 2026-09-17 from Europe/Rome, GitHub's `contributionCalendar`
    /// snaps `from` down to the start of the UTC day holding it, so a local
    /// midnight rendered as the instant it is — `2026-09-16T22:00:00Z` — bought
    /// the whole of the 16th: 326 contributions where the profile's own square
    /// for the 17th read 128, and 773 over seven days where the seven squares
    /// came to 704. Asked from `2026-09-17T00:00:00Z` it answers 128, and from
    /// noon or 23:00 on that same date it still answers 128, which is what
    /// proves the bucket is the day rather than the instant. It is also why the
    /// error is invisible at 30 days on some accounts and not others — it is
    /// worth whatever the extra day held, which was 0 on 2026-08-18 and 198 on
    /// 2026-09-16.
    ///
    /// So a window is named by its **date** and every figure on the row takes
    /// the same form, including the two that are genuinely instant filters:
    /// GitHub's `merged:>=` qualifier and GitLab's `mergedAfter` would
    /// otherwise sit on a window two hours wider than the contributions beside
    /// them — measured the same day, 156 merges against the 155 that fall in
    /// the seven UTC days the contribution figure is over. One row, one window,
    /// in the calendar the user is reading the heatmap in.
    ///
    /// The local date rather than the UTC one, because that is the day the user
    /// is having: west of Greenwich the two agree for most of the day and east
    /// of it the local date is the later one, and in both the square the
    /// heatmap labels with today's date is the UTC day of the same name.
    static func vendorDay(_ start: Date) -> String { day.string(from: start) + utcMidnight }

    /// The instant `vendorDay` names, as a date rather than as text.
    ///
    /// The one counter no forge will total is counted here instead of at the
    /// vendor, so it needs that same boundary as something comparable. It is
    /// **`vendorDay`'s own day, read back** rather than recomputed, which is
    /// the only construction under which the two cannot disagree.
    ///
    /// Recomputing it is what the obvious version did, and it was wrong on a
    /// Mac whose calendar is not Gregorian: taking `year`/`month`/`day` off
    /// `Calendar.current` and building a Gregorian date from them turned a
    /// Buddhist 2026-09-18 into a boundary in **2569**, which every comment
    /// falls before — so every bounded window reported 0 *and* looked proven
    /// doing it, since an oldest reading of 2026 duly precedes a boundary five
    /// centuries out. `day` pins its own calendar and locale for exactly this
    /// reason and this now inherits that rather than restating it.
    static func vendorInstant(_ start: Date) -> Date? { utcDay.date(from: day.string(from: start)) }

    /// `day`'s format read in UTC, which is what turns its local date into the
    /// midnight `Z` the query strings name.
    private static let utcDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let utcMidnight = "T00:00:00Z"
}

/// The field names the aliased documents use for each period.
///
/// Explicit rather than derived from the raw values, because those are also
/// what `server.json` and the archive's day files are keyed by: a period
/// renamed for the panel's sake must not silently rename a GraphQL alias and
/// leave both readers parsing a key nothing answers under.
enum ForgeAlias {
    static func contributions(_ period: UsagePeriod) -> String { "contrib" + suffix(period) }
    static func merged(_ period: UsagePeriod) -> String { "merged" + suffix(period) }
    static func issues(_ period: UsagePeriod) -> String { "issues" + suffix(period) }

    private static func suffix(_ period: UsagePeriod) -> String {
        switch period {
        case .today: "Today"
        case .sevenDays: "Week"
        case .thirtyDays: "Month"
        case .all: "All"
        }
    }
}

/// Reads one forge connection's activity counters.
///
/// **One request per poll where the vendor allows it, and never one per
/// repository.** Measured 2026-09-17 and re-measured 2026-09-18 with the
/// comment counter on: GitHub answers every period's contribution total,
/// merged-pull-request count, opened-issue count **and comment count** in a
/// single GraphQL document still costing 1 point of 5000 per hour — the
/// comments ride in as a page of the account's own, counted here rather than
/// at the vendor, so the fourth counter costs no request at all. GitLab takes
/// two GraphQL documents — the second only because the login the first returns
/// is what the root `issues` field filters on — plus two `x-total` header reads
/// per period, the activity total and the same filtered to `commented`, which
/// is ten small requests. A reader that asked per repository would be spending
/// a request on each of the thirty-odd repositories a real day touches, for
/// four numbers.
///
/// The failure vocabulary is `ForgeReadFailure` rather than HTTP's, because the
/// row has to say what the user can do about it and "the VPN is off" and "the
/// token was refused" are not the same sentence.
enum ForgeActivityFeed {
    static let requestTimeout: TimeInterval = 15
    /// What Sissy calls itself to a forge. A product token rather than a bare
    /// library default: GitHub's API documents that a request without one may
    /// be refused, and a reading that fails on a header is a reading nobody can
    /// diagnose from the row.
    static let userAgent = "Sissy"

    static func read(
        _ connection: ForgeConnection, token: String, now: Date = Date()
    ) async throws -> ForgeActivityReading {
        switch connection.kind {
        case .gitHub:
            return try await GitHubActivityFeed.read(connection, token: token, now: now)
        case .gitLab:
            return try await GitLabActivityFeed.read(connection, token: token, now: now)
        }
    }

    /// One JSON reply, or the reason there is not one.
    ///
    /// Every status the vendors answer with is mapped here rather than at each
    /// call site, so a 401 from GitHub and a 401 from GitLab reach the row as
    /// the same sentence.
    static func send(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ForgeReadFailure.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw ForgeReadFailure.malformed }
        switch http.statusCode {
        case 200:
            return (data, http)
        case 401, 403:
            // 403 is GitHub's own answer to an exhausted rate limit as well as
            // to a scope it will not serve, and the two are told apart by the
            // remaining count rather than by the code.
            throw exhausted(http) ? ForgeReadFailure.rateLimited : .unauthorized
        case 429:
            throw ForgeReadFailure.rateLimited
        default:
            throw ForgeReadFailure.malformed
        }
    }

    private static func exhausted(_ response: HTTPURLResponse) -> Bool {
        guard let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining") else {
            return false
        }
        return Int(remaining) == 0
    }

    static func request(_ url: URL, token: String, header: String, scheme: String?) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(scheme.map { "\($0) \(token)" } ?? token, forHTTPHeaderField: header)
        return request
    }

    /// A GraphQL document posted, with the document itself kept out of the log
    /// on failure: it carries no secret, but it does carry the account's own
    /// query and there is nothing a reader could do with it.
    ///
    /// **Anything the vendor told us goes in `variables`, never in the
    /// document.** GitLab has no "issues I authored" field on `currentUser`, so
    /// that count is asked through the root `issues(authorUsername:)` with a
    /// name the previous reply supplied — and a login spliced into a query
    /// string is a forge deciding what Sissy asks for. The dates are Sissy's
    /// own and stay inline.
    static func graphQL(
        _ url: URL, query: String, variables: [String: String] = [:], token: String,
        header: String, scheme: String?
    ) async throws -> [String: Any] {
        var request = request(url, token: token, header: header, scheme: scheme)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["query": query, "variables": variables])
        guard request.httpBody != nil else { throw ForgeReadFailure.malformed }
        let (data, _) = try await send(request)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ForgeReadFailure.malformed
        }
        // A GraphQL endpoint answers 200 for a query it refused, with the
        // reason in `errors` — so a document that came back without `data` is
        // an error however healthy the status line was.
        guard let payload = root["data"] as? [String: Any] else {
            throw Self.refusal(root) ?? ForgeReadFailure.malformed
        }
        return payload
    }

    /// The failure a GraphQL `errors` array names, where it names one this
    /// build knows. Anything else is malformed, which is the honest answer for
    /// a reply nobody here can act on.
    private static func refusal(_ root: [String: Any]) -> ForgeReadFailure? {
        guard let errors = root["errors"] as? [[String: Any]] else { return nil }
        let types = errors.compactMap { $0["type"] as? String }
        if types.contains("RATE_LIMITED") { return .rateLimited }
        if types.contains(where: { $0 == "FORBIDDEN" || $0 == "UNAUTHORIZED" }) {
            return .unauthorized
        }
        return nil
    }
}

/// GitHub's half: one GraphQL document for every figure on the row.
///
/// The contributions figure is `contributionCalendar.totalContributions`, which
/// is the number on the profile's own squares and therefore the one the user
/// recognises. It is deliberately not the sum of the breakdown beside it —
/// measured 2026-09-17, the calendar read 115 for a day whose commit, pull
/// request and issue counts came to 44, the difference being contributions to
/// private repositories the breakdown does not itemise.
///
/// `all` omits the range rather than widening it: the query refuses a window
/// longer than a year, so the widest contributions figure GitHub will answer is
/// the last twelve months while the merged count beside it is every one ever.
/// That is what `contributionsBoundedToOneYear` exists to let the row say.
enum GitHubActivityFeed {
    /// `github.com` answers on its own API host; an Enterprise install answers
    /// under `/api` on the host itself, which is the convention every GitHub
    /// client uses.
    static let dotComHost = "github.com"
    private static let dotComEndpoint = URL(string: "https://api.github.com/graphql")!
    private static let enterprisePath = "/api/graphql"
    private static let authorizationHeader = "Authorization"
    private static let authorizationScheme = "Bearer"

    static func endpoint(host: String) -> URL? {
        guard host != dotComHost else { return dotComEndpoint }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = enterprisePath
        return components.url
    }

    static func read(
        _ connection: ForgeConnection, token: String, now: Date
    ) async throws -> ForgeActivityReading {
        guard let endpoint = endpoint(host: connection.host) else {
            throw ForgeReadFailure.malformed
        }
        let payload = try await ForgeActivityFeed.graphQL(
            endpoint, query: document(now: now), token: token,
            header: authorizationHeader, scheme: authorizationScheme)
        return try parse(payload, connection: connection, now: now)
    }

    /// Every period aliased into one document, because the cost is per document
    /// rather than per field: measured 2026-09-17, four contribution ranges and
    /// eight searches together still cost 1 point of the 5000 an hour, because
    /// a `search` asked for `first: 1` is one request node whatever it counts.
    /// Re-measured 2026-09-18 with a hundred-comment page added to the same
    /// `viewer`: still 1 point.
    static func document(now: Date) -> String {
        let contributions =
            UsagePeriod.allCases.map { period in
                let range =
                    ForgeWindow.start(of: period, now: now)
                    .map { "(from: \"\(ForgeWindow.vendorDay($0))\")" } ?? ""
                let alias = ForgeAlias.contributions(period)
                return "\(alias): contributionsCollection\(range) { \(calendarField) }"
            } + [commentField]
        let searches = UsagePeriod.allCases.flatMap { period -> [String] in
            let since =
                ForgeWindow.start(of: period, now: now)
                .map(ForgeWindow.vendorDay) ?? ""
            return [
                count(ForgeAlias.merged(period), "is:pr author:@me is:merged", "merged", since),
                count(ForgeAlias.issues(period), "is:issue author:@me", "created", since),
            ]
        }
        return """
            query {
              viewer { login \(contributions.joined(separator: " ")) }
              \(searches.joined(separator: "\n  "))
            }
            """
    }

    /// One aliased search, scoped to a window unless the window is unbounded.
    ///
    /// The qualifier is named by the caller because the two counters are over
    /// two different events: a pull request enters the merged figure when it is
    /// merged and an issue enters the opened figure when it is created, and a
    /// row that asked `created:` for both would be counting the pull requests
    /// this account *opened* under a mark that says merged.
    private static func count(
        _ alias: String, _ terms: String, _ qualifier: String, _ since: String
    ) -> String {
        let scope = since.isEmpty ? "" : " \(qualifier):>=\(since)"
        return "\(alias): search(query: \"\(terms)\(scope)\", type: ISSUE, first: 1)"
            + " { issueCount }"
    }

    private static let calendarField = "contributionCalendar { totalContributions }"

    /// The alias the comment page comes back under. Its own name rather than
    /// one of `ForgeAlias`'s, because there is one page for every window
    /// instead of a field each — the windows are cut out of it here.
    static let commentsAlias = "comments"
    /// How many comments one page carries, which is the connection's own
    /// ceiling: GraphQL refuses `first:` above 100.
    static let commentPage = 100
    /// One page of the account's own comments, newest-updated first.
    ///
    /// Ordered by `UPDATED_AT` because that is the only order this connection
    /// offers, and it is the order the coverage proof in `commentCounts` needs
    /// — not because the row cares when a comment was edited. `totalCount` is
    /// what answers the widest window, and it is exact however short the page
    /// falls.
    private static let commentField =
        "\(commentsAlias): issueComments(first: \(commentPage),"
        + " orderBy: {field: UPDATED_AT, direction: DESC})"
        + " { totalCount pageInfo { hasNextPage } nodes { createdAt updatedAt } }"

    /// Every window's comment count, cut out of the one page the document
    /// carries.
    ///
    /// **GitHub will not total this, so it is counted rather than asked for.**
    /// Measured 2026-09-18 across all 1 829 types of the live schema: 18 fields
    /// return a comment connection, **none** takes a date argument, and the
    /// four rooted on `User` (`issueComments`, `commitComments`, `gistComments`,
    /// `repositoryDiscussionComments`) offer only `orderBy` and paging — every
    /// other one hangs off a repository or a thread, which is the
    /// request-per-repository this reader exists not to do. The search that
    /// looks like the answer is not one: `commenter:@me` counts *threads* and
    /// `updated:` dates the thread rather than the comment, which read 35 and
    /// 53 against the 44 and 71 actually written — and `commented:` is not a
    /// qualifier at all, answering 0 exactly as an invented one does, on
    /// `ISSUE`, `ISSUE_ADVANCED` and `ISSUE_HYBRID` alike.
    ///
    /// **The page carries its own proof of coverage**, which is what makes one
    /// request enough. Nodes come back newest-updated first and nothing can be
    /// created after it was updated, so once the oldest `updatedAt` on the page
    /// precedes a window's start, no comment left unread can fall inside that
    /// window. A window the page cannot prove is **absent rather than a lower
    /// bound** — this type's own rule, and the reason a busy month may leave
    /// the figure off while the three beside it answer. Measured 2026-09-18 on
    /// an account holding 133 comments: one page answered 0 today, 44 over
    /// seven days and 71 over thirty, which is what reading all 133 answers,
    /// and it filled 71 of its 100 rows doing it.
    ///
    /// **Four things break the proof and every one of them fails to absent**,
    /// because each would otherwise report a short count as an exact one. The
    /// page not reaching back far enough is the ordinary case. A `hasNextPage`
    /// this build cannot read is the second, and it defaults to *unread*: the
    /// question the flag answers is whether anything is missing, so a flag that
    /// is missing has to be read as a yes. A node whose stamps will not parse
    /// is the third and the least obvious — dropping it quietly removes it from
    /// the tally *and* from the oldest-`updatedAt` the proof rests on, so a
    /// window could still look proven while being one comment short. A `nodes`
    /// that will not read as an array of objects at all is the fourth, and it
    /// is deliberately **not** the same as an empty one: GraphQL answers a
    /// partial failure with a null in place of the field, so reading that as
    /// "no comments, page complete" would publish a confident zero for every
    /// window out of a reply that carried nothing. The
    /// boundary comparison is strict for the same reason: a comment created and
    /// never edited exactly on it would sit outside a page that reached only as
    /// far as that instant. Only the widest window survives all three, because
    /// `totalCount` is the connection's own and owes the page nothing.
    static func commentCounts(_ viewer: [String: Any], now: Date) -> [UsagePeriod: Int] {
        guard let block = viewer[commentsAlias] as? [String: Any] else { return [:] }
        let nodes = block["nodes"] as? [[String: Any]]
        let stamps = (nodes ?? []).compactMap { node -> (created: Date, updated: Date)? in
            guard
                let created = (node["createdAt"] as? String)
                    .flatMap(UsageReaderShared.parseTimestamp),
                let updated = (node["updatedAt"] as? String)
                    .flatMap(UsageReaderShared.parseTimestamp)
            else { return nil }
            return (created, updated)
        }
        let total = block["totalCount"] as? Int
        let unread = (block["pageInfo"] as? [String: Any])?["hasNextPage"] as? Bool ?? true
        let everyNodeRead = nodes.map { stamps.count == $0.count } ?? false
        let oldestRead = stamps.map(\.updated).min()
        var counts: [UsagePeriod: Int] = [:]
        for period in UsagePeriod.allCases {
            guard let start = ForgeWindow.start(of: period, now: now) else {
                counts[period] = total
                continue
            }
            guard let boundary = ForgeWindow.vendorInstant(start) else { continue }
            guard everyNodeRead,
                !unread || (oldestRead.map { $0 < boundary } ?? false)
            else { continue }
            counts[period] = stamps.filter { $0.created >= boundary }.count
        }
        return counts
    }

    private static func issueCount(_ payload: [String: Any], _ alias: String) -> Int? {
        (payload[alias] as? [String: Any])?["issueCount"] as? Int
    }

    static func parse(
        _ payload: [String: Any], connection: ForgeConnection, now: Date
    ) throws -> ForgeActivityReading {
        guard let viewer = payload["viewer"] as? [String: Any],
            let login = viewer["login"] as? String, !login.isEmpty
        else { throw ForgeReadFailure.malformed }
        var contributions: [UsagePeriod: Int] = [:]
        var merged: [UsagePeriod: Int] = [:]
        var issues: [UsagePeriod: Int] = [:]
        for period in UsagePeriod.allCases {
            if let block = viewer[ForgeAlias.contributions(period)] as? [String: Any],
                let calendar = block["contributionCalendar"] as? [String: Any],
                let total = calendar["totalContributions"] as? Int
            {
                contributions[period] = total
            }
            if let count = issueCount(payload, ForgeAlias.merged(period)) { merged[period] = count }
            if let count = issueCount(payload, ForgeAlias.issues(period)) { issues[period] = count }
        }
        let comments = commentCounts(viewer, now: now)
        // A reply that named the account and no figure at all is a shape this
        // build does not understand rather than a quiet week.
        guard !contributions.isEmpty || !merged.isEmpty || !issues.isEmpty || !comments.isEmpty
        else {
            throw ForgeReadFailure.malformed
        }
        return ForgeActivityReading(
            id: connection.id, kind: connection.kind, host: connection.host, login: login,
            activity: ForgeActivity(
                contributions: contributions, merged: merged, issues: issues, comments: comments,
                contributionsBoundedToOneYear: true),
            readAt: now, failure: nil)
    }
}

/// GitLab's half: one GraphQL query for the merged counts, and two header reads
/// per period — the activity total, and the same filtered to comments.
///
/// **GitLab publishes no contribution total Sissy can read.** Its own profile
/// squares come from `users/<name>/calendar.json`, which is a web route rather
/// than an API one: measured 2026-09-17 against a self-hosted 19.3 instance
/// with a personal access token, it answered 200 with `{}`. So the figure here
/// is the number of events GitLab recorded for the user — push, merge request,
/// issue and comment activity — taken from the `x-total` header of
/// `/api/v4/events` with one row requested, which costs no page of results.
///
/// `after` is **exclusive**, measured the same day: `after=2026-09-17` answered
/// `x-total: 0` on a day that had 91 events, so a window starting on a day is
/// asked for by naming the day before it.
enum GitLabActivityFeed {
    private static let apiPath = "/api/v4/events"
    private static let graphQLPath = "/api/graphql"
    private static let tokenHeader = "PRIVATE-TOKEN"
    private static let totalHeader = "x-total"
    private static let onePage = "1"

    static func read(
        _ connection: ForgeConnection, token: String, now: Date
    ) async throws -> ForgeActivityReading {
        let merged = try await mergedCounts(connection, token: token, now: now)
        let issues = await issueCounts(
            connection, token: token, author: merged.username, now: now)
        // The one call above that cannot report a cancellation, so it is asked
        // for here rather than four requests later.
        try Task.checkCancellation()
        var contributions: [UsagePeriod: Int] = [:]
        var comments: [UsagePeriod: Int] = [:]
        // The two reads of a period go together rather than one after the
        // other: the comment counter doubled the header reads and would
        // otherwise have doubled the wall clock with them, on a self-hosted
        // instance that is reached over a tunnel and is the slow half of this
        // reader already. A period is still awaited before the next starts, so
        // the instance sees two requests at a time rather than eight.
        for period in UsagePeriod.allCases {
            async let total = events(connection, token: token, period: period, now: now)
            async let commented = commentEvents(
                connection, token: token, period: period, now: now)
            contributions[period] = try await total
            comments[period] = await commented
        }
        return ForgeActivityReading(
            id: connection.id, kind: connection.kind, host: connection.host, login: merged.username,
            activity: ForgeActivity(
                contributions: contributions, merged: merged.counts, issues: issues,
                comments: comments, contributionsBoundedToOneYear: false),
            readAt: now, failure: nil)
    }

    private static func mergedCounts(
        _ connection: ForgeConnection, token: String, now: Date
    ) async throws -> (username: String, counts: [UsagePeriod: Int]) {
        guard let root = connection.root else { throw ForgeReadFailure.malformed }
        let endpoint = root.appendingPathComponent(graphQLPath)
        let payload = try await ForgeActivityFeed.graphQL(
            endpoint, query: document(now: now), token: token,
            header: tokenHeader, scheme: nil)
        guard let user = payload["currentUser"] as? [String: Any],
            let username = user["username"] as? String, !username.isEmpty
        else { throw ForgeReadFailure.malformed }
        var counts: [UsagePeriod: Int] = [:]
        for period in UsagePeriod.allCases {
            guard let block = user[ForgeAlias.merged(period)] as? [String: Any],
                let count = block["count"] as? Int
            else { continue }
            counts[period] = count
        }
        return (username, counts)
    }

    static func document(now: Date) -> String {
        let fields = UsagePeriod.allCases.map { period -> String in
            let scope =
                ForgeWindow.start(of: period, now: now)
                .map { ", mergedAfter: \"\(ForgeWindow.vendorDay($0))\"" } ?? ""
            return
                "\(ForgeAlias.merged(period)): authoredMergeRequests(state: merged\(scope)) { count }"
        }
        return """
            query {
              currentUser { username \(fields.joined(separator: " ")) }
            }
            """
    }

    /// The issues this account opened, per window.
    ///
    /// A second document rather than a second field, because `CurrentUser`
    /// has no authored-issues connection — measured 2026-09-17 against 19.3,
    /// which answers `Field 'createdIssues' doesn't exist on type
    /// 'CurrentUser'` — so the count comes off the root `issues` field, which
    /// needs the login the first document just returned. A GraphQL argument
    /// cannot be fed from another field in the same document, so this is one
    /// more request and not a rearrangement of the one before it.
    static func issuesDocument(now: Date) -> String {
        let fields = UsagePeriod.allCases.map { period -> String in
            let scope =
                ForgeWindow.start(of: period, now: now)
                .map { ", createdAfter: \"\(ForgeWindow.vendorDay($0))\"" } ?? ""
            return "\(ForgeAlias.issues(period)): issues(authorUsername: $author\(scope)) { count }"
        }
        return """
            query($author: String!) {
              \(fields.joined(separator: "\n  "))
            }
            """
    }

    /// Every window's issue count, or none of them.
    ///
    /// Non-throwing on purpose: this is the one figure on the row an older
    /// GitLab may not serve at all, and a reading that already carries the
    /// contributions, the merges and the account must not be thrown away
    /// because the third counter was refused. It is the type's own rule read
    /// from the other end — a period is absent rather than zero when it could
    /// not be read — and a token the instance would not accept has already
    /// failed the document before this one.
    ///
    /// **What it therefore cannot report is a cancellation**, and not because
    /// of the `try?`: `send` has already erased the distinction, mapping every
    /// transport error — a refusal, a dropped connection, a cancelled task —
    /// onto `ForgeReadFailure.unreachable`. So `read` checks the task itself
    /// after this returns, which is the cancellation path for the one call in
    /// it that has none of its own.
    private static func issueCounts(
        _ connection: ForgeConnection, token: String, author: String, now: Date
    ) async -> [UsagePeriod: Int] {
        guard let root = connection.root else { return [:] }
        let endpoint = root.appendingPathComponent(graphQLPath)
        guard
            let payload = try? await ForgeActivityFeed.graphQL(
                endpoint, query: issuesDocument(now: now), variables: ["author": author],
                token: token, header: tokenHeader, scheme: nil)
        else { return [:] }
        var counts: [UsagePeriod: Int] = [:]
        for period in UsagePeriod.allCases {
            guard let block = payload[ForgeAlias.issues(period)] as? [String: Any],
                let count = block["count"] as? Int
            else { continue }
            counts[period] = count
        }
        return counts
    }

    /// One period's event count, read from the header rather than the body.
    ///
    /// A page of one row is requested because the count is what is wanted and
    /// the rows are not: measured 2026-09-17, thirty days of this user's
    /// activity is 986 events over ten pages, so counting them by reading them
    /// would be ten requests for a number the first reply already carries.
    /// The URL one period's count is asked for.
    ///
    /// Internal so a test can hold the off-by-one: `after` is **exclusive**, so
    /// a window starting on a day is asked for by naming the day before it.
    /// Measured 2026-09-17, `after=2026-09-17` answered `x-total: 0` on a day
    /// that had 95 events.
    static func eventsURL(
        _ connection: ForgeConnection, period: UsagePeriod, now: Date, action: String? = nil
    ) -> URL? {
        guard let root = connection.root,
            var components = URLComponents(
                url: root.appendingPathComponent(apiPath), resolvingAgainstBaseURL: false)
        else { return nil }
        var query = [URLQueryItem(name: "per_page", value: onePage)]
        if let start = ForgeWindow.start(of: period, now: now),
            let exclusive = Calendar.current.date(byAdding: .day, value: -1, to: start)
        {
            query.append(URLQueryItem(name: "after", value: ForgeWindow.day.string(from: exclusive)))
        }
        if let action { query.append(URLQueryItem(name: "action", value: action)) }
        components.queryItems = query
        return components.url
    }

    /// One period's comment count, off the same header as the events total.
    ///
    /// GitLab files a comment as an event, so the count is the contributions
    /// query with one filter on it — which also means it is a **part of** the
    /// figure beside it rather than something new: measured 2026-09-18, 14 of
    /// one week's 525 events and 62 of the month's 1 036.
    ///
    /// Non-throwing for the reason `issueCounts` is. `action` is an enumerated
    /// filter and an instance that will not serve this one answers 400, which
    /// would otherwise throw away a reading that already carries the
    /// contributions, the merges, the issues and the account over its newest
    /// counter. A period that could not be read is absent, never zero.
    private static func commentEvents(
        _ connection: ForgeConnection, token: String, period: UsagePeriod, now: Date
    ) async -> Int? {
        guard
            let count = try? await events(
                connection, token: token, period: period, now: now, action: commentedAction)
        else { return nil }
        return count
    }

    /// GitLab's own name for the event a comment files.
    static let commentedAction = "commented"

    private static func events(
        _ connection: ForgeConnection, token: String, period: UsagePeriod, now: Date,
        action: String? = nil
    ) async throws -> Int? {
        guard let url = eventsURL(connection, period: period, now: now, action: action) else {
            throw ForgeReadFailure.malformed
        }
        let request = ForgeActivityFeed.request(
            url, token: token, header: tokenHeader, scheme: nil)
        // Through the shared `send` so this path takes the same failure table
        // the GraphQL one does: the count is in a header rather than the body,
        // which is the only thing different about it.
        let (_, response) = try await ForgeActivityFeed.send(request)
        return response.value(forHTTPHeaderField: totalHeader).flatMap(Int.init)
    }
}
