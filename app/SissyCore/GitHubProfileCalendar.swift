import Foundation

/// The squares a `github.com` profile draws, read from the fragment the
/// profile page loads them from: `https://github.com/users/<login>/contributions`.
///
/// **This, not `contributionCalendar`, is the number on the profile.** Measured
/// 2026-10-13 for one account, with the token's own GraphQL calendar against the
/// profile: 133 against 145 on 11 Oct, 129 against 142 on 12 Oct, and 6 896
/// against 7 026 over the last year. Quiet days agree to the unit (2/2 on
/// 30 Sep, 4/4 on 4 Oct), so the dates are the same and the gap is private
/// work: on 12 Oct both counted the same 8 commits and 7 pull requests in
/// public, and the profile 127 private contributions where the API's
/// `restrictedContributionsCount` gave 114.
///
/// **One request, no token, a year a day at a time.** The fragment carries the
/// profile's own last year, 53 weeks ending today, and one calendar year with
/// `from=YYYY-01-01&to=YYYY-12-31`: measured 2026-10-13, any other pair of
/// dates is widened to the calendar year it starts in. So every window the
/// panel asks for, a picked span included, is cut out of the squares here, and
/// only a day older than the last year costs a request of its own. It is a web
/// route rather than an API one and carries no credential, because the profile
/// is what a stranger sees. 240 KB of HTML, 21 KB as it travels compressed.
///
/// **The profile counts private work only while its owner lets it.** A profile
/// with "Private contributions" switched off draws public work alone, and no
/// published figure then counts what the token can see. That case is told by
/// comparison rather than read, since the fragment says nothing about the
/// setting: over the 365 days ending yesterday the profile has to read at least
/// what the token's own calendar does, and one that reads less is hiding work,
/// so the token's figure is the answer for that reading. Yesterday, because a
/// contribution reaches the API before the profile is rebuilt, and a busy
/// minute today must not tip an account over. The off case was not measured.
///
/// **A fragment this build cannot read is no figure, never the API's.** The
/// parse proves itself: every square needs a count, and the counts have to add
/// up to the total the fragment prints over them. Anything short of that is
/// `ForgeReadFailure.malformed`, and a contributions figure that fell back to
/// the token's would put the old, lower number back on the row with nothing to
/// say the fragment had changed shape.
///
/// `all` is the profile's own last year, 53 weeks ending today, which is what
/// the heading over the squares counts; the token's calendar answered a year
/// to the instant, a few days fewer.
///
/// A refusal here is never the token's, since none was sent: anything but a
/// rate limit or a redirect is `malformed`, so a profile that will not answer
/// cannot park a connection as needing a new token.
///
/// `github.com` only. An Enterprise install serves the same page, but behind
/// its own sign-in, which a request with no credential cannot pass and a token
/// is not accepted on; there the token's calendar stays the figure.
enum GitHubProfileCalendar {
    private static let root = URL(string: "https://github.com/users")!
    /// How many days the comparison with the token's calendar runs over, which
    /// is the widest window that calendar takes in one field.
    static let checkDays = 365
    /// How many calendar years one reading may fetch beyond the last year,
    /// which a picked span of `ForgeSpanFeed`'s ten years at most stays inside.
    static let yearLimit = 11
    /// The alias the token's count over the comparison days comes back under.
    static let checkAlias = "profileCheck"

    /// What the profile drew for each day, keyed `yyyy-MM-dd`.
    struct Squares: Sendable, Equatable {
        let days: [String: Int]
        /// The first day of the profile's own "in the last year".
        let lastYearFrom: String

        /// The sum over `first...last`, nil when a day in it was not drawn.
        func total(from first: String, through last: String) -> Int? {
            var sum = 0
            for day in GitHubProfileCalendar.dayNames(from: first, through: last) {
                guard let count = days[day] else { return nil }
                sum += count
            }
            return sum
        }
    }

    static func url(login: String, year: Int? = nil) -> URL? {
        let page = root.appendingPathComponent(login).appendingPathComponent("contributions")
        guard let year else { return page }
        var components = URLComponents(url: page, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "from", value: String(format: "%04d-01-01", year)),
            URLQueryItem(name: "to", value: String(format: "%04d-12-31", year)),
        ]
        return components?.url
    }

    /// The first and last day the comparison with the token's calendar covers.
    static func checkRange(now: Date, calendar: Calendar = .current) -> (first: Date, last: Date)? {
        let today = calendar.startOfDay(for: now)
        guard let first = calendar.date(byAdding: .day, value: -checkDays, to: today),
            let last = calendar.date(byAdding: .day, value: -1, to: today)
        else { return nil }
        return (first, last)
    }

    /// The field that asks the token's calendar for the comparison days.
    static func checkField(now: Date, calendar: Calendar = .current) -> String? {
        guard let range = checkRange(now: now, calendar: calendar) else { return nil }
        let from = ForgeWindow.vendorDay(range.first, calendar: calendar)
        let to = ForgeWindow.vendorDayEnd(range.last, calendar: calendar)
        return "\(checkAlias): contributionsCollection(from: \"\(from)\", to: \"\(to)\")"
            + " { contributionCalendar { totalContributions } }"
    }

    static func tokenCount(_ viewer: [String: Any]) -> Int? {
        guard let block = viewer[checkAlias] as? [String: Any],
            let calendar = block["contributionCalendar"] as? [String: Any],
            let total = calendar["totalContributions"] as? Int, total >= 0
        else { return nil }
        return total
    }

    /// The profile's squares over `first...last` and the comparison days, or
    /// nil where the token's figure answers: a profile that hides the private
    /// work the token counts, or a token calendar that did not answer the
    /// comparison, which leaves nothing to tell the two cases apart with and
    /// is the API's failure rather than the profile's.
    static func read(
        login: String, from first: String, through last: String, tokenCount: Int?,
        now: Date, calendar: Calendar = .current
    ) async throws -> Squares? {
        guard let tokenCount else { return nil }
        guard let check = checkRange(now: now, calendar: calendar) else {
            throw ForgeReadFailure.malformed
        }
        let checkFirst = ForgeWindow.dayName(check.first, calendar: calendar)
        let checkLast = ForgeWindow.dayName(check.last, calendar: calendar)
        let squares = try await fetch(
            login: login, from: min(first, checkFirst), through: max(last, checkLast))
        guard let profileCount = squares.total(from: checkFirst, through: checkLast) else {
            throw ForgeReadFailure.malformed
        }
        return decide(squares, profileCount: profileCount, tokenCount: tokenCount)
    }

    /// The squares when the profile counts at least what the token does.
    static func decide(_ squares: Squares, profileCount: Int, tokenCount: Int) -> Squares? {
        profileCount >= tokenCount ? squares : nil
    }

    /// The last year, and every calendar year a day of `first...last` falls in
    /// that the last year does not reach.
    private static func fetch(login: String, from first: String, through last: String)
        async throws -> Squares
    {
        guard let page = url(login: login) else { throw ForgeReadFailure.malformed }
        let lastYear = try await days(at: page)
        guard let lastYearFrom = lastYear.keys.min() else { throw ForgeReadFailure.malformed }
        let years = Set(
            dayNames(from: first, through: last).filter { lastYear[$0] == nil }
                .compactMap { Int($0.prefix(4)) })
        guard years.count <= yearLimit else { throw ForgeReadFailure.malformed }
        var days = lastYear
        for year in years.sorted() {
            guard let page = url(login: login, year: year) else { throw ForgeReadFailure.malformed }
            days.merge(try await self.days(at: page)) { kept, _ in kept }
            try Task.checkCancellation()
        }
        return Squares(days: days, lastYearFrom: lastYearFrom)
    }

    private static func days(at url: URL) async throws -> [String: Int] {
        var request = URLRequest(url: url, timeoutInterval: ForgeActivityFeed.requestTimeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue(ForgeActivityFeed.userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await SissyHTTP.data(for: request)
        } catch {
            throw ForgeActivityFeed.failure(thrown: error)
        }
        guard let http = response as? HTTPURLResponse else { throw ForgeReadFailure.malformed }
        if let failure = ForgeActivityFeed.failure(of: http, addressedTo: url) {
            throw failure == .rateLimited || failure == .redirected ? failure : ForgeReadFailure.malformed
        }
        guard let html = String(data: data, encoding: .utf8) else { throw ForgeReadFailure.malformed }
        return try parse(html)
    }

    private static let cellPattern = try? NSRegularExpression(pattern: #"<td\b[^>]*>"#)
    private static let datePattern = try? NSRegularExpression(
        pattern: #"\bdata-date="(\d{4}-\d{2}-\d{2})""#)
    private static let idPattern = try? NSRegularExpression(pattern: #"\sid="([^"]+)""#)
    private static let tipPattern = try? NSRegularExpression(
        pattern: #"<tool-tip\b[^>]*\sfor="([^"]+)"[^>]*>([^<]*)</tool-tip>"#)
    private static let countPattern = try? NSRegularExpression(
        pattern: #"^\s*(No|[0-9][0-9,]*) contributions? on "#)
    private static let headerPattern = try? NSRegularExpression(
        pattern: #"id="js-contribution-activity-description"[^>]*>\s*([0-9][0-9,]*)\s+contributions?\b"#)

    /// Every square's count, keyed by its date, or `malformed` for a fragment
    /// that does not prove itself: a square with no count, a count that will
    /// not read, or counts that do not add up to the total printed over them.
    static func parse(_ html: String) throws -> [String: Int] {
        guard let cellPattern, let datePattern, let idPattern, let tipPattern, let countPattern,
            let headerPattern
        else { throw ForgeReadFailure.malformed }
        var counts: [String: Int] = [:]
        for match in matches(tipPattern, in: html) {
            guard let target = group(1, of: match, in: html), let text = group(2, of: match, in: html),
                let count = countPattern.firstMatch(
                    in: text, range: NSRange(text.startIndex..., in: text)
                ).flatMap({ group(1, of: $0, in: text) })
            else { continue }
            counts[target] = count == "No" ? 0 : number(count)
        }
        var days: [String: Int] = [:]
        for match in matches(cellPattern, in: html) {
            guard let cell = Range(match.range, in: html).map({ String(html[$0]) }),
                let date = datePattern.firstMatch(in: cell, range: NSRange(cell.startIndex..., in: cell))
                    .flatMap({ group(1, of: $0, in: cell) })
            else { continue }
            guard
                let id = idPattern.firstMatch(in: cell, range: NSRange(cell.startIndex..., in: cell))
                    .flatMap({ group(1, of: $0, in: cell) }),
                let count = counts[id], days[date] == nil
            else { throw ForgeReadFailure.malformed }
            days[date] = count
        }
        guard !days.isEmpty,
            let header = headerPattern.firstMatch(in: html, range: NSRange(html.startIndex..., in: html))
                .flatMap({ group(1, of: $0, in: html) }).flatMap(number),
            days.values.reduce(0, +) == header
        else { throw ForgeReadFailure.malformed }
        return days
    }

    /// `yyyy-MM-dd` for every day from `first` through `last`, inclusive.
    static func dayNames(from first: String, through last: String) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd"
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .gmt
        guard var cursor = formatter.date(from: first), let end = formatter.date(from: last) else {
            return []
        }
        var names: [String] = []
        while cursor <= end {
            names.append(formatter.string(from: cursor))
            guard let next = gregorian.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return names
    }

    private static func matches(_ pattern: NSRegularExpression, in text: String) -> [NSTextCheckingResult] {
        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func group(_ index: Int, of match: NSTextCheckingResult, in text: String) -> String? {
        Range(match.range(at: index), in: text).map { String(text[$0]) }
    }

    private static func number(_ text: String) -> Int? {
        Int(text.replacingOccurrences(of: ",", with: ""))
    }
}
