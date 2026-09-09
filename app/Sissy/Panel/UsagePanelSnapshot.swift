import Foundation

/// Everything numeric the usage panel renders, derived from one frame plus
/// the milestone preset. Pure by construction: no AppKit, no clock, no model
/// access, so the panel's arithmetic — shares, day-over-day delta, milestone
/// progress — is testable without a live daemon.
///
/// Totals come from the frame's raw `providers` slices rather than the
/// daemon-formatted scalars, so the big number, the rows and the delta all
/// agree to the penny.
struct UsagePanelSnapshot: Equatable {
    let tokens: String
    let cost: String
    let burn: String
    let delta: TokenDelta?
    let milestone: MilestoneProgress?
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

    struct MilestoneProgress: Equatable {
        let nextDollars: Int
        let fraction: Double
    }

    struct ProviderRow: Equatable, Identifiable {
        let id: String
        let name: String
        let tokens: String
        let cost: String
        let share: Double
    }

    static func make(
        frame: DisplayFrame,
        milestoneFrequency: Preferences.MilestoneFrequency
    ) -> Self {
        let totalTokens = frame.providers.reduce(0) { $0 + $1.tokens }
        let totalCost = frame.providers.reduce(Decimal(0)) { $0 + $1.cost }
        return Self(
            tokens: frame.providers.isEmpty ? frame.tokens : UsageFormat.tokens(totalTokens),
            cost: frame.providers.isEmpty ? "$\(frame.cost)" : UsageFormat.cost(totalCost),
            burn: frame.burn,
            delta: makeDelta(today: totalTokens, prev: frame.prev),
            milestone: makeMilestone(cost: totalCost, step: milestoneFrequency.costStep),
            providers: makeRows(frame.providers, totalTokens: totalTokens)
        )
    }

    private static func makeDelta(today: Int, prev: DisplayFrame.PrevTotals?) -> TokenDelta? {
        guard let prev, prev.tokens > 0, today > 0 else { return nil }
        let ratio = Double(today - prev.tokens) / Double(prev.tokens)
        let percent = Int((abs(ratio) * 100).rounded())
        if percent == 0 {
            return TokenDelta(percent: 0, direction: .flat)
        }
        return TokenDelta(percent: percent, direction: today > prev.tokens ? .up : .down)
    }

    /// Truncates toward zero to match `MilestoneTracker.dollars` in the
    /// daemon: rounding here would put the panel's "next $500" a dollar away
    /// from the crossing that actually fires the celebration.
    private static func makeMilestone(cost: Decimal, step: Int) -> MilestoneProgress? {
        guard step > 0 else { return nil }
        let dollars = NSDecimalNumber(decimal: cost).doubleValue
        guard dollars >= 0 else { return nil }
        let crossed = Int(dollars) / step
        let floor = Double(crossed * step)
        return MilestoneProgress(
            nextDollars: (crossed + 1) * step,
            fraction: (dollars - floor) / Double(step)
        )
    }

    private static func makeRows(
        _ slices: [DisplayFrame.ProviderSlice],
        totalTokens: Int
    ) -> [ProviderRow] {
        slices.map { slice in
            ProviderRow(
                id: slice.id,
                name: UsageFormat.providerName(slice.id),
                tokens: UsageFormat.tokens(slice.tokens),
                cost: UsageFormat.cost(slice.cost),
                share: totalTokens > 0 ? Double(slice.tokens) / Double(totalTokens) : 0
            )
        }
    }
}
