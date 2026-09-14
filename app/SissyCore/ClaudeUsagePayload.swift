import Foundation

/// The body Anthropic answers a usage question with, wherever it was read.
///
/// Three places hand Sissy the same object: `api.anthropic.com/api/oauth/usage`
/// over the wire, `claude.ai/api/organizations/{org}/usage` over the wire, and
/// `cachedUsageUtilization.utilization` in the CLI's own `.claude.json`, which
/// is one of those replies stored verbatim. Measured 2026-09-14, the three
/// agree field for field. One parser, therefore, and three transports — the
/// alternative is a second reading of `spend` that drifts from the first the
/// first time a vendor renames a key.
///
/// Everything here is a boundary: the payload is a vendor's, undocumented, and
/// nothing is trusted past the shape it is checked for.
enum ClaudeUsagePayload {
    /// Response key to window length. Anthropic publishes finer buckets
    /// (`seven_day_opus`, `seven_day_sonnet`) and a run of codenamed ones; the
    /// panel shows the two that apply to every plan.
    static let buckets: [(key: String, minutes: Int)] = [
        ("five_hour", 300), ("seven_day", 10_080),
    ]

    private static let spendKey = "spend"

    /// Buckets that report no `utilization`, or no reset, are dropped: a
    /// window without both halves cannot be drawn, and the plan-scoped
    /// buckets the endpoint sends alongside these two arrive that way.
    static func windows(_ body: [String: Any]) -> [UsageWindow] {
        buckets.compactMap { bucket in
            guard let raw = body[bucket.key] as? [String: Any],
                let resetsAt = parseReset(raw["resets_at"]),
                let usedPercent = raw["utilization"] as? Double
            else { return nil }
            return UsageWindow(
                minutes: bucket.minutes,
                usedPercent: usedPercent,
                resetsAt: resetsAt
            )
        }
    }

    /// What the vendor has billed against the spend cap.
    ///
    /// `observedAt` is the caller's, because only the caller knows how old the
    /// reading is: a fetch stamps it now, and the CLI's cache carries the
    /// vendor's own `fetchedAtMs`. A number shown without its age is a claim
    /// of being current that a cache cannot make.
    static func credits(_ body: [String: Any], observedAt: Date) -> ProviderCredits? {
        guard let spend = body[spendKey] as? [String: Any],
            let used = money(spend["used"]),
            let cap = money(spend["limit"]),
            used.currency == cap.currency,
            used.exponent == cap.exponent
        else { return nil }
        return ProviderCredits(
            isEnabled: spend["enabled"] as? Bool ?? true,
            usedMinor: used.minor,
            capMinor: cap.minor,
            currency: used.currency,
            exponent: used.exponent,
            observedAt: observedAt
        )
    }

    /// One money object of the payload. The currency has to look like an
    /// ISO 4217 code before it is carried any further: it reaches a formatter,
    /// and a formatter handed arbitrary text out of a file is how a display
    /// string becomes an injection.
    static func money(_ raw: Any?) -> (minor: Int, currency: String, exponent: Int)? {
        guard let object = raw as? [String: Any],
            let minor = object["amount_minor"] as? Int, minor >= 0,
            let exponent = object["exponent"] as? Int, (0...4).contains(exponent),
            let currency = object["currency"] as? String,
            currency.count == 3,
            currency.allSatisfy({ $0.isASCII && $0.isUppercase })
        else { return nil }
        return (minor, currency, exponent)
    }

    /// `resets_at` is accepted both as epoch seconds and as an ISO-8601
    /// string: the endpoint is undocumented, so the parse does not bet on one.
    /// The string form is measured to carry a `+00:00` offset and microsecond
    /// precision, which only the reader's full parse accepts.
    private static func parseReset(_ raw: Any?) -> Date? {
        if let epoch = raw as? Double {
            return Date(timeIntervalSince1970: epoch)
        }
        if let text = raw as? String {
            return UsageReaderShared.parseTimestamp(text)
        }
        return nil
    }
}
