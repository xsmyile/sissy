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
        period.start(now: now, calendar: calendar)
    }

    /// The date GitHub's `contributionsCollection` reads off an argument,
    /// written at midnight `Z`.
    ///
    /// **GitHub dates each contribution on the account's own day, and reads an
    /// argument as the UTC date it falls on.** Measured 2026-09-17 from
    /// Europe/Rome: a local midnight sent as the instant it is,
    /// `2026-09-16T22:00:00Z`, bought the whole of the 16th, 326 contributions
    /// where the profile's square for the 17th read 128, so an argument is a
    /// date rather than an instant. Measured 2026-10-07: pull requests opened
    /// at 00:34 Rome time, 22:34Z the day before, are counted under the local
    /// date, and the collection's own default window ends at `21:59:59Z`, the
    /// account's midnight. So a window is its local date written at midnight
    /// `Z`, which GitHub reads back as that same date, and it is open from the
    /// first second of the local day. Through 0.3.3 this read the second half the
    /// other way round, took the vendor's day for the UTC one, and left every
    /// row blank from local midnight until the UTC one.
    ///
    /// Gregorian whatever the system calendar is: taking the components off
    /// `Calendar.current` on a Mac set to a Buddhist calendar named 2569.
    static func vendorDay(_ instant: Date, calendar: Calendar = .current) -> String {
        dayName(instant, calendar: calendar) + "T00:00:00Z"
    }

    /// The last second of the local date `instant` falls on, in the form
    /// `vendorDay` names a start in: the `to` every bounded collection takes.
    ///
    /// Left out, `to` is the instant of the request, whose UTC date is still
    /// yesterday's for the first hours of a day east of Greenwich. A window
    /// ending in the future is no refusal: measured 2026-10-07, one ending
    /// tomorrow answered 0 with no error.
    static func vendorDayEnd(_ instant: Date, calendar: Calendar = .current) -> String {
        dayName(instant, calendar: calendar) + "T23:59:59Z"
    }

    /// An instant as GitHub's search qualifiers and GitLab's GraphQL filters
    /// take it.
    ///
    /// Both compare instants rather than dates, so a window starting at local
    /// midnight is asked for from the local midnight. Measured 2026-10-07 from
    /// Europe/Rome: `merged:>=` at the Rome midnight counted 15 merges where
    /// midnight `Z` counted 5, and GitLab's `mergedAfter: "2026-10-06T22:00:00Z"`
    /// counted the 4 merges after that instant out of the day's 79.
    static func instant(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    /// `yyyy-MM-dd` for the date `instant` falls on in `calendar`'s zone, off
    /// a Gregorian calendar.
    static func dayName(_ instant: Date, calendar: Calendar = .current) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: instant)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
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
/// is ten small requests, and away from UTC a page of the feed more for each
/// bounded read, the stretch `GitLabDaySplit` counts. A reader that asked per repository would be spending
/// a request on each of the thirty-odd repositories a real day touches, for
/// four numbers.
///
/// The latest event is the one reading that is not a count, and it costs each
/// vendor one request more: GitHub's feed is REST where the counts are
/// GraphQL, and GitLab's feed names its project by number. GitLab's feed itself
/// is free, riding the widest window's header read.
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
    private static let remainingHeader = "X-RateLimit-Remaining"
    private static let retryAfterHeader = "Retry-After"

    static func read(
        _ connection: ForgeConnection, token: String,
        counters: Set<ForgeCounter> = ForgeCounter.all, now: Date = Date()
    ) async throws -> ForgeActivityReading {
        switch connection.kind {
        case .gitHub:
            return try await GitHubActivityFeed.read(
                connection, token: token, counters: counters, now: now)
        case .gitLab:
            return try await GitLabActivityFeed.read(
                connection, token: token, counters: counters, now: now)
        }
    }

    /// Who the token belongs to, asked of whichever forge the connection
    /// names. It is what a connect is held on before anything is filed.
    static func probe(_ connection: ForgeConnection, token: String) async throws -> String {
        if ForgeRefusalStore.shared.failure(url: connection.root, token: token) == .unauthorized {
            ForgeRefusalStore.shared.record(nil, url: connection.root, token: token)
        }
        switch connection.kind {
        case .gitHub: return try await GitHubActivityFeed.probe(connection, token: token)
        case .gitLab: return try await GitLabActivityFeed.probe(connection, token: token)
        }
    }

    /// One JSON reply, or the reason there is not one.
    ///
    /// Every status the vendors answer with is mapped here rather than at each
    /// call site, so a 401 from GitHub and a 401 from GitLab reach the row as
    /// the same sentence.
    static func send(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        let token =
            request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
            ?? request.value(forHTTPHeaderField: "PRIVATE-TOKEN") ?? ""
        if let failure = ForgeRefusalStore.shared.failure(url: request.url, token: token) { throw failure }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await SissyHTTP.data(for: request)
        } catch {
            throw failure(thrown: error)
        }
        guard let http = response as? HTTPURLResponse else { throw ForgeReadFailure.malformed }
        if let failure = failure(of: http, addressedTo: request.url) {
            ForgeRefusalStore.shared.record(
                failure, url: request.url, token: token,
                until: ForgeRefusalStore.retryDeadline(http))
            throw failure
        }
        ForgeRefusalStore.shared.record(nil, url: request.url, token: token)
        return (data, http)
    }

    /// What a request that produced no reply means for the row: a reply from
    /// another host, which `SissyHTTP` throws rather than hands over, is
    /// `redirected`, and anything else is a forge out of reach.
    static func failure(thrown error: Error) -> ForgeReadFailure {
        error is SissyHTTP.LeftItsOrigin ? .redirected : .unreachable
    }

    /// What a reply means for the row, `nil` for one worth reading.
    ///
    /// A refusal is the token's only when the host the request was addressed
    /// to gave it: past a redirect off that origin the token was never sent,
    /// and a redirect the session would not follow comes back as the `3xx`
    /// itself. Both are `redirected`, and the origin is read before the
    /// throttling headers: a deadline another host sent is that host's quota,
    /// not the forge's. Internal so a test can hold it against a constructed
    /// reply.
    static func failure(of response: HTTPURLResponse, addressedTo url: URL?) -> ForgeReadFailure? {
        switch response.statusCode {
        case 200:
            return nil
        case 300..<400:
            return .redirected
        case 401, 403:
            guard SissyHTTP.sameOrigin(url, response.url) else { return .redirected }
            return askedToSlowDown(response) ? .rateLimited : .unauthorized
        case 429:
            return .rateLimited
        default:
            return .malformed
        }
    }

    /// Whether a refusal is the vendor asking for less traffic rather than
    /// refusing the token, which `403` is GitHub's answer to either way.
    ///
    /// The two are told apart by the headers rather than by the code, and by
    /// two headers rather than one: an exhausted hourly quota leaves a
    /// remaining count of zero, while a secondary limit leaves the quota
    /// untouched and sends a retry deadline instead. Reading only the count
    /// files a throttled account as a refused token, which `needsTheUser`
    /// parks — so the connection stops being polled until the user replaces a
    /// token that was never the problem. Unreachable enough while the cadence
    /// is the only thing asking; a refresh on a click is what makes it
    /// ordinary.
    ///
    /// Internal so a test can hold the distinction against a constructed reply,
    /// which is the only seam there is: `send` goes straight to `SissyHTTP`.
    static func askedToSlowDown(_ response: HTTPURLResponse) -> Bool {
        if response.value(forHTTPHeaderField: retryAfterHeader) != nil { return true }
        guard let remaining = response.value(forHTTPHeaderField: remainingHeader) else {
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
        let (data, response) = try await send(request)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ForgeReadFailure.malformed
        }
        fileGraphQLRefusal(root, reply: response, url: url, token: token)
        // A GraphQL endpoint answers 200 for a query it refused, with the
        // reason in `errors` — so a document that came back without `data` is
        // an error however healthy the status line was.
        guard let payload = root["data"] as? [String: Any] else {
            throw Self.refusal(root) ?? ForgeReadFailure.malformed
        }
        return payload
    }

    /// A rate limit a GraphQL endpoint answered with a 200, filed against the
    /// credential with the reply's deadline the way a refused status is, so a
    /// rebuilt monitor or a relaunch does not ask again before the reset.
    /// GitHub documents that 200 for an exhausted GraphQL quota; `send` has
    /// already cleared the credential by then, on the status line alone.
    @discardableResult
    static func fileGraphQLRefusal(
        _ root: [String: Any], reply: HTTPURLResponse, url: URL?, token: String,
        store: ForgeRefusalStore = .shared
    ) -> ForgeReadFailure? {
        let types = (root["errors"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String }
        guard types.contains("RATE_LIMITED") else { return nil }
        store.record(.rateLimited, url: url, token: token, until: ForgeRefusalStore.retryDeadline(reply))
        return .rateLimited
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

/// GitHub's half: one GraphQL document for every count on the row, and the
/// account's event feed for the latest event.
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
    static let authorizationHeader = "Authorization"
    static let authorizationScheme = "Bearer"

    static func endpoint(_ connection: ForgeConnection) -> URL? {
        guard !connection.isVendorHosted else { return dotComEndpoint }
        return connection.root?.appendingPathComponent(enterprisePath)
    }

    /// Who the token belongs to, and nothing else: the one question every
    /// read starts with, asked before a connection is filed.
    static func probe(_ connection: ForgeConnection, token: String) async throws -> String {
        guard let endpoint = endpoint(connection) else { throw ForgeReadFailure.malformed }
        let payload = try await ForgeActivityFeed.graphQL(
            endpoint, query: probeDocument, token: token,
            header: authorizationHeader, scheme: authorizationScheme)
        return try login(fromProbe: payload)
    }

    /// The login a probe's `data` names. A `viewer` that is there and null is
    /// a token that signed nobody in, which is the token's refusal; a reply
    /// with no `viewer` at all is not GitHub answering.
    static func login(fromProbe payload: [String: Any]) throws -> String {
        if payload["viewer"] is NSNull { throw ForgeReadFailure.unauthorized }
        guard let viewer = payload["viewer"] as? [String: Any],
            let login = viewer["login"] as? String, !login.isEmpty
        else { throw ForgeReadFailure.malformed }
        return login
    }

    static let probeDocument = "query { viewer { login } }"

    static func read(
        _ connection: ForgeConnection, token: String, counters: Set<ForgeCounter>, now: Date
    ) async throws -> ForgeActivityReading {
        guard let endpoint = endpoint(connection) else {
            throw ForgeReadFailure.malformed
        }
        let payload = try await ForgeActivityFeed.graphQL(
            endpoint, query: document(now: now, counters: counters), token: token,
            header: authorizationHeader, scheme: authorizationScheme)
        var reading = try parse(payload, connection: connection, now: now)
        if counters.contains(.latest), let login = reading.login {
            reading.latest = await latestEvent(connection, token: token, login: login)
            try Task.checkCancellation()
        }
        if counters.contains(.actions), let login = reading.login {
            reading.actions = await GitHubActionsFeed.read(
                connection, token: token, login: login, now: now)
            try Task.checkCancellation()
        }
        return reading
    }

    static let dotComREST = URL(string: "https://api.github.com")!
    private static let enterpriseRESTPath = "/api/v3"
    /// How many events one read of the feed asks for, which is the most a
    /// page of it carries.
    static let eventPage = 100

    /// The account's own event feed, which is the one place GitHub says what
    /// was done last.
    ///
    /// **REST, because GraphQL has no feed.** `contributionsCollection` dates a
    /// commit to its day and nothing finer, so the document above can say how
    /// much and never when. The feed is a request of its own, on the REST
    /// quota rather than the GraphQL one, which is 5000 an hour against a poll
    /// that is at most twelve. Measured 2026-09-28 with a classic token, it
    /// carries the account's private events as well as its public ones — pushes
    /// to private repositories of an organisation included.
    static func eventsURL(_ connection: ForgeConnection, login: String) -> URL? {
        let base =
            connection.isVendorHosted
            ? dotComREST : connection.root?.appendingPathComponent(enterpriseRESTPath)
        guard let base,
            var components = URLComponents(
                url: base.appendingPathComponent("users").appendingPathComponent(login)
                    .appendingPathComponent("events"),
                resolvingAgainstBaseURL: false)
        else { return nil }
        components.queryItems = [URLQueryItem(name: "per_page", value: String(eventPage))]
        return components.url
    }

    /// The newest event worth naming, or nil.
    ///
    /// Non-throwing for the reason `GitLabActivityFeed.issueCounts` is: the
    /// counters have already arrived, and a feed that would not answer must
    /// not throw them away. What it cannot report is a cancellation, so the
    /// caller asks the task itself.
    ///
    /// **The feed runs late, and the row can only say what it holds.**
    /// Measured 2026-09-28, a push had not reached it a quarter of an hour
    /// later, and a push from the morning was filed after the evening's merges.
    /// The stamp on what is shown is still the vendor's own, so the row is late
    /// rather than wrong.
    private static func latestEvent(
        _ connection: ForgeConnection, token: String, login: String
    ) async -> ForgeEvent? {
        guard let url = eventsURL(connection, login: login) else { return nil }
        let request = ForgeActivityFeed.request(
            url, token: token, header: authorizationHeader, scheme: authorizationScheme)
        guard let reply = try? await ForgeActivityFeed.send(request),
            let rows = try? JSONSerialization.jsonObject(with: reply.data) as? [[String: Any]]
        else { return nil }
        return ForgeEvent.newest(rows.compactMap(event))
    }

    /// One row of the feed as the event the row names, nil for the ones that
    /// are not work: a branch created or deleted, a star, a label.
    static func event(_ row: [String: Any]) -> ForgeEvent? {
        guard let type = row["type"] as? String,
            let at = (row["created_at"] as? String).flatMap(UsageReaderShared.parseTimestamp),
            let payload = row["payload"] as? [String: Any],
            let done = action(type, payload)
        else { return nil }
        let repository = ((row["repo"] as? [String: Any])?["name"] as? String)
            .map { $0.split(separator: "/").last.map(String.init) ?? $0 }
        return ForgeEvent(action: done.action, target: done.target, repository: repository, at: at)
    }

    /// Which of the five verbs a feed row is, and what it was done to.
    ///
    /// Every verb is the account's own act, so `merged` is a request this
    /// account merged, whoever opened it: the event line says what was done,
    /// where the merged figure above it counts the requests it authored.
    ///
    /// **A merge is `merged` as well as `closed`.** Measured 2026-09-28, the
    /// feed filed a pull request merged that day with the action `merged` and
    /// a `pull_request` trimmed to its number, so the `merged` flag the
    /// documented `closed` carries is not there to be read; both forms are
    /// taken, and a `closed` without the flag is a request closed unmerged.
    private static func action(
        _ type: String, _ payload: [String: Any]
    ) -> (action: ForgeEvent.Action, target: String?)? {
        let verb = payload["action"] as? String
        let request = payload["pull_request"] as? [String: Any]
        let requestNumber = reference((payload["number"] as? Int) ?? (request?["number"] as? Int))
        let issueNumber = reference((payload["issue"] as? [String: Any])?["number"] as? Int)
        let merged = verb == "merged" || (verb == "closed" && request?["merged"] as? Bool == true)
        switch type {
        case "PushEvent":
            return (.pushed, (payload["ref"] as? String).map(branch))
        case "PullRequestEvent" where verb == "opened" || verb == "reopened":
            return (.opened, requestNumber)
        case "PullRequestEvent" where merged:
            return (.merged, requestNumber)
        case "IssuesEvent" where verb == "opened":
            return (.openedIssue, issueNumber)
        case "IssueCommentEvent" where verb == "created":
            return (.commented, issueNumber)
        case "PullRequestReviewCommentEvent" where verb == "created":
            return (.commented, requestNumber)
        case "PullRequestReviewEvent" where verb == "created":
            return (.reviewed, requestNumber)
        default:
            return nil
        }
    }

    private static func reference(_ number: Int?) -> String? { number.map { "#\($0)" } }

    /// A ref as the row names it: a branch by its name, a tag as `tag` and its
    /// name, which is what tells it apart from a branch of the same name and
    /// is the form `GitLabActivityFeed` gives one too.
    private static func branch(_ ref: String) -> String {
        if ref.hasPrefix(branchPrefix) { return String(ref.dropFirst(branchPrefix.count)) }
        if ref.hasPrefix(tagPrefix) { return ForgeEvent.tag(String(ref.dropFirst(tagPrefix.count))) }
        return ref
    }

    private static let branchPrefix = "refs/heads/"
    private static let tagPrefix = "refs/tags/"

    /// Every period aliased into one document, because the cost is per document
    /// rather than per field: measured 2026-09-17, four contribution ranges and
    /// eight searches together still cost 1 point of the 5000 an hour, because
    /// a `search` asked for `first: 1` is one request node whatever it counts.
    /// Re-measured 2026-09-18 with a hundred-comment page added to the same
    /// `viewer`: still 1 point.
    static func document(
        now: Date, counters: Set<ForgeCounter> = ForgeCounter.all, calendar: Calendar = .current
    ) -> String {
        let periods = UsagePeriod.allCases
        let end = ForgeWindow.vendorDayEnd(now, calendar: calendar)
        let contributions =
            periods.map { period in
                let range =
                    ForgeWindow.start(of: period, now: now, calendar: calendar)
                    .map { "(from: \"\(ForgeWindow.vendorDay($0, calendar: calendar))\", to: \"\(end)\")" }
                    ?? ""
                let alias = ForgeAlias.contributions(period)
                return "\(alias): contributionsCollection\(range) { \(calendarField) }"
            } + (counters.contains(.comments) ? [commentField] : [])
        let searches = periods.flatMap { period -> [String] in
            let since =
                ForgeWindow.start(of: period, now: now, calendar: calendar)
                .map(ForgeWindow.instant) ?? ""
            var fields: [String] = []
            if counters.contains(.merged) {
                fields.append(
                    count(ForgeAlias.merged(period), "is:pr author:@me is:merged", "merged", since))
            }
            if counters.contains(.issues) {
                fields.append(
                    count(ForgeAlias.issues(period), "is:issue author:@me", "created", since))
            }
            return fields
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
    static func commentCounts(
        _ viewer: [String: Any], now: Date, calendar: Calendar = .current
    ) -> [UsagePeriod: Int] {
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
            guard let boundary = ForgeWindow.start(of: period, now: now, calendar: calendar) else {
                counts[period] = total
                continue
            }
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
            id: connection.id, kind: connection.kind, host: connection.address, login: login,
            activity: ForgeActivity(
                contributions: contributions, merged: merged, issues: issues, comments: comments,
                contributionsBoundedToOneYear: true),
            readAt: now, failure: nil)
    }
}

/// GitLab's half: one GraphQL query for the merged counts, and two header reads
/// per period — the activity total, and the same filtered to comments — plus
/// the name of the project the latest event is on.
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
    /// GitLab's own hosted instance, which the connect sheet offers when the
    /// forge is picked.
    static let dotComHost = "gitlab.com"
    /// Where GitLab stops counting. Past it the events endpoint drops
    /// `x-total` and keeps paginating, per GitLab's REST documentation read
    /// 2026-09-23, so a reply with a next page and no total proves this many
    /// and no more.
    static let countCeiling = 10_000
    private static let nextPageHeader = "x-next-page"
    private static let apiPath = "/api/v4/events"
    private static let graphQLPath = "/api/graphql"
    private static let tokenHeader = "PRIVATE-TOKEN"
    private static let totalHeader = "x-total"
    private static let onePage = 1

    static func read(
        _ connection: ForgeConnection, token: String, counters: Set<ForgeCounter>, now: Date
    ) async throws -> ForgeActivityReading {
        // Asked for whatever the counters say, because this is also the call
        // that names the account — the row's login and the author the issue
        // document filters on both come off it, so it is the one request here
        // that a switch cannot take away.
        let merged = try await mergedCounts(
            connection, token: token, counters: counters, now: now)
        let issues =
            counters.contains(.issues)
            ? await issueCounts(connection, token: token, author: merged.username, now: now)
            : [:]
        // The one call above that cannot report a cancellation, so it is asked
        // for here rather than four requests later.
        try Task.checkCancellation()
        var contributions: [UsagePeriod: Int] = [:]
        var comments: [UsagePeriod: Int] = [:]
        var contributionsAtLeast: Set<UsagePeriod> = []
        var commentsAtLeast: Set<UsagePeriod> = []
        var newest: (event: ForgeEvent, project: Int?)?
        // The two reads of a period go together rather than one after the
        // other: the comment counter doubled the header reads and would
        // otherwise have doubled the wall clock with them, on a self-hosted
        // instance that is reached over a tunnel and is the slow half of this
        // reader already. A period is still awaited before the next starts, so
        // the instance sees two requests at a time rather than eight.
        for period in UsagePeriod.allCases {
            let feed = period == .all && counters.contains(.latest)
            let start = ForgeWindow.start(of: period, now: now)
            async let total = events(
                connection, token: token, since: start, rows: feed ? latestPage : onePage)
            async let commented =
                counters.contains(.comments)
                ? commentEvents(connection, token: token, since: start) : nil
            let counted = try await total
            let commentCount = await commented
            contributions[period] = counted.count?.value
            comments[period] = commentCount?.value
            if counted.count?.isFloor == true { contributionsAtLeast.insert(period) }
            if commentCount?.isFloor == true { commentsAtLeast.insert(period) }
            if feed { newest = latest(in: counted.body) }
        }
        var lastEvent = newest?.event
        if let newest, let project = newest.project {
            lastEvent = newest.event.named(await projectPath(connection, token: token, id: project))
            try Task.checkCancellation()
        }
        return ForgeActivityReading(
            id: connection.id, kind: connection.kind, host: connection.address, login: merged.username,
            activity: ForgeActivity(
                contributions: contributions, merged: merged.counts, issues: issues,
                comments: comments, contributionsBoundedToOneYear: false,
                contributionsAtLeast: contributionsAtLeast, commentsAtLeast: commentsAtLeast),
            readAt: now, failure: nil, latest: lastEvent)
    }

    /// How many events the widest window's read carries in its body when the
    /// latest event is asked for.
    ///
    /// **The page is free, which is why this is not a request of its own.**
    /// The `all` count already asks the feed newest first and throws the rows
    /// away; asking for twenty instead of one costs the reply a few kilobytes.
    /// Twenty rather than one because the newest row is often not work:
    /// measured 2026-09-28, it was a branch `deleted` after its merge, and a
    /// merge files three rows in the same second.
    static let latestPage = 20

    /// The newest event worth naming on a page of the feed, with the project
    /// it names, which the row still has to ask the name of.
    static func latest(in body: Data) -> (event: ForgeEvent, project: Int?)? {
        guard let rows = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else {
            return nil
        }
        return rows.compactMap(event).max { $0.event.at < $1.event.at }
    }

    /// One row of the feed as the event the row names, nil for the ones that
    /// are not work.
    ///
    /// **`target_iid` is not always the request.** Measured 2026-09-28 on
    /// 19.3, a push files the project's own id there and a comment files the
    /// note's, so a comment is read through `note.noteable_iid` and a push
    /// takes no number at all.
    static func event(_ row: [String: Any]) -> (event: ForgeEvent, project: Int?)? {
        guard let name = row["action_name"] as? String,
            let at = (row["created_at"] as? String).flatMap(UsageReaderShared.parseTimestamp),
            let done = action(name, row)
        else { return nil }
        let event = ForgeEvent(action: done.action, target: done.target, repository: nil, at: at)
        return (event, row["project_id"] as? Int)
    }

    private static func action(
        _ name: String, _ row: [String: Any]
    ) -> (action: ForgeEvent.Action, target: String?)? {
        let type = row["target_type"] as? String
        let iid = row["target_iid"] as? Int
        let push = row["push_data"] as? [String: Any]
        switch name {
        case "pushed to", "pushed new":
            let ref = push?["ref"] as? String
            return (.pushed, push?["ref_type"] as? String == tagRefType ? ref.map(ForgeEvent.tag) : ref)
        case "opened" where type == mergeRequestType:
            return (.opened, iid.map(mergeRequest))
        case "opened" where type == issueType:
            return (.openedIssue, iid.map(issue))
        case "accepted":
            return (.merged, iid.map(mergeRequest))
        case "approved":
            return (.reviewed, iid.map(mergeRequest))
        case "commented on":
            return (.commented, noteTarget(row))
        default:
            return nil
        }
    }

    /// What a comment was left on, in the notation GitLab itself writes it
    /// in: `!` for a merge request, `#` for an issue, nothing for a commit or
    /// a snippet.
    private static func noteTarget(_ row: [String: Any]) -> String? {
        let note = row["note"] as? [String: Any]
        guard let iid = note?["noteable_iid"] as? Int else { return nil }
        switch note?["noteable_type"] as? String {
        case mergeRequestType: return mergeRequest(iid)
        case issueType: return issue(iid)
        default: return nil
        }
    }

    private static func mergeRequest(_ iid: Int) -> String { "!\(iid)" }
    private static func issue(_ iid: Int) -> String { "#\(iid)" }
    private static let mergeRequestType = "MergeRequest"
    private static let issueType = "Issue"
    private static let tagRefType = "tag"

    /// The project a feed row names, as the path its own URL ends in.
    ///
    /// **One request, because the feed names projects by number.** Measured
    /// 2026-09-28, a merge request's row carries its own title and the
    /// project's id and nothing else, so the name is asked for. The path rather
    /// than the display name, because it is what a GitHub row's repository is:
    /// the last component of the URL the user would type. Non-throwing for
    /// the reason `issueCounts` is.
    static func projectURL(_ connection: ForgeConnection, id: Int) -> URL? {
        connection.root?.appendingPathComponent(projectsPath).appendingPathComponent(String(id))
    }

    private static func projectPath(
        _ connection: ForgeConnection, token: String, id: Int
    ) async -> String? {
        guard let url = projectURL(connection, id: id) else { return nil }
        let request = ForgeActivityFeed.request(url, token: token, header: tokenHeader, scheme: nil)
        guard let reply = try? await ForgeActivityFeed.send(request),
            let project = try? JSONSerialization.jsonObject(with: reply.data) as? [String: Any]
        else { return nil }
        return project["path"] as? String
    }

    private static let projectsPath = "/api/v4/projects"

    /// Who the token belongs to, off the same document the merged counts
    /// ride on with none of them asked for.
    static func probe(_ connection: ForgeConnection, token: String) async throws -> String {
        try await mergedCounts(connection, token: token, counters: [], now: Date()).username
    }

    private static func mergedCounts(
        _ connection: ForgeConnection, token: String, counters: Set<ForgeCounter>, now: Date
    ) async throws -> (username: String, counts: [UsagePeriod: Int]) {
        guard let root = connection.root else { throw ForgeReadFailure.malformed }
        let endpoint = root.appendingPathComponent(graphQLPath)
        let payload = try await ForgeActivityFeed.graphQL(
            endpoint, query: document(now: now, counters: counters), token: token,
            header: tokenHeader, scheme: nil)
        let username = try username(from: payload)
        guard let user = payload["currentUser"] as? [String: Any] else {
            throw ForgeReadFailure.malformed
        }
        var counts: [UsagePeriod: Int] = [:]
        for period in UsagePeriod.allCases {
            guard let block = user[ForgeAlias.merged(period)] as? [String: Any],
                let count = block["count"] as? Int
            else { continue }
            counts[period] = count
        }
        return (username, counts)
    }

    /// The login a document's `data` names. A `currentUser` that is there
    /// and null is a request GitLab served as nobody, which is the token's
    /// refusal and used to read as a host that was not GitLab; a reply with
    /// no `currentUser` at all is that.
    static func username(from payload: [String: Any]) throws -> String {
        if payload["currentUser"] is NSNull { throw ForgeReadFailure.unauthorized }
        guard let user = payload["currentUser"] as? [String: Any],
            let username = user["username"] as? String, !username.isEmpty
        else { throw ForgeReadFailure.malformed }
        return username
    }

    static func document(
        now: Date, counters: Set<ForgeCounter> = ForgeCounter.all, calendar: Calendar = .current
    ) -> String {
        let fields =
            counters.contains(.merged)
            ? UsagePeriod.allCases.map { period -> String in
                let scope =
                    ForgeWindow.start(of: period, now: now, calendar: calendar)
                    .map { ", mergedAfter: \"\(ForgeWindow.instant($0))\"" } ?? ""
                return
                    "\(ForgeAlias.merged(period)): authoredMergeRequests(state: merged\(scope)) { count }"
            } : []
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
    static func issuesDocument(now: Date, calendar: Calendar = .current) -> String {
        let fields = UsagePeriod.allCases
            .map { period -> String in
                let scope =
                    ForgeWindow.start(of: period, now: now, calendar: calendar)
                    .map { ", createdAfter: \"\(ForgeWindow.instant($0))\"" } ?? ""
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

    /// The URL a count from a UTC midnight is asked for, every event for nil.
    ///
    /// A page of one row is requested because the count is what is wanted and
    /// the rows are not: measured 2026-09-17, thirty days of this user's
    /// activity is 986 events over ten pages, so counting them by reading them
    /// would be ten requests for a number the first reply already carries.
    ///
    /// `after` is **exclusive**, so the count from a UTC midnight names the
    /// day before it. Measured 2026-09-17, `after=2026-09-17` answered
    /// `x-total: 0` on a day that had 95 events.
    static func eventsURL(
        _ connection: ForgeConnection, from midnight: Date?, action: String? = nil, rows: Int = onePage
    ) -> URL? {
        var query = [URLQueryItem(name: "per_page", value: String(rows))]
        if let midnight {
            query.append(URLQueryItem(name: "after", value: GitLabDaySplit.name(midnight, days: -1)))
        }
        if let action { query.append(URLQueryItem(name: "action", value: action)) }
        return eventsURL(connection, query: query)
    }

    private static func eventsURL(_ connection: ForgeConnection, query: [URLQueryItem]) -> URL? {
        guard let root = connection.root,
            var components = URLComponents(
                url: root.appendingPathComponent(apiPath), resolvingAgainstBaseURL: false)
        else { return nil }
        components.queryItems = query
        return components.url
    }

    /// One page of a UTC day's feed, oldest or newest first, which is where the
    /// stretch between a window's start and GitLab's midnight is counted.
    static func sliverURL(
        _ connection: ForgeConnection, split: GitLabDaySplit, action: String? = nil, page: Int
    ) -> URL? {
        let day = split.sliver.start
        var query = [
            URLQueryItem(name: "after", value: GitLabDaySplit.name(day, days: -1)),
            URLQueryItem(name: "before", value: GitLabDaySplit.name(day, days: 1)),
            URLQueryItem(name: "per_page", value: String(sliverPage)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "sort", value: split.adds ? "desc" : "asc"),
        ]
        if let action { query.append(URLQueryItem(name: "action", value: action)) }
        return eventsURL(connection, query: query)
    }

    /// The rows one stretch page carries, which is the most GitLab serves.
    static let sliverPage = 100
    /// How many pages a stretch is read through before it is given up as
    /// absent: a thousand events in at most twelve hours.
    static let sliverPageLimit = 10

    /// One window's comment count, off the same header as the events total.
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
        _ connection: ForgeConnection, token: String, since start: Date?
    ) async -> ForgeEventCount? {
        guard
            let read = try? await events(
                connection, token: token, since: start, action: commentedAction)
        else { return nil }
        return read.count
    }

    /// GitLab's own name for the event a comment files.
    static let commentedAction = "commented"

    /// The events since `start`, every one for nil, and the page of the feed
    /// the count came with.
    ///
    /// **The count is GitLab's for whole UTC days and the feed's for the
    /// rest.** `after` takes a date and filters by the UTC day — measured
    /// 2026-09-19, naming an instant inside the day answered as naming the
    /// date did — but every row carries its `created_at` to the millisecond.
    /// So the header counts from the UTC midnight nearest the start, and the
    /// stretch between the two, two hours in Rome, is counted off the rows of
    /// that one UTC day (`GitLabDaySplit`). Measured 2026-10-07: 16 of the
    /// events GitLab filed under the 6th were the first minutes of the 7th in
    /// Rome, which is what the row read blank over through 0.3.3. A stretch
    /// that does not fit `sliverPageLimit` pages, or that outnumbers the
    /// header count it corrects, leaves the count absent rather than short; a
    /// refusal or a cancellation on its pages throws like the header read.
    ///
    /// The stretch's day is taken in UTC. An instance whose own timezone is
    /// not UTC applies `after` and `before` in that zone instead, and the one
    /// residual nothing here closes is the part of the stretch that zone moves
    /// to the neighbouring date: measured 2026-10-07 on a 19.4 instance, the
    /// split counted the 40 events a full read since the Rome midnight did.
    static func events(
        _ connection: ForgeConnection, token: String, since start: Date?,
        action: String? = nil, rows: Int = onePage
    ) async throws -> (count: ForgeEventCount?, body: Data) {
        let split = start.map(GitLabDaySplit.init)
        guard let url = eventsURL(connection, from: split?.midnight, action: action, rows: rows) else {
            throw ForgeReadFailure.malformed
        }
        let request = ForgeActivityFeed.request(
            url, token: token, header: tokenHeader, scheme: nil)
        // Through the shared `send` so this path takes the same failure table
        // the GraphQL one does: the count is in a header rather than the body,
        // which is the only thing different about it.
        let (body, response) = try await ForgeActivityFeed.send(request)
        let counted = count(of: response)
        guard let counted, let split, split.sliver.duration > 0 else { return (counted, body) }
        guard let edge = try await sliverCount(connection, token: token, split: split, action: action)
        else { return (nil, body) }
        return (counted.adding(split.adds ? edge : -edge), body)
    }

    private static func sliverCount(
        _ connection: ForgeConnection, token: String, split: GitLabDaySplit, action: String?
    ) async throws -> Int? {
        var total = 0
        for page in 1...sliverPageLimit {
            guard let url = sliverURL(connection, split: split, action: action, page: page) else {
                throw ForgeReadFailure.malformed
            }
            let request = ForgeActivityFeed.request(
                url, token: token, header: tokenHeader, scheme: nil)
            let body = try await ForgeActivityFeed.send(request).data
            guard let rows = (try? JSONSerialization.jsonObject(with: body)) as? [[String: Any]]
            else { return nil }
            let stamps = rows.compactMap {
                ($0["created_at"] as? String).flatMap(UsageReaderShared.parseTimestamp)
            }
            guard stamps.count == rows.count else { return nil }
            let tally = split.tally(stamps)
            total += tally.count
            if tally.finished || rows.count < sliverPage { return total }
        }
        return nil
    }

    /// The count a reply's headers carry, nil where they carry none.
    ///
    /// `x-total` is the count. A reply without it that still names a next
    /// page is GitLab past `countCeiling`, which is a floor the row can print;
    /// one with neither is a reply that says nothing, and stays absent rather
    /// than zero.
    static func count(of response: HTTPURLResponse) -> ForgeEventCount? {
        if let total = response.value(forHTTPHeaderField: totalHeader).flatMap(Int.init) {
            return .exact(total)
        }
        guard let next = response.value(forHTTPHeaderField: nextPageHeader), Int(next) != nil
        else { return nil }
        return .atLeast(countCeiling)
    }
}

/// One GitLab event count: the whole of it, or the ceiling GitLab stopped
/// counting at.
enum ForgeEventCount: Sendable, Equatable {
    case exact(Int)
    case atLeast(Int)

    var value: Int {
        switch self {
        case .exact(let count), .atLeast(let count): count
        }
    }

    var isFloor: Bool {
        if case .atLeast = self { return true }
        return false
    }

    /// The same count moved by `delta`, which keeps a floor a floor: what is
    /// at least `n` from one instant is at least `n + delta` from another.
    /// Nil where the move would go below zero, which only two reads that
    /// disagree can produce, and which is no count at all rather than a zero.
    func adding(_ delta: Int) -> Self? {
        switch self {
        case .exact(let count): count + delta < 0 ? nil : .exact(count + delta)
        case .atLeast(let count): count + delta < 0 ? nil : .atLeast(count + delta)
        }
    }
}

/// Where a window's local start meets GitLab's UTC days.
///
/// GitLab's events count whole UTC days, so a window is counted from the UTC
/// midnight nearest its start and the stretch between them is counted off the
/// feed: added when the start falls before that midnight, as it does east of
/// Greenwich, and taken off when it falls after it. Nearest, so the stretch is
/// at most twelve hours of one UTC day whatever the zone.
struct GitLabDaySplit: Sendable, Equatable {
    /// The midnight the header count runs from.
    let midnight: Date
    /// The stretch between the window's start and that midnight.
    let sliver: DateInterval
    /// Whether the stretch is inside the window, so its events are added.
    let adds: Bool

    init(start: Date) {
        let floor = Self.utc.startOfDay(for: start)
        let ceiling = Self.utc.date(byAdding: .day, value: 1, to: floor) ?? floor
        if start.timeIntervalSince(floor) <= ceiling.timeIntervalSince(start) {
            midnight = floor
            sliver = DateInterval(start: floor, end: start)
            adds = false
        } else {
            midnight = ceiling
            sliver = DateInterval(start: start, end: ceiling)
            adds = true
        }
    }

    /// How many of one page's stamps fall in the stretch, and whether the page
    /// has already passed it in the order it was asked for: newest first for a
    /// stretch at the end of its day, oldest first for one at the start.
    func tally(_ stamps: [Date]) -> (count: Int, finished: Bool) {
        var count = 0
        for stamp in stamps {
            if adds ? stamp < sliver.start : stamp >= sliver.end { return (count, true) }
            if stamp >= sliver.start, stamp < sliver.end { count += 1 }
        }
        return (count, false)
    }

    /// The UTC date `days` away from the one `instant` falls on, as GitLab's
    /// `after` and `before` take it.
    static func name(_ instant: Date, days: Int) -> String {
        ForgeWindow.dayName(utc.date(byAdding: .day, value: days, to: instant) ?? instant, calendar: utc)
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()
}
