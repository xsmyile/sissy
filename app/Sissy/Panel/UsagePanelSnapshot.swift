import Foundation

/// Everything numeric the usage panel renders, derived from one frame. Pure
/// by construction: no AppKit, no clock, no model access, so the panel's
/// arithmetic — shares, day-over-day delta — is testable without a live
/// daemon.
///
/// Totals come from the frame's raw `providers` slices rather than the
/// daemon-formatted scalars, so the big number, the rows and the delta all
/// agree to the penny.
struct UsagePanelSnapshot: Equatable {
    let tokens: String
    let cost: String
    let burn: String
    let delta: TokenDelta?
    let providers: [ProviderRow]

    /// Day-over-day change in tokens. Absent when the daemon hasn't shipped
    /// yesterday yet, or when yesterday was zero and a percentage would be
    /// undefined. Note the comparison is today-so-far against yesterday's
    /// full day — daily totals are the only granularity the daemon keeps.
    struct TokenDelta: Equatable {
        let percent: Int
        let direction: DeltaDirection
    }

    enum DeltaDirection: Equatable {
        case up
        case down
        case flat
    }

    struct ProviderRow: Equatable, Identifiable {
        let id: String
        let name: String
        /// Subscription plan, already worded. Nil leaves the row's header at
        /// the name alone — an API-key user has no plan to name, and a Codex
        /// that has not taken a turn yet has not said which it is on.
        let plan: String?
        /// Limit tier, worded, and only when it is not already part of
        /// `plan` — a Team seat metered at Max 5x. It goes to the tooltip:
        /// the badge is for the plan the user pays for.
        let planTier: String?
        let tokens: String
        let cost: String
        let share: Double
        /// Shortest window first. Empty puts the row back on `share`.
        let windows: [WindowRow]
    }

    /// One rate-limit gauge. `fraction` is clamped for the bar while
    /// `percent` is not, so a window past 100% still reads as what it is.
    struct WindowRow: Equatable, Identifiable {
        let id: Int
        let label: String
        let percent: Int
        let fraction: Double
        let resetsAt: Date
    }

    static func make(frame: FrameData) -> Self {
        let totalTokens = frame.providers.reduce(0) { $0 + $1.tokens }
        let totalCost = frame.providers.reduce(Decimal(0)) { $0 + $1.cost }
        return Self(
            tokens: frame.providers.isEmpty ? frame.tokens : UsageFormat.tokens(totalTokens),
            cost: frame.providers.isEmpty ? "$\(frame.cost)" : UsageFormat.cost(totalCost),
            burn: frame.burn,
            delta: makeDelta(today: totalTokens, prevTokens: frame.prevTokens),
            providers: makeRows(frame.providers, totalTokens: totalTokens)
        )
    }

    private static func makeDelta(today: Int, prevTokens: Int?) -> TokenDelta? {
        guard let prevTokens, prevTokens > 0, today > 0 else { return nil }
        let ratio = Double(today - prevTokens) / Double(prevTokens)
        let percent = Int((abs(ratio) * 100).rounded())
        if percent == 0 {
            return TokenDelta(percent: 0, direction: .flat)
        }
        return TokenDelta(percent: percent, direction: today > prevTokens ? .up : .down)
    }

    private static func makeRows(
        _ slices: [ProviderSlice],
        totalTokens: Int
    ) -> [ProviderRow] {
        slices.map { slice in
            let plan = UsageFormat.plan(slice.plan, tier: slice.planTier)
            return ProviderRow(
                id: slice.id,
                name: UsageFormat.providerName(slice.id),
                plan: plan?.label,
                planTier: plan?.tier,
                tokens: UsageFormat.tokens(slice.tokens),
                cost: UsageFormat.cost(slice.cost),
                share: totalTokens > 0 ? Double(slice.tokens) / Double(totalTokens) : 0,
                windows: slice.windows.map(makeWindow)
            )
        }
    }

    private static func makeWindow(_ window: UsageWindow) -> WindowRow {
        WindowRow(
            id: window.minutes,
            label: UsageFormat.windowLabel(minutes: window.minutes),
            percent: Int(window.usedPercent.rounded()),
            fraction: min(max(window.usedPercent / 100, 0), 1),
            resetsAt: window.resetsAt
        )
    }
}
