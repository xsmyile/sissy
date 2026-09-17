import Foundation

/// The body OpenAI answers a Codex usage question with.
///
/// `chatgpt.com/backend-api/wham/usage` carries the same block the CLI writes
/// on every `token_count` event — measured 2026-09-17, `rate_limit` against
/// `rate_limits`, field for field, with the windows spelled in seconds here
/// and in minutes there. That is the whole reason this reader exists: the
/// rollout's copy is only ever as fresh as the last turn, and on the same
/// machine at the same moment the freshest rollout was 1 h 51 m old and two
/// points behind.
///
/// The credits block is byte-identical, so it is not parsed twice:
/// `CodexAdapter.credits` is what reads it in both places, and a vendor
/// renaming a key there has one reader to fix.
///
/// Everything here is a boundary — a vendor's undocumented payload — so
/// nothing is trusted past the shape it is checked for.
enum CodexUsagePayload {
    /// The two windows every plan is metered by, in the order the vendor
    /// names them. Position is not meaning: each carries its own length, and
    /// the length is what the panel words.
    private static let windowKeys = ["primary_window", "secondary_window"]
    private static let rateLimitKey = "rate_limit"
    private static let secondsPerMinute = 60

    /// One reading of the endpoint.
    ///
    /// The account id travels with it because the reply names which account it
    /// answered for, which is the one thing a caller cannot check for itself:
    /// a token can be sent with a workspace header and a vendor is free to
    /// answer for another.
    struct Reading: Sendable, Equatable {
        let accountId: String?
        let account: ProviderAccount?
        let plan: String?
        let windows: [UsageWindow]
        let credits: ProviderCredits?
    }

    static func reading(_ body: [String: Any], observedAt: Date) -> Reading {
        Reading(
            accountId: UsageReaderShared.sanitizedDisplayText(body["account_id"] as? String),
            account: ProviderAccount(
                email: UsageReaderShared.sanitizedDisplayText(body["email"] as? String)),
            plan: UsageReaderShared.sanitizedPlanToken(body["plan_type"] as? String),
            windows: windows(body),
            credits: CodexAdapter.credits(body["credits"], observedAt: observedAt)
        )
    }

    /// Every window the payload names.
    ///
    /// A bucket whose length does not come to whole minutes is dropped rather
    /// than rounded: the length is what the panel words the period with, and
    /// a period Sissy cannot name is a gauge with no axis. A null reset is
    /// kept, on `UsageWindow`'s own rule — a period nobody has started is a
    /// window at zero, not a window that does not exist.
    ///
    /// `additional_rate_limits` is deliberately not read. Measured on one
    /// machine it was null on every reply, so its shape is unknown, and a
    /// model-scoped window guessed at renders beside the plan's own as if it
    /// measured the same thing.
    static func windows(_ body: [String: Any]) -> [UsageWindow] {
        guard let limits = body[rateLimitKey] as? [String: Any] else { return [] }
        return windowKeys.compactMap { key -> UsageWindow? in
            guard let bucket = limits[key] as? [String: Any],
                let seconds = bucket["limit_window_seconds"] as? Int,
                seconds >= secondsPerMinute, seconds % secondsPerMinute == 0,
                let used = bucket["used_percent"] as? Double
            else { return nil }
            return UsageWindow(
                minutes: seconds / secondsPerMinute,
                usedPercent: used,
                resetsAt: (bucket["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            )
        }
    }
}
