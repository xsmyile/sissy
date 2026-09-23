import Foundation

/// The one reader behind every provider's status row.
///
/// Statuspage v2's `api/v2/status.json`, which is what both vendors answer —
/// Claude on Atlassian's own service, OpenAI on incident.io, which emulates
/// the same endpoint. Measured 2026-09-15: 212 and 202 bytes, no auth, no
/// account, the same `{page, status{indicator, description}}` envelope. A
/// provider that publishes a different shape is a second reader here, not a
/// second monitor.
///
/// The request is deliberately small and the reply deliberately unused past
/// two fields: `page.updated_at` is on it and is never read, because it moves
/// on incidents rather than on polls.
enum StatuspageFeed {
    static let requestTimeout: TimeInterval = 10

    static func statusURL(root: URL) -> URL {
        root.appendingPathComponent("api/v2/status.json")
    }

    static func summaryURL(root: URL) -> URL {
        root.appendingPathComponent("api/v2/summary.json")
    }

    /// The sentence and the services in one document, which is what keeps a
    /// provider on this shape at one request per poll.
    static func summary(root: URL, checkedAt: Date = Date()) async throws -> ProviderStatusReading {
        let data = try await load(summaryURL(root: root))
        return try parseSummary(data, checkedAt: checkedAt)
    }

    static func parseSummary(_ data: Data, checkedAt: Date) throws -> ProviderStatusReading {
        let payload = try JSONDecoder().decode(StatuspageSummaryPayload.self, from: data)
        return ProviderStatusReading(
            indicator: ProviderStatusIndicator(page: payload.status.indicator),
            description: payload.status.description,
            checkedAt: checkedAt,
            components: components(payload.components))
    }

    /// The vendor's own rows, in the vendor's own order and nesting.
    ///
    /// `onlyShowIfDegraded` is honoured because the page honours it: a row
    /// Statuspage hides while it is healthy is one the user would not find by
    /// opening the page either, and showing it here would make Sissy's tree
    /// disagree with the thing it is a copy of. Measured 2026-09-15: Claude
    /// publishes six components, none of them grouped and none of them hidden,
    /// so this degenerates to a flat list — which is the shape the panel draws
    /// one row deep.
    private static func components(_ rows: [StatuspageComponentPayload])
        -> [ProviderStatusComponent]
    {
        let ordered = rows.sorted { $0.position < $1.position }
        let visible = ordered.filter { !$0.onlyShowIfDegraded || $0.status != "operational" }
        let children = visible.filter { $0.groupID != nil }
        return visible.compactMap { row in
            guard row.groupID == nil else { return nil }
            let mine = children.filter { $0.groupID == row.id }.map(leaf)
            return mine.isEmpty ? leaf(row) : .group(id: row.id, name: row.name, children: mine)
        }
    }

    private static func leaf(_ row: StatuspageComponentPayload) -> ProviderStatusComponent {
        ProviderStatusComponent(
            id: row.id,
            name: row.name,
            indicator: ProviderStatusIndicator(component: row.status),
            status: row.status)
    }

    private static func load(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await SissyHTTP.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderStatusError.malformedPayload
        }
        guard http.statusCode == 200 else {
            throw ProviderStatusError.badStatus(http.statusCode)
        }
        return data
    }

    static func fetch(root: URL, checkedAt: Date = Date()) async throws -> ProviderStatusReading {
        try parse(try await load(statusURL(root: root)), checkedAt: checkedAt)
    }

    /// Typed at the boundary, which is what keeps an indicator a vendor ships
    /// tomorrow from throwing: the string reaches
    /// `ProviderStatusIndicator(page:)` and lands on `unknown`, where a
    /// `RawRepresentable` decode would have failed the whole reply.
    static func parse(_ data: Data, checkedAt: Date) throws -> ProviderStatusReading {
        let payload = try JSONDecoder().decode(StatuspagePayload.self, from: data)
        return ProviderStatusReading(
            indicator: ProviderStatusIndicator(page: payload.status.indicator),
            description: payload.status.description,
            checkedAt: checkedAt)
    }
}

/// The two fields of the status reply Sissy reads, and nothing else it
/// carries.
private struct StatuspagePayload: Decodable {
    let status: StatuspageStatusPayload
}

private struct StatuspageStatusPayload: Decodable {
    let indicator: String
    let description: String?
}

/// The summary reply: the same status block, plus the services under it.
private struct StatuspageSummaryPayload: Decodable {
    private enum CodingKeys: String, CodingKey {
        case status, components
    }

    let status: StatuspageStatusPayload
    let components: [StatuspageComponentPayload]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(StatuspageStatusPayload.self, forKey: .status)
        components =
            try container.decodeIfPresent([StatuspageComponentPayload].self, forKey: .components)
            ?? []
    }
}

/// One row of the page. Every field a vendor may leave out is defaulted here
/// rather than carried as an optional, so nothing downstream has to ask twice
/// whether a row is hidden or where it sorts.
private struct StatuspageComponentPayload: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, name, status, position
        case groupID = "group_id"
        case onlyShowIfDegraded = "only_show_if_degraded"
    }

    let id: String
    let name: String
    let status: String
    let position: Int
    let groupID: String?
    let onlyShowIfDegraded: Bool

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        status = try container.decode(String.self, forKey: .status)
        position = try container.decodeIfPresent(Int.self, forKey: .position) ?? 0
        groupID = try container.decodeIfPresent(String.self, forKey: .groupID)
        onlyShowIfDegraded =
            try container.decodeIfPresent(Bool.self, forKey: .onlyShowIfDegraded) ?? false
    }
}

enum ProviderStatusError: Error {
    case badStatus(Int)
    case malformedPayload
}
