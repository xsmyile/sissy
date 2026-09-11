import Foundation

/// Display formatters shared by the menubar menu and the usage panel.
///
/// Intentionally diverges from the engine's `FrameBuilder.fmtTokens` /
/// `fmtCost`: those were shaped for a 128×64 display and trade precision
/// for width, while every surface here has room for a decimal and full cent
/// precision. Keeping both is deliberate — unifying them would force one
/// surface to compromise. What must not diverge is the app's own surfaces,
/// which is why they all resolve through this one type.
enum UsageFormat {
    static func tokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        }
        if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }

    static func cost(_ cost: Decimal) -> String {
        String(format: "$%.2f", NSDecimalNumber(decimal: cost).doubleValue)
    }

    /// Coarse age of the last frame, for the panel's footer. Deliberately
    /// one unit and no seconds past a minute: the footer is a reassurance that
    /// the reading is live, not a stopwatch.
    static func age(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        return "\(minutes / 60)h ago"
    }

    /// Compact name for a rate-limit window, derived from its length so a
    /// vendor that ships a bucket Sissy has never seen still gets a label.
    static func windowLabel(minutes: Int) -> String {
        if minutes % minutesPerDay == 0 { return "\(minutes / minutesPerDay)d" }
        if minutes % minutesPerHour == 0 { return "\(minutes / minutesPerHour)h" }
        return "\(minutes)m"
    }

    /// When a window rolls over. A clock time while that is unambiguous, the
    /// weekday once it is not — a bare "13:00" three days out reads as today.
    ///
    /// The cut is the calendar day rather than a 24-hour horizon: at 22:00 a
    /// five-hour window resetting at 01:00 is three hours away, and "01:00"
    /// there reads as this morning, already past. The weekday carries no
    /// clock time because the panel gives this column 74 points and the
    /// window's own label shares them.
    static func resetLabel(
        _ resetsAt: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        if calendar.isDate(resetsAt, inSameDayAs: now) {
            return resetsAt.formatted(.dateTime.hour().minute())
        }
        return resetsAt.formatted(.dateTime.weekday(.abbreviated))
    }

    private static let minutesPerHour = 60
    private static let minutesPerDay = 1440

    /// The plan as the badge says it, plus the limit tier when the tier
    /// belongs to a different plan than the account's own.
    ///
    /// A Max account metered at `max_5x` reads as one thing, "Max 5x". A Team
    /// seat metered at the same tier does not: "Team 5x" is a plan nobody
    /// sells, so the badge stays "Team" and the tier goes to the row's
    /// tooltip. Folding is therefore conditional on the tier naming the plan
    /// it decorates.
    static func plan(_ plan: String?, tier: String?) -> (label: String, tier: String?)? {
        guard let plan, let label = words(plan) else { return nil }
        let parts = tierParts(tier)
        guard let base = parts.base else { return (label, nil) }
        if base == plan {
            return (parts.multiplier.map { "\(label) \($0)" } ?? label, nil)
        }
        guard let baseLabel = words(base) else { return (label, nil) }
        return (label, parts.multiplier.map { "\(baseLabel) \($0)" } ?? baseLabel)
    }

    /// A vendor token as words: `plus` → "Plus", `edu_plus` → "Edu Plus".
    /// Derived rather than mapped for the same reason as
    /// `windowLabel(minutes:)` — the two CLIs between them publish a dozen
    /// tiers and add to the list without asking, and a table here would show
    /// nothing for the one that arrived after the release. Both vendors emit
    /// lowercase `snake_case`, and the engine passes the token through
    /// verbatim.
    private static func words(_ token: String) -> String? {
        let parts = token.split(separator: "_").map { $0.capitalized }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Splits a tier into the plan it meters and the multiplier on it:
    /// `max_5x` → (`max`, "5x"), `pro` → (`pro`, nil). The multiplier is
    /// recognised by shape rather than by a list, and stays verbatim — "5X"
    /// is not how anyone writes it.
    private static func tierParts(_ tier: String?) -> (base: String?, multiplier: String?) {
        guard let tier, !tier.isEmpty else { return (nil, nil) }
        guard let separator = tier.lastIndex(of: "_") else { return (tier, nil) }
        let suffix = String(tier[tier.index(after: separator)...])
        guard suffix.hasSuffix("x"), suffix.count > 1,
            suffix.dropLast().allSatisfy(\.isNumber)
        else { return (tier, nil) }
        return (String(tier[tier.startIndex..<separator]), suffix)
    }

    static func providerName(_ id: String) -> String {
        switch id {
        case "claude-code": return "Claude Code"
        case "codex": return "Codex"
        default: return id
        }
    }
}
