import Foundation

/// The four dated figures. Contributions have no switch in the existing forge
/// settings; the other three follow their existing ForgeCounter switches.
enum ForgeSpanMetric: String, Sendable, Equatable, CaseIterable {
    case contributions
    case merged
    case issues
    case comments

    func isEnabled(in counters: Set<ForgeCounter>) -> Bool {
        switch self {
        case .contributions: true
        case .merged: counters.contains(.merged)
        case .issues: counters.contains(.issues)
        case .comments: counters.contains(.comments)
        }
    }
}

/// One counter over picked dates. An absence never stands in for a measured zero.
enum ForgeSpanCounter: Sendable, Equatable {
    case counted(ForgeEventCount)
    case unavailable(ForgeSpanAbsence)
}

/// Why a picked window has no figure, including a page that cannot prove coverage.
enum ForgeSpanAbsence: Error, Sendable, Equatable {
    case switchedOff
    case missingScope
    case incomplete
    case invalidDates
    case deadlineExceeded
    case monitorChanged
    case failure(ForgeReadFailure)
}

/// One connection's counters over inclusive local dates, kept separate from the poll.
/// The login comes from this fetch's vendor reply, never from a CLI configuration.
struct ForgeSpanReading: Sendable, Equatable, Identifiable {
    let id: String
    let kind: ForgeKind
    let host: String
    let login: String?
    let from: Date
    let to: Date
    let readAt: Date
    var counters: [ForgeSpanMetric: ForgeSpanCounter]

    var isCacheable: Bool {
        !counters.values.contains { counter in
            switch counter {
            case .unavailable(.failure), .unavailable(.deadlineExceeded), .unavailable(.monitorChanged): true
            default: false
            }
        }
    }

    static func unavailable(
        _ connection: ForgeConnection, dates: (Date, Date), now: Date,
        enabled: Set<ForgeCounter>, reason: ForgeSpanAbsence
    ) -> Self {
        Self(
            id: connection.id, kind: connection.kind, host: connection.address, login: nil,
            from: dates.0, to: dates.1, readAt: now,
            counters: Dictionary(
                uniqueKeysWithValues: ForgeSpanFeed.counters.map {
                    ($0, .unavailable($0.isEnabled(in: enabled) ? reason : .switchedOff))
                }))
    }
}

/// On-demand counters only: no event line, billing request, or change to periodic readings.
enum ForgeSpanFeed {
    /// A picked span in the forms each vendor takes it, all over the local
    /// days the user picked.
    struct VendorBounds: Hashable {
        /// The local midnight the first day starts at.
        let start: Date
        /// The local midnight after the last day, or now where that is sooner.
        let end: Date
        /// Whether the span reaches now, so `end` is the instant of the read
        /// rather than an exclusive midnight.
        let isOpen: Bool
        /// The first and last local dates, `yyyy-MM-dd`.
        let firstDay: String
        let lastDay: String
        /// The same two dates as GitHub's contribution calendar reads them:
        /// the first at midnight `Z`, the last at its final second.
        let calendarStart: Date
        let calendarEnd: Date

        /// The last instant an inclusive filter may name.
        var lastInstant: Date { isOpen ? end : end.addingTimeInterval(-1) }
    }
    static let counters: [ForgeSpanMetric] = [.contributions, .merged, .issues, .comments]

    /// Every figure is over the local days picked, from local midnight to
    /// local midnight, because that is how the vendors date the work: GitHub
    /// files a contribution on the account's own day and its calendar takes the
    /// dates (`ForgeWindow.vendorDay`), while its searches, GitLab's GraphQL
    /// filters and GitLab's event rows compare instants (`ForgeWindow.instant`,
    /// `GitLabDaySplit`). Today's end is capped at now.
    ///
    /// GitHub's search takes the span as one inclusive `A..B` range: measured
    /// 2026-10-07, it ORs a repeated qualifier, and `merged:>=A merged:<B`
    /// counted every merged pull request the account ever authored (975)
    /// where the range counted 8. GitLab's `mergedBefore` widens an instant to
    /// the end of its UTC day (read in its source 2026-10-03, measured
    /// 2026-10-07: 78 merges before `21:59:59Z` against the 75 there were), so
    /// a past span's merges are the count after its start less the count after
    /// its end, both of which `mergedAfter` takes to the second.
    static func bounds(
        from: Date, to: Date, now: Date, calendar: Calendar = .current
    ) -> VendorBounds? {
        let firstDay = calendar.startOfDay(for: from)
        let lastDay = calendar.startOfDay(for: to)
        guard firstDay <= lastDay, lastDay <= calendar.startOfDay(for: now),
            let days = calendar.dateComponents([.day], from: firstDay, to: lastDay).day,
            days < 3650,
            let next = calendar.date(byAdding: .day, value: 1, to: lastDay)
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd"
        let firstName = ForgeWindow.dayName(from, calendar: calendar)
        let lastName = ForgeWindow.dayName(to, calendar: calendar)
        guard let calendarStart = formatter.date(from: firstName),
            let calendarLast = formatter.date(from: lastName)
        else { return nil }
        return VendorBounds(
            start: firstDay, end: min(next, now), isOpen: next > now,
            firstDay: firstName, lastDay: lastName,
            calendarStart: calendarStart, calendarEnd: calendarLast.addingTimeInterval(86_399))
    }

    static func read(
        _ connection: ForgeConnection, token: String, counters enabled: Set<ForgeCounter>,
        from: Date, to: Date, now: Date = Date()
    ) async throws -> ForgeSpanReading {
        guard let bounds = bounds(from: from, to: to, now: now) else {
            return .unavailable(
                connection, dates: (from, to), now: now,
                enabled: enabled, reason: .invalidDates)
        }
        switch connection.kind {
        case .gitHub:
            guard let endpoint = GitHubActivityFeed.endpoint(connection) else {
                throw ForgeReadFailure.malformed
            }
            let reply = try await graphQL(
                endpoint,
                query: githubDocument(
                    from: from, to: to, now: now, counters: enabled), token: token, kind: .gitHub)
            return try parseGitHub(
                reply.data, failures: reply.failures, connection: connection,
                dates: (from, to), now: now, counters: enabled)
        case .gitLab:
            return try await readGitLab(
                connection, token: token, counters: enabled,
                dates: (from, to), now: now)
        }
    }

    private static func readGitLab(
        _ connection: ForgeConnection, token: String, counters enabled: Set<ForgeCounter>,
        dates: (Date, Date), now: Date
    ) async throws -> ForgeSpanReading {
        let (from, to) = dates
        var reading = ForgeSpanReading.unavailable(
            connection, dates: dates,
            now: now, enabled: enabled, reason: .failure(.malformed))
        guard let root = connection.root else { throw ForgeReadFailure.malformed }
        let endpoint = root.appendingPathComponent("/api/graphql")
        let reply = try await graphQL(
            endpoint,
            query: gitlabDocument(
                from: from, to: to, now: now, counters: enabled), token: token, kind: .gitLab)
        let login = try GitLabActivityFeed.username(from: reply.data)
        reading = ForgeSpanReading(
            id: reading.id, kind: reading.kind, host: reading.host, login: login,
            from: from, to: to, readAt: now, counters: reading.counters)
        if enabled.contains(.merged) {
            reading.counters[.merged] = gitlabMerged(
                reply.data["currentUser"] as? [String: Any] ?? [:], failures: reply.failures,
                isOpen: bounds(from: from, to: to, now: now)?.isOpen ?? true)
        }
        if enabled.contains(.issues) {
            do {
                let issues = try await graphQL(
                    endpoint,
                    query: gitlabIssuesDocument(
                        from: from, to: to, now: now), variables: ["author": login],
                    token: token, kind: .gitLab)
                reading.counters[.issues] = count(
                    issues.data, alias: "issues", failures: issues.failures)
            } catch {
                try Task.checkCancellation()
                reading.counters[.issues] = .unavailable(absence(error))
            }
        }
        guard let bounds = bounds(from: from, to: to, now: now) else { return reading }
        for counter in [ForgeSpanMetric.contributions, .comments] where counter.isEnabled(in: enabled) {
            do {
                reading.counters[counter] = try await gitlabEvents(
                    connection, token: token, bounds: bounds,
                    action: counter == .comments ? GitLabActivityFeed.commentedAction : nil)
            } catch {
                try Task.checkCancellation()
                reading.counters[counter] = .unavailable(absence(error))
            }
        }
        try Task.checkCancellation()
        return reading
    }

    /// At most 365 UTC days per contribution field, so multi-year picks stay
    /// inside GitHub's one-year limit without overlapping a calendar bucket.
    /// Constructed three-year and 3650-day picks verified 2026-10-03; no
    /// multi-year vendor reply was measured. At most ten year-sized fields
    /// are requested, and longer picks are invalid rather than truncated.
    static func contributionRanges(start: Date, end: Date) -> [(Date, Date)] {
        guard start <= end, end.timeIntervalSince(start) < 3650 * 86400 else { return [] }
        var ranges: [(Date, Date)] = []
        var cursor = start
        while cursor <= end {
            let last = min(cursor.addingTimeInterval(365 * 86400 - 1), end)
            ranges.append((cursor, last))
            cursor = last.addingTimeInterval(1)
        }
        return ranges
    }

    static func githubDocument(
        from: Date, to: Date, now: Date, counters enabled: Set<ForgeCounter>,
        calendar: Calendar = .current
    ) -> String {
        guard let bounds = bounds(from: from, to: to, now: now, calendar: calendar)
        else { return GitHubActivityFeed.probeDocument }
        let iso = ISO8601DateFormatter()
        var viewer = ["login"]
        do {
            for (index, range) in contributionRanges(start: bounds.calendarStart, end: bounds.calendarEnd)
                .enumerated()
            {
                viewer.append(
                    "contrib\(index): contributionsCollection(from: \"\(iso.string(from: range.0))\", to: \"\(iso.string(from: range.1))\") { contributionCalendar { totalContributions } }"
                )
            }
        }
        if enabled.contains(.comments) {
            viewer.append(
                "comments: issueComments(first: 100, orderBy: {field: UPDATED_AT, direction: DESC}) { pageInfo { hasNextPage } nodes { createdAt updatedAt } }"
            )
        }
        var fields: [String] = []
        for (counter, terms, qualifier) in [
            (ForgeSpanMetric.merged, "is:pr author:@me is:merged", "merged"),
            (.issues, "is:issue author:@me", "created"),
        ] where counter.isEnabled(in: enabled) {
            let dates =
                "\(qualifier):\(ForgeWindow.instant(bounds.start))..\(ForgeWindow.instant(bounds.lastInstant))"
            fields.append(
                "\(counter.rawValue): search(query: \"\(terms) \(dates)\", type: ISSUE, first: 1) { issueCount }"
            )
        }
        return "query { viewer { \(viewer.joined(separator: " ")) } \(fields.joined(separator: " ")) }"
    }

    static func gitlabDocument(
        from: Date, to: Date, now: Date, counters enabled: Set<ForgeCounter>,
        calendar: Calendar = .current
    ) -> String {
        var fields = ""
        if enabled.contains(.merged),
            let bounds = bounds(from: from, to: to, now: now, calendar: calendar)
        {
            fields =
                "merged: authoredMergeRequests(state: merged, mergedAfter: \"\(ForgeWindow.instant(bounds.start))\") { count }"
            if !bounds.isOpen {
                fields +=
                    " \(mergedLaterAlias): authoredMergeRequests(state: merged, mergedAfter: \"\(ForgeWindow.instant(bounds.end))\") { count }"
            }
        }
        return "query { currentUser { username \(fields) } }"
    }

    static func gitlabIssuesDocument(
        from: Date, to: Date, now: Date, calendar: Calendar = .current
    ) -> String {
        guard let bounds = bounds(from: from, to: to, now: now, calendar: calendar) else { return "" }
        let last = ISO8601DateFormatter()
        last.formatOptions.insert(.withFractionalSeconds)
        let upper = bounds.isOpen ? now : bounds.end.addingTimeInterval(-0.001)
        return
            "query($author: String!) { issues: issues(authorUsername: $author, createdAfter: \"\(ForgeWindow.instant(bounds.start))\", createdBefore: \"\(last.string(from: upper))\") { count } }"
    }

    /// The alias the merges after a past span's end come back under.
    static let mergedLaterAlias = "mergedLater"

    /// A span's merges: the count after its start, less the count after its
    /// end for a span that has ended. A missing second count is no figure,
    /// never the first count standing in for the span.
    static func gitlabMerged(
        _ user: [String: Any], failures: [String: ForgeSpanAbsence], isOpen: Bool
    ) -> ForgeSpanCounter {
        let since = count(user, alias: "merged", failures: failures)
        if isOpen { return since }
        switch (since, count(user, alias: mergedLaterAlias, failures: failures)) {
        case (.counted(.exact(let all)), .counted(.exact(let after))) where all >= after:
            return .counted(.exact(all - after))
        case (.unavailable(let reason), _), (_, .unavailable(let reason)):
            return .unavailable(reason)
        default:
            return .unavailable(.incomplete)
        }
    }

    /// The events over a span: those since its start less those since its end,
    /// each counted from its own instant by `GitLabActivityFeed.events`.
    private static func gitlabEvents(
        _ connection: ForgeConnection, token: String, bounds: VendorBounds, action: String?
    ) async throws -> ForgeSpanCounter {
        let since = try await GitLabActivityFeed.events(
            connection, token: token, since: bounds.start, action: action
        ).count
        guard let since else { return .unavailable(.failure(.malformed)) }
        if bounds.isOpen { return .counted(since) }
        let after = try await GitLabActivityFeed.events(
            connection, token: token, since: bounds.end, action: action
        ).count
        switch after {
        case .exact(let later):
            return since.adding(-later).map(ForgeSpanCounter.counted) ?? .unavailable(.incomplete)
        case .atLeast: return .unavailable(.incomplete)
        case nil: return .unavailable(.failure(.malformed))
        }
    }

    static func parseGitHub(
        _ payload: [String: Any], failures: [String: ForgeSpanAbsence] = [:],
        connection: ForgeConnection, dates: (Date, Date), now: Date,
        counters enabled: Set<ForgeCounter>, calendar: Calendar = .current
    ) throws -> ForgeSpanReading {
        let (from, to) = dates
        guard let bounds = bounds(from: from, to: to, now: now, calendar: calendar),
            !contributionRanges(start: bounds.calendarStart, end: bounds.calendarEnd).isEmpty
        else {
            return .unavailable(connection, dates: dates, now: now, enabled: enabled, reason: .invalidDates)
        }
        if let reason = failures["viewer"], payload["viewer"] as? [String: Any] == nil {
            return .unavailable(connection, dates: dates, now: now, enabled: enabled, reason: reason)
        }
        let login = try GitHubActivityFeed.login(fromProbe: payload)
        let viewer = payload["viewer"] as? [String: Any] ?? [:]
        var reading = ForgeSpanReading.unavailable(
            connection, dates: (from, to), now: now, enabled: enabled,
            reason: .failure(.malformed))
        reading = ForgeSpanReading(
            id: reading.id, kind: reading.kind, host: reading.host,
            login: login, from: from, to: to, readAt: now, counters: reading.counters)
        do {
            var total = 0
            var missing: ForgeSpanAbsence?
            for index in contributionRanges(start: bounds.calendarStart, end: bounds.calendarEnd).indices {
                let alias = "contrib\(index)"
                guard let block = viewer[alias] as? [String: Any],
                    let contribution = block["contributionCalendar"] as? [String: Any],
                    let value = contribution["totalContributions"] as? Int, value >= 0
                else {
                    missing =
                        failures[alias] ?? failures["contributionsCollection"] ?? failures["viewer"]
                        ?? failures["*"] ?? .failure(.malformed)
                    break
                }
                total += value
            }
            reading.counters[.contributions] =
                missing.map(ForgeSpanCounter.unavailable)
                ?? .counted(.exact(total))
        }
        for counter in [ForgeSpanMetric.merged, .issues] where counter.isEnabled(in: enabled) {
            reading.counters[counter] = count(
                payload, alias: counter.rawValue,
                failures: failures, field: "issueCount")
        }
        if enabled.contains(.comments) {
            reading.counters[.comments] =
                (failures["comments"] ?? failures["viewer"] ?? failures["*"]).map(
                    ForgeSpanCounter.unavailable)
                ?? commentCount(
                    viewer, start: bounds.start, end: bounds.end, inclusiveEnd: bounds.isOpen)
        }
        return reading
    }

    /// A page proves a past span only when it reaches before the span's start;
    /// recent edits cannot make an old comment disappear from that proof.
    static func commentCount(_ viewer: [String: Any], start: Date, end: Date, inclusiveEnd: Bool = false)
        -> ForgeSpanCounter
    {
        guard let block = viewer["comments"] as? [String: Any],
            let nodes = block["nodes"] as? [[String: Any]]
        else { return .unavailable(.failure(.malformed)) }
        let stamps = nodes.compactMap { node -> (Date, Date)? in
            guard let created = (node["createdAt"] as? String).flatMap(UsageReaderShared.parseTimestamp),
                let updated = (node["updatedAt"] as? String).flatMap(UsageReaderShared.parseTimestamp)
            else { return nil }
            return (created, updated)
        }
        let unread = (block["pageInfo"] as? [String: Any])?["hasNextPage"] as? Bool ?? true
        guard stamps.count == nodes.count else { return .unavailable(.failure(.malformed)) }
        guard !unread || (stamps.map(\.1).min().map { $0 < start } ?? false)
        else { return .unavailable(.incomplete) }
        return .counted(
            .exact(stamps.filter { $0.0 >= start && (inclusiveEnd ? $0.0 <= end : $0.0 < end) }.count))
    }

    static func count(
        _ payload: [String: Any], alias: String, failures: [String: ForgeSpanAbsence],
        field: String = "count"
    ) -> ForgeSpanCounter {
        guard let block = payload[alias] as? [String: Any],
            let value = block[field] as? Int, value >= 0
        else { return .unavailable(failures[alias] ?? failures["*"] ?? .failure(.malformed)) }
        return .counted(.exact(value))
    }

    static func absence(_ error: Error) -> ForgeSpanAbsence {
        (error as? ForgeSpanAbsence) ?? .failure((error as? ForgeReadFailure) ?? .malformed)
    }

    /// Partial GraphQL errors stay beside their fields, so a missing scope
    /// cannot discard successful counters or become a quiet day.
    static func decode(_ root: [String: Any]) throws -> (
        data: [String: Any], failures: [String: ForgeSpanAbsence]
    ) {
        var failures: [String: ForgeSpanAbsence] = [:]
        for error in root["errors"] as? [[String: Any]] ?? [] {
            let type = error["type"] as? String
            if type == "RATE_LIMITED" { throw ForgeReadFailure.rateLimited }
            if type == "UNAUTHORIZED" { throw ForgeReadFailure.unauthorized }
            let message = (error["message"] as? String ?? "").lowercased()
            let reason: ForgeSpanAbsence =
                type == "FORBIDDEN" || type == "INSUFFICIENT_SCOPES"
                    || (type == nil && message.contains("scope")) ? .missingScope : .failure(.malformed)
            let path = (error["path"] as? [Any] ?? []).compactMap { $0 as? String }
            if path.isEmpty { failures["*"] = reason }
            let field =
                path.first {
                    ["merged", "issues", "comments", "contributionsCollection"].contains($0)
                        || $0.hasPrefix("contrib")
                } ?? path.last
            if let field { failures[field] = reason }
        }
        guard let data = root["data"] as? [String: Any] else {
            throw failures["*"] ?? failures["viewer"] ?? .failure(.malformed)
        }
        return (data, failures)
    }

    private static func graphQL(
        _ url: URL, query: String, variables: [String: String] = [:], token: String, kind: ForgeKind
    ) async throws -> (data: [String: Any], failures: [String: ForgeSpanAbsence]) {
        var request = ForgeActivityFeed.request(
            url, token: token,
            header: kind == .gitHub ? "Authorization" : "PRIVATE-TOKEN",
            scheme: kind == .gitHub ? "Bearer" : nil)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query, "variables": variables,
        ])
        let reply = try await ForgeActivityFeed.send(request)
        try Task.checkCancellation()
        guard let root = try JSONSerialization.jsonObject(with: reply.data) as? [String: Any]
        else { throw ForgeReadFailure.malformed }
        if let refusal = ForgeActivityFeed.fileGraphQLRefusal(
            root, reply: reply.response, url: url, token: token)
        {
            throw refusal
        }
        return try decode(root)
    }
}
