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

    static func fetch(root: URL, checkedAt: Date = Date()) async throws -> ProviderStatusReading {
        var request = URLRequest(url: statusURL(root: root), timeoutInterval: requestTimeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderStatusError.malformedPayload
        }
        guard http.statusCode == 200 else {
            throw ProviderStatusError.badStatus(http.statusCode)
        }
        return try parse(data, checkedAt: checkedAt)
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

/// The two fields of the reply Sissy reads, and nothing else it carries.
private struct StatuspagePayload: Decodable {
    struct Status: Decodable {
        let indicator: String
        let description: String?
    }

    let status: Status
}

enum ProviderStatusError: Error {
    case badStatus(Int)
    case malformedPayload
}
