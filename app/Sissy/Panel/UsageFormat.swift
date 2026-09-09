import Foundation

/// Display formatters shared by the menubar menu and the usage panel.
///
/// Intentionally diverges from the daemon's `FrameBuilder.fmtTokens` /
/// `fmtCost`: those render into 128×64 pixels of OLED and trade precision
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
    static func resetLabel(_ resetsAt: Date, now: Date = Date()) -> String {
        let horizon = TimeInterval(minutesPerDay * 60)
        if resetsAt.timeIntervalSince(now) < horizon {
            return resetsAt.formatted(.dateTime.hour().minute())
        }
        return resetsAt.formatted(.dateTime.weekday(.abbreviated))
    }

    private static let minutesPerHour = 60
    private static let minutesPerDay = 1440

    static func providerName(_ id: String) -> String {
        switch id {
        case "claude-code": return "Claude Code"
        case "codex": return "Codex"
        default: return id
        }
    }

    /// Header subtitle for the menubar pull-down. Sums the provider slices the
    /// daemon shipped so the total matches the panel's per-provider rows to
    /// the penny. Burn rate isn't per-provider, so it passes through
    /// daemon-formatted.
    static func headerSubtitle(
        providers: [DisplayFrame.ProviderSlice],
        burn: String
    ) -> String? {
        var parts: [String] = []
        let totalTokens = providers.reduce(0) { $0 + $1.tokens }
        let totalCost = providers.reduce(Decimal(0)) { $0 + $1.cost }
        if totalTokens > 0 {
            parts.append("\(tokens(totalTokens)) tok")
        }
        if totalCost > 0 || !providers.isEmpty {
            parts.append(cost(totalCost))
        }
        if burn != FrameDecoder.placeholder {
            parts.append("\(burn)/h")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
