import Foundation

/// What a usage request can answer with instead of a reading.
///
/// Shared by every reader that asks a vendor rather than a log — the CLI's own
/// credential against `api.anthropic.com`, the claude.ai session, and the
/// Codex credential against `chatgpt.com` — because they all refuse in HTTP's
/// vocabulary and a 429 is a 429 whoever sent it. A file of its own is what
/// lets any of them grow without the others carrying it.
enum UsageRequestError: Error {
    case rateLimited(retryAfter: TimeInterval?)
    case badStatus(Int)
    case malformedPayload
}

extension UsageRequestError {
    /// The floor is the ordinary poll interval: coming back sooner than a
    /// poll would have is what earns a 429 in the first place.
    private static let retryAfterFloor: TimeInterval = 300
    /// A ceiling because the header is foreign input, and because a block
    /// longer than this is indistinguishable from one Sissy simply waits out.
    static let retryAfterCeiling: TimeInterval = 3600
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

extension UsageRequestError: CustomStringConvertible {
    /// What the log says this refusal was.
    ///
    /// `localizedDescription` on a bare enum answers `error 1` and drops the
    /// status code, which is the whole of what a persistent refusal has to
    /// say — three readers log this type and every one of them was reporting
    /// a number nobody could act on. `CustomStringConvertible` rather than
    /// `LocalizedError`: none of this reaches a surface a user reads, and
    /// `errorDescription` would promise that it does.
    var description: String {
        switch self {
        case .rateLimited(let retryAfter):
            guard let retryAfter else { return "429 with no Retry-After" }
            return "429, Retry-After \(Int(retryAfter))s"
        case .badStatus(let code):
            return "HTTP \(code)"
        case .malformedPayload:
            return "the reply did not parse"
        }
    }
}
