import Foundation

/// What a Claude usage request can answer with instead of a reading.
///
/// Shared by both readers — the CLI's own credential against
/// `api.anthropic.com` and the claude.ai session — because the two endpoints
/// refuse in the same vocabulary, and a file of its own is what lets either
/// of them grow without the other's carrying it.
enum ClaudeLimitsError: Error {
    case rateLimited
    case badStatus(Int)
    case malformedPayload
}
