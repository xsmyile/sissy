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
    /// Response key to window length, for the payload's older shape. Anthropic
    /// publishes finer buckets alongside these and a run of codenamed ones;
    /// only the two that apply to every plan are read here.
    static let buckets: [(key: String, minutes: Int)] = [
        ("five_hour", 300), ("seven_day", 10_080),
    ]

    /// `limits` is the vendor's own curated list, and it is the only place
    /// the model-scoped weekly window appears: the flat keys carry the
    /// plan-wide buckets and nothing else, so a payload read through them
    /// alone silently drops it.
    private static let limitsKey = "limits"
    private static let spendKey = "spend"

    /// `kind` to window length. Anything else the vendor lists is skipped
    /// rather than guessed at — a bucket whose period Sissy cannot name is a
    /// gauge with no axis.
    private static let limitKinds: [String: Int] = [
        "session": 300, "weekly_all": 10_080, "weekly_scoped": 10_080,
    ]

    /// Every window the payload names, from `limits` where the vendor sends
    /// it and from the flat keys where it does not.
    ///
    /// A bucket with no `utilization` is dropped — there is nothing to draw.
    /// A bucket with no reset is not: the vendor sends a null reset for a
    /// period nobody has started yet, and that is a window at zero rather
    /// than a window that does not exist.
    static func windows(_ body: [String: Any]) -> [UsageWindow] {
        let listed = (body[limitsKey] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        guard listed.isEmpty else { return listed.compactMap(window(fromLimit:)) }
        return buckets.compactMap { bucket in
            guard let raw = body[bucket.key] as? [String: Any],
                let resetsAt = parseReset(raw["resets_at"]),
                let usedPercent = raw["utilization"] as? Double
            else { return nil }
            return UsageWindow(
                minutes: bucket.minutes, usedPercent: usedPercent, resetsAt: resetsAt)
        }
    }

    /// One entry of `limits`. The scope is the model's display name as the
    /// vendor spells it, which is what keeps a weekly bucket for one model
    /// from rendering as the weekly bucket for everything.
    private static func window(fromLimit raw: [String: Any]) -> UsageWindow? {
        guard let kind = raw["kind"] as? String,
            let minutes = limitKinds[kind],
            let percent = raw["percent"] as? Double ?? (raw["percent"] as? Int).map(Double.init)
        else { return nil }
        let resetsAt = parseReset(raw["resets_at"])
        let model = (raw["scope"] as? [String: Any])?["model"] as? [String: Any]
        return UsageWindow(
            minutes: minutes,
            usedPercent: percent,
            resetsAt: resetsAt,
            scope: (model?["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// What the vendor has billed against the spend cap.
    ///
    /// `observedAt` is the caller's, because only the caller knows how old the
    /// reading is: a fetch stamps it now, and the CLI's cache carries the
    /// vendor's own `fetchedAtMs`. A number shown without its age is a claim
    /// of being current that a cache cannot make.
    static func credits(
        _ body: [String: Any],
        observedAt: Date,
        balanceMinor: Int? = nil
    ) -> ProviderCredits? {
        guard let spend = body[spendKey] as? [String: Any],
            let used = money(spend["used"]),
            let cap = money(spend["limit"]),
            used.currency == cap.currency,
            used.exponent == cap.exponent
        else { return nil }
        return ProviderCredits(
            isEnabled: spend["enabled"] as? Bool ?? true,
            unit: .money(currency: used.currency, exponent: used.exponent),
            usedMinor: used.minor,
            capMinor: cap.minor,
            observedAt: observedAt,
            balanceMinor: balanceMinor
        )
    }

    /// The prepaid balance, off `/prepaid/credits`. A different question from
    /// the spend: one is what is left on the account, the other what has been
    /// billed against the cap, and a source that answers only the second says
    /// nothing about the first rather than guessing at zero.
    static func balance(_ body: [String: Any], currency: String) -> Int? {
        guard let money = (body["balance"] as? [String: Any])?["money"],
            let parsed = self.money(money),
            parsed.currency == currency
        else { return nil }
        return parsed.minor
    }

    /// One money object of the payload, in the vendor's own minor units.
    struct Money: Equatable {
        let minor: Int
        let currency: String
        let exponent: Int
    }

    /// One money object of the payload. The currency has to look like an
    /// ISO 4217 code before it is carried any further: it reaches a formatter,
    /// and a formatter handed arbitrary text out of a file is how a display
    /// string becomes an injection.
    static func money(_ raw: Any?) -> Money? {
        guard let object = raw as? [String: Any],
            let minor = object["amount_minor"] as? Int, minor >= 0,
            let exponent = object["exponent"] as? Int, (0...4).contains(exponent),
            let currency = object["currency"] as? String,
            currency.count == 3,
            currency.allSatisfy({ $0.isASCII && $0.isUppercase })
        else { return nil }
        return Money(minor: minor, currency: currency, exponent: exponent)
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
