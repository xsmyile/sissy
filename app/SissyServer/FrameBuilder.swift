import Foundation

struct DayTotals: Sendable, Equatable {
    let totalTokens: Int
    let totalCost: Decimal
}

enum PrimaryMetric: String, Sendable {
    case tokens = "tokens"
    case burnRate = "burn_rate"
}

/// One subscription rate-limit window exactly as the vendor reports it.
///
/// `minutes` identifies the window rather than its position in the payload:
/// Codex labels its buckets `primary`/`secondary` but a `primary` bucket is
/// not always the 5-hour one, so anything that keys off position eventually
/// mislabels a weekly window as a session window.
struct UsageWindow: Sendable, Equatable, Codable, Identifiable {
    let minutes: Int
    let usedPercent: Double
    let resetsAt: Date

    /// The length identifies the window, so it is also what the panel keys
    /// its rows by — a vendor reordering its buckets must not re-create the
    /// row it moved.
    var id: Int { minutes }
}

/// Raw per-provider slice carried on the WS frame so the app can derive both
/// the menubar header total and the panel's per-provider rows from a single
/// payload. Cost is a `Decimal` here; the wire representation is
/// `NSDecimalNumber.stringValue` so it round-trips lossless through
/// `Decimal(string:)` on the app side.
struct ProviderSlice: Sendable, Equatable, Codable, Identifiable {
    let id: String
    let tokens: Int
    let cost: Decimal
    /// Empty whenever the provider reports no limits — an API-key user, or a
    /// CLI that has not surfaced a window yet. The panel falls back to the
    /// share-of-today bar rather than rendering an empty gauge.
    let windows: [UsageWindow]
    /// Vendor's own plan token (`max`, `plus`), nil when the provider names
    /// none. Raw rather than a label so the app owns the wording — same
    /// division as `id`, which the app turns into a display name.
    let plan: String?
    /// Limit tier the plan is metered at (`max_5x`), for the one vendor that
    /// publishes one. Only ever set alongside `plan`.
    let planTier: String?

    init(
        id: String,
        tokens: Int,
        cost: Decimal,
        windows: [UsageWindow] = [],
        plan: String? = nil,
        planTier: String? = nil
    ) {
        self.id = id
        self.tokens = tokens
        self.cost = cost
        self.windows = windows
        self.plan = plan
        self.planTier = plan == nil ? nil : planTier
    }
}

struct FrameData: Sendable, Equatable, Codable {
    let tokens: String
    let cost: String
    let burn: String
    let primary: String
    let primaryLabel: String
    /// Per-provider totals (raw tokens + Decimal cost) for every provider with
    /// spend today. Stable order: claude-code, codex, then alphabetical. Empty
    /// when no provider has tokens today (none active yet, or all idle today).
    let providers: [ProviderSlice]
    /// Yesterday's raw totals, carried so the menubar can render a
    /// day-over-day delta. Both nil until every active provider has produced
    /// a `prev` snapshot, so the app shows no delta instead of a false 0%.
    let prevTokens: Int?
    let prevCost: Decimal?
    /// The keep-awake mode and whether it is holding right now. Always
    /// emitted, including when off: the app renders the control from this, and
    /// an absent key would be indistinguishable from a daemon too old to have
    /// one.
    let keepAwake: KeepAwakeState
}

enum FrameBuilder {
    /// What a formatter prints when there is nothing to print yet. Read back
    /// by the panel, which drops the burn line rather than showing it.
    static let placeholder = "..."

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
        if tokens <= 0 || hoursElapsed <= 0 { return placeholder }
        let safeHours = max(hoursElapsed, 1.0 / 60.0)
        let rate = Int(Double(tokens) / safeHours)
        return fmtTokens(rate)
    }

    static func fmtCost(_ c: Decimal) -> String {
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

    static func build(
        today: DayTotals,
        prev: DayTotals?,
        hoursElapsed: Double,
        primaryMetric: PrimaryMetric,
        providers: [ProviderSlice] = [],
        keepAwake: KeepAwakeState = .off
    ) -> FrameData {
        let tokens = fmtTokens(today.totalTokens)
        let burn = fmtBurn(tokens: today.totalTokens, hoursElapsed: hoursElapsed)
        let (primary, primaryLabel) = selectPrimary(tokens: tokens, burn: burn, metric: primaryMetric)
        return FrameData(
            tokens: tokens,
            cost: fmtCost(today.totalCost),
            burn: burn,
            primary: primary,
            primaryLabel: primaryLabel,
            providers: providers,
            prevTokens: prev?.totalTokens,
            prevCost: prev?.totalCost,
            keepAwake: keepAwake
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

    /// Breakdown slices for the wire: only CLIs with spend today, in canonical
    /// order. A provider with zero tokens today is omitted so the menubar
    /// Breakdown reflects that day's actual per-CLI split rather than every
    /// warm reader.
    static func activeSlices(_ slices: [ProviderSlice]) -> [ProviderSlice] {
        sortProviders(slices.filter { $0.tokens > 0 })
    }
}
