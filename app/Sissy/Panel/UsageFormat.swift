import Foundation

/// Display formatters shared by the menubar menu and the usage panel.
///
/// Intentionally diverges from the daemon's `FrameBuilder.fmtTokens` /
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
    /// the daemon is alive, not a stopwatch.
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

    /// The vendor's plan token as words: `plus` → "Plus", `edu_plus` → "Edu
    /// Plus". Derived rather than mapped for the same reason as
    /// `windowLabel(minutes:)` — the two CLIs between them publish a dozen
    /// tiers and add to the list without asking, and a table here would show
    /// nothing for the one that arrived after the release. Both vendors emit
    /// lowercase `snake_case`, which the daemon enforces before the token
    /// reaches the wire.
    static func planLabel(_ plan: String?) -> String? {
        guard let plan else { return nil }
        let words = plan.split(separator: "_").map { $0.capitalized }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    static func providerName(_ id: String) -> String {
        switch id {
        case "claude-code": return "Claude Code"
        case "codex": return "Codex"
        default: return id
        }
    }
}
