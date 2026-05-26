import Foundation

/// Mirrors the daemon's `HTTPResponses.swift`. Kept in sync by hand because
/// the app and daemon targets don't share a Swift module — the cost of
/// duplication is far smaller than the cost of a shared framework target
/// just for two response types.
struct HealthResponse: Codable, Sendable, Equatable {
    let status: String
    let usageReader: String
    let uptimeSeconds: Int
}
