import Foundation

/// Typed wire formats for the daemon's HTTP endpoints. Stays Codable so the
/// menubar can decode the same shape with its own mirror struct (see
/// `app/Sissy/Server/HTTPResponses.swift`). Sendable so Swift 6 strict
/// concurrency can carry these across actor / TaskGroup boundaries without
/// reaching for `[String: Any]` workarounds.
///
/// Money is encoded as a `String` (Decimal canonical form) so a sub-cent
/// per-provider total round-trips byte-exact through JSON — `Double` would
/// silently drop precision. Same rationale as `UsageStateSnapshot.DailyTotal`.
struct HealthResponse: Codable, Sendable, Equatable {
    /// Always "ok" today; reserved for richer states when we wire in
    /// per-feature health (e.g. FSEvents stream broken).
    let status: String
    /// "ok" or "no-jsonl-found". Frontend gates the yellow "No JSONL"
    /// pill on the latter.
    let usageReader: String
    let uptimeSeconds: Int
}

struct StatsResponse: Codable, Sendable, Equatable {
    let connectedClients: Int
    let filesWatched: Int
    /// ISO-8601 string for the last Hub.broadcast emit, nil if no frame
    /// has been broadcast yet (cold-start before any provider emit).
    let lastFrameAt: String?
}
