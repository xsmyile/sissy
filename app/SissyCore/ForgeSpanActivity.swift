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
    case notOpened
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
    /// UTC request boundaries, not the engine's selected-window value.
    struct VendorBounds: Hashable {
        let start: Date
        let end: Date
        let after: String
        let before: String
        let upper: Date
    }
    static let counters: [ForgeSpanMetric] = [.contributions, .merged, .issues, .comments]

    /// Dates follow the mapping measured by ForgeWindow on 2026-09-17.
    /// Verified with constructed requests 2026-10-03: a past span stops before
    /// the following UTC midnight. GitHub's calendar and its searches both end
    /// at 23:59:59 UTC on the named final date: a search takes the window as
    /// one inclusive `A..B` range, because measured 2026-10-07 GitHub ORs a
    /// repeated qualifier, and `merged:>=A merged:<B` counted every merged
    /// pull request the account ever authored (975) where the range counted 8.
    /// Today's end is capped at now. GitLab events use the following date as
    /// their proposed exclusive before boundary and the preceding date as after.
    /// GitLab's GraphQL upper filters are inclusive, read in its source on
    /// 2026-10-03: `mergedBefore` widens a time to the end of its UTC day and
    /// `createdBefore` compares with `<=`, so both take the final date's last
    /// instant rather than the exclusive next midnight.
    static func bounds(
        from: Date, to: Date, now: Date, calendar: Calendar = .current
    ) -> VendorBounds? {
        let firstDay = calendar.startOfDay(for: from)
        let lastDay = calendar.startOfDay(for: to)
        guard firstDay <= lastDay, lastDay <= calendar.startOfDay(for: now),
            let days = calendar.dateComponents([.day], from: firstDay, to: lastDay).day,
            days < 3650,
            let zone = TimeZone(secondsFromGMT: 0)
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let startName = formatter.string(from: from)
        let endName = formatter.string(from: to)
        formatter.timeZone = zone
        guard let start = formatter.date(from: startName),
            let last = formatter.date(from: endName)
        else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = zone
        guard let next = utc.date(byAdding: .day, value: 1, to: last),
            let previous = utc.date(byAdding: .day, value: -1, to: start)
        else { return nil }
        return VendorBounds(
            start: start, end: min(next.addingTimeInterval(-1), now),
            after: formatter.string(from: previous), before: formatter.string(from: next),
            upper: min(next, now))
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
        guard bounds.start <= now else {
            return .unavailable(
                connection, dates: (from, to), now: now,
                enabled: enabled, reason: .notOpened)
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
            let user = reply.data["currentUser"] as? [String: Any] ?? [:]
            reading.counters[.merged] = count(user, alias: "merged", failures: reply.failures)
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
        for counter in [ForgeSpanMetric.contributions, .comments] where counter.isEnabled(in: enabled) {
            do {
                guard
                    let url = gitlabEventsURL(
                        connection, dates: dates, now: now,
                        action: counter == .comments ? GitLabActivityFeed.commentedAction : nil)
                else { throw ForgeReadFailure.malformed }
                let request = ForgeActivityFeed.request(
                    url, token: token, header: "PRIVATE-TOKEN", scheme: nil)
                let response = try await ForgeActivityFeed.send(request).response
                reading.counters[counter] =
                    GitLabActivityFeed.count(of: response)
                    .map(ForgeSpanCounter.counted) ?? .unavailable(.failure(.malformed))
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
        guard let bounds = bounds(from: from, to: to, now: now, calendar: calendar),
            bounds.start <= bounds.end
        else { return GitHubActivityFeed.probeDocument }
        let iso = ISO8601DateFormatter()
        var viewer = ["login"]
        do {
            for (index, range) in contributionRanges(start: bounds.start, end: bounds.end).enumerated() {
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
            let dates = "\(qualifier):\(iso.string(from: bounds.start))..\(iso.string(from: bounds.end))"
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
            let iso = ISO8601DateFormatter()
            fields =
                "merged: authoredMergeRequests(state: merged, mergedAfter: \"\(iso.string(from: bounds.start))\", mergedBefore: \"\(iso.string(from: bounds.end))\") { count }"
        }
        return "query { currentUser { username \(fields) } }"
    }

    static func gitlabIssuesDocument(
        from: Date, to: Date, now: Date, calendar: Calendar = .current
    ) -> String {
        guard let bounds = bounds(from: from, to: to, now: now, calendar: calendar) else { return "" }
        let iso = ISO8601DateFormatter()
        let last = ISO8601DateFormatter()
        last.formatOptions.insert(.withFractionalSeconds)
        let upper = bounds.upper == now ? now : bounds.upper.addingTimeInterval(-0.001)
        return
            "query($author: String!) { issues: issues(authorUsername: $author, createdAfter: \"\(iso.string(from: bounds.start))\", createdBefore: \"\(last.string(from: upper))\") { count } }"
    }

    static func gitlabEventsURL(
        _ connection: ForgeConnection, dates: (Date, Date), now: Date,
        action: String? = nil, calendar: Calendar = .current
    ) -> URL? {
        guard let root = connection.root,
            let bounds = bounds(from: dates.0, to: dates.1, now: now, calendar: calendar),
            var parts = URLComponents(
                url: root.appendingPathComponent("/api/v4/events"),
                resolvingAgainstBaseURL: false)
        else { return nil }
        parts.queryItems = [
            URLQueryItem(name: "per_page", value: "1"),
            URLQueryItem(name: "after", value: bounds.after),
            URLQueryItem(name: "before", value: bounds.before),
        ]
        if let action { parts.queryItems?.append(URLQueryItem(name: "action", value: action)) }
        return parts.url
    }

    static func parseGitHub(
        _ payload: [String: Any], failures: [String: ForgeSpanAbsence] = [:],
        connection: ForgeConnection, dates: (Date, Date), now: Date,
        counters enabled: Set<ForgeCounter>, calendar: Calendar = .current
    ) throws -> ForgeSpanReading {
        let (from, to) = dates
        guard let bounds = bounds(from: from, to: to, now: now, calendar: calendar),
            !contributionRanges(start: bounds.start, end: bounds.end).isEmpty
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
            for index in contributionRanges(start: bounds.start, end: bounds.end).indices {
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
                    viewer, start: bounds.start, end: bounds.upper, inclusiveEnd: bounds.upper == now)
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
