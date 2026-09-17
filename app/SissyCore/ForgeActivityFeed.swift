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

    /// Read-only after construction, which is the condition
    /// `UsageReaderShared` documents for the same escape hatch: only mutating
    /// `formatOptions` is unsafe on these types, and nothing here does.
    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// The same instant with **this Mac's own offset on it**, for a filter that
    /// would otherwise be read in a calendar that is not the user's.
    ///
    /// GitHub's search qualifiers take either a bare date or a timestamp, and a
    /// bare date is midnight **UTC**: measured 2026-09-17 from Europe/Rome, a
    /// window whose local start is 00:00+02:00 asked as `merged:>=2026-09-17`
    /// begins two hours late, so merges in the first two hours of the local day
    /// fall out of Today while the contributions figure beside them — which is
    /// asked as an instant — keeps them. The timestamp form fixes it and the
    /// offset is honoured: measured the same day, the same window asked from
    /// 14:00+02:00 answered 11 where 14:00+00:00 answered 6 and the whole day
    /// answered 25.
    nonisolated(unsafe) static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()

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
/// repository.** Measured 2026-09-17: GitHub answers every period's
/// contribution total *and* every period's merged-pull-request count in a
/// single GraphQL document costing 1 point of 5000 per hour; GitLab answers the
/// merged counts in one GraphQL query and each period's activity total in the
/// `x-total` header of a one-row REST page, which is five small requests. A
/// reader that asked per repository would be spending a request on each of the
/// thirty-odd repositories a real day touches, for two numbers.
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
    static func graphQL(
        _ url: URL, query: String, token: String, header: String, scheme: String?
    ) async throws -> [String: Any] {
        var request = request(url, token: token, header: header, scheme: scheme)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])
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
    /// four searches together cost 1.
    static func document(now: Date) -> String {
        let contributions = UsagePeriod.allCases.map { period in
            let range =
                ForgeWindow.start(of: period, now: now)
                .map { "(from: \"\(ForgeWindow.iso.string(from: $0))\")" } ?? ""
            let alias = ForgeAlias.contributions(period)
            return "\(alias): contributionsCollection\(range) { \(calendarField) }"
        }
        let merged = UsagePeriod.allCases.map { period in
            let scope =
                ForgeWindow.start(of: period, now: now)
                .map { " merged:>=\(ForgeWindow.timestamp.string(from: $0))" } ?? ""
            let alias = ForgeAlias.merged(period)
            let terms = "is:pr author:@me is:merged\(scope)"
            return "\(alias): search(query: \"\(terms)\", type: ISSUE, first: 1) { issueCount }"
        }
        return """
            query {
              viewer { login \(contributions.joined(separator: " ")) }
              \(merged.joined(separator: "\n  "))
            }
            """
    }

    private static let calendarField = "contributionCalendar { totalContributions }"

    static func parse(
        _ payload: [String: Any], connection: ForgeConnection, now: Date
    ) throws -> ForgeActivityReading {
        guard let viewer = payload["viewer"] as? [String: Any],
            let login = viewer["login"] as? String, !login.isEmpty
        else { throw ForgeReadFailure.malformed }
        var contributions: [UsagePeriod: Int] = [:]
        var merged: [UsagePeriod: Int] = [:]
        for period in UsagePeriod.allCases {
            if let block = viewer[ForgeAlias.contributions(period)] as? [String: Any],
                let calendar = block["contributionCalendar"] as? [String: Any],
                let total = calendar["totalContributions"] as? Int
            {
                contributions[period] = total
            }
            if let block = payload[ForgeAlias.merged(period)] as? [String: Any],
                let count = block["issueCount"] as? Int
            {
                merged[period] = count
            }
        }
        // A reply that named the account and no figure at all is a shape this
        // build does not understand rather than a quiet week.
        guard !contributions.isEmpty || !merged.isEmpty else { throw ForgeReadFailure.malformed }
        return ForgeActivityReading(
            id: connection.id, kind: connection.kind, host: connection.host, login: login,
            activity: ForgeActivity(
                contributions: contributions, merged: merged,
                contributionsBoundedToOneYear: true),
            readAt: now, failure: nil)
    }

}

/// GitLab's half: one GraphQL query for the merged counts, and one header read
/// per period for the activity total.
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
        var contributions: [UsagePeriod: Int] = [:]
        for period in UsagePeriod.allCases {
            contributions[period] = try await events(
                connection, token: token, period: period, now: now)
        }
        return ForgeActivityReading(
            id: connection.id, kind: connection.kind, host: connection.host, login: merged.username,
            activity: ForgeActivity(
                contributions: contributions, merged: merged.counts,
                contributionsBoundedToOneYear: false),
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
                .map { ", mergedAfter: \"\(ForgeWindow.iso.string(from: $0))\"" } ?? ""
            return "\(ForgeAlias.merged(period)): authoredMergeRequests(state: merged\(scope)) { count }"
        }
        return """
            query {
              currentUser { username \(fields.joined(separator: " ")) }
            }
            """
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
    static func eventsURL(_ connection: ForgeConnection, period: UsagePeriod, now: Date) -> URL? {
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
        components.queryItems = query
        return components.url
    }

    private static func events(
        _ connection: ForgeConnection, token: String, period: UsagePeriod, now: Date
    ) async throws -> Int? {
        guard let url = eventsURL(connection, period: period, now: now) else {
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
