import Foundation

struct DayTotals: Sendable, Equatable {
    let totalTokens: Int
    let totalCost: Decimal
}

enum PrimaryMetric: String, Sendable {
    case tokens = "tokens"
    case burnRate = "burn_rate"
}

struct StateThresholds: Sendable, Codable {
    var code: Decimal = 20
    var glow: Decimal = 100
    var angry: Decimal = 200
    var trendRatio: Decimal = 1.3
}

/// Raw per-provider slice carried on the WS frame so the app can derive both
/// the menubar header total and the Breakdown submenu rows from a single
/// payload. Firmware ignores the field. Cost is a `Decimal` here; the wire
/// representation is `NSDecimalNumber.stringValue` so it round-trips lossless
/// through `Decimal(string:)` on the app side.
struct ProviderSlice: Sendable, Equatable, Codable {
    let id: String
    let tokens: Int
    let cost: Decimal
}

struct FrameData: Sendable, Equatable, Codable {
    let tokens: String
    let cost: String
    let burn: String
    let state: String
    let primary: String
    let primaryLabel: String
    /// Carries a milestone key on the single frame that crosses a threshold,
    /// nil on every other frame. Format: `"cost:<D>"` (whole dollars, e.g.
    /// `"cost:225"`). The app parses this into a `MilestoneDescriptor` to
    /// render the matching catchphrase; firmware ignores the field.
    let milestone: String?
    /// Per-provider totals (raw tokens + Decimal cost). Stable order: claude-code,
    /// codex, then alphabetical. Empty array when no provider has emitted yet.
    /// App-only; firmware ignores it.
    let providers: [ProviderSlice]
}

enum FrameBuilder {
    static func fmtTokens(_ n: Int) -> String {
        if n >= 1_000_000_000 {
            let v = Double(n) / 1_000_000_000
            return v < 10 ? String(format: "%.1fB", v) : "\(Int(v))B"
        }
        if n >= 1_000_000 {
            let v = Double(n) / 1_000_000
            return v < 10 ? String(format: "%.1fM", v) : "\(Int(v))M"
        }
        if n >= 1_000 {
            let v = Double(n) / 1_000
            return v < 10 ? String(format: "%.1fK", v) : "\(Int(v))K"
        }
        return "\(n)"
    }

    static func fmtBurn(tokens: Int, hoursElapsed: Double) -> String {
        if tokens <= 0 || hoursElapsed <= 0 { return "..." }
        let safeHours = max(hoursElapsed, 1.0 / 60.0)
        let rate = Int(Double(tokens) / safeHours)
        return fmtTokens(rate)
    }

    static func fmtCost(_ c: Decimal) -> String {
        // The ≥100 branch must use the same truncation as
        // `MilestoneTracker.dollars` (toward-zero). If one rounds while the
        // other truncates, a milestone-crossing frame's headline ("$190
        // down") and subline ("$189") desync by a dollar. Both currently
        // truncate; keep it that way.
        let d = NSDecimalNumber(decimal: c).doubleValue
        if d >= 100 { return "\(Int(d))" }
        if d >= 10 { return String(format: "%.1f", d) }
        return String(format: "%.2f", d)
    }

    static func selectPrimary(tokens: String, burn: String, metric: PrimaryMetric) -> (
        value: String, label: String
    ) {
        switch metric {
        case .burnRate: return (burn, "BURN/H")
        case .tokens: return (tokens, "TOKENS")
        }
    }

    static func pickState(today: DayTotals, prev: DayTotals?, thresholds: StateThresholds) -> String {
        if today.totalTokens == 0 { return "sleep" }
        if today.totalCost >= thresholds.angry { return "angry" }
        if today.totalCost >= thresholds.glow { return "glow" }
        if let prev, prev.totalCost > 0, today.totalCost >= prev.totalCost * thresholds.trendRatio {
            return "trend"
        }
        if today.totalCost >= thresholds.code { return "code" }
        return "think"
    }

    static func build(
        today: DayTotals,
        prev: DayTotals?,
        hoursElapsed: Double,
        primaryMetric: PrimaryMetric,
        thresholds: StateThresholds = StateThresholds(),
        milestone: String? = nil,
        providers: [ProviderSlice] = []
    ) -> FrameData {
        let tokens = fmtTokens(today.totalTokens)
        let burn = fmtBurn(tokens: today.totalTokens, hoursElapsed: hoursElapsed)
        let (primary, primaryLabel) = selectPrimary(tokens: tokens, burn: burn, metric: primaryMetric)
        return FrameData(
            tokens: tokens,
            cost: fmtCost(today.totalCost),
            burn: burn,
            state: pickState(today: today, prev: prev, thresholds: thresholds),
            primary: primary,
            primaryLabel: primaryLabel,
            milestone: milestone,
            providers: providers
        )
    }

    /// Stable order for the wire: claude-code first (v0.1.0 baseline), then
    /// codex, then anything else alphabetically. App + daemon use the same
    /// rule so a freshly-connected client never sees rows shuffle.
    static func providerSortOrder(_ id: String) -> Int {
        switch id {
        case "claude-code": return 0
        case "codex": return 1
        default: return 2
        }
    }

    static func sortProviders(_ slices: [ProviderSlice]) -> [ProviderSlice] {
        slices.sorted { lhs, rhs in
            let lp = providerSortOrder(lhs.id)
            let rp = providerSortOrder(rhs.id)
            if lp != rp { return lp < rp }
            return lhs.id < rhs.id
        }
    }
}
