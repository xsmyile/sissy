import Foundation

/// What a Claude usage request can answer with instead of a reading.
///
/// Shared by both readers — the CLI's own credential against
/// `api.anthropic.com` and the claude.ai session — because the two endpoints
/// refuse in the same vocabulary, and a file of its own is what lets either
/// of them grow without the other's carrying it.
enum ClaudeLimitsError: Error {
    case rateLimited(retryAfter: TimeInterval?)
    case badStatus(Int)
    case malformedPayload
}

extension ClaudeLimitsError {
    /// The floor is the ordinary poll interval: coming back sooner than a
    /// poll would have is what earns a 429 in the first place.
    private static let retryAfterFloor: TimeInterval = 300
    /// A ceiling because the header is foreign input, and because a block
    /// longer than this is indistinguishable from one Sissy simply waits out.
    private static let retryAfterCeiling: TimeInterval = 3600
    /// What a 429 with no `Retry-After` is worth waiting.
    private static let blindBackoff: TimeInterval = 1800

    /// How long to wait after a 429, taking the vendor's own figure where it
    /// sent one.
    ///
    /// One number for both the sleep and the date the row prints, so the
    /// panel cannot promise a moment the loop will not honour.
    ///
    /// The figure counts down to an instant the vendor keeps to within a
    /// request or two and then moves: measured 2026-09-17 against
    /// `api/oauth/usage`, refusals 77 s apart carried 1684 s and 1607 s —
    /// the same instant — while one 24 minutes later named an instant 142 s
    /// further out. A window that rolls, in other words, so a wait that ends
    /// early is re-armed by the next refusal rather than counted as expiry.
    static func backoffSeconds(retryAfter: TimeInterval?) -> TimeInterval {
        guard let retryAfter, retryAfter.isFinite, retryAfter >= 0 else { return blindBackoff }
        return min(max(retryAfter, retryAfterFloor), retryAfterCeiling)
    }

    /// `Retry-After` in the delta-seconds form every measured reply used.
    ///
    /// The HTTP-date form is deliberately not read: nothing has been observed
    /// sending one here, and a date parsed against the wrong clock would move
    /// the deadline the panel prints. An unparsed header answers nil, which
    /// is the blind backoff.
    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let header = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        return TimeInterval(header.trimmingCharacters(in: .whitespaces))
    }
}
