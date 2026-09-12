import Foundation

/// Pluggable source of per-day token + cost totals. Each implementation tails
/// one CLI's session log (Claude Code JSONL today, Codex JSONL next), parses
/// usage events, and pushes a `(today, prev)` pair through `onChange` whenever
/// state changes. The aggregator fans these into a single combined frame so
/// the frame stays unaware of multi-provider.
///
/// Conforming types are typically actors; protocol leaves isolation up to the
/// implementation but every stateful method is `async` so callers don't need
/// to know.
protocol UsageProvider: AnyObject, Sendable {
    /// Stable identifier used as the key in the per-provider breakdown
    /// and (where applicable) as the suffix on provider-specific persistence
    /// files. Kebab-case, lowercase. Claude is the exception: it keeps the
    /// legacy unqualified `usage-state.json` for upgrade smoothness.
    nonisolated var id: String { get }

    /// Boot the provider. Does any persisted-state load, initial cold scan,
    /// and starts the FSEvents watcher + safety-net poll. The supplied
    /// callback fires on every observed state change.
    func start(onChange: @Sendable @escaping (DayTotals, DayTotals?) async -> Void) async

    /// Tear down. Flushes any pending persistence, cancels timers, releases
    /// the FSEvents stream. Idempotent.
    func stop() async

    /// Drops whatever the provider still holds of the days the archive has
    /// just been told to forget. Today is untouched — it is still being
    /// counted, and the archive takes it back on the next flush.
    func forgetArchivedDays() async

    /// Latest `(today, prev)` totals as observed by this provider. `prev` is
    /// suppressed (nil) until the cold scan has finished — see
    /// `LocalUsageProvider.coldScanComplete` for the trend-flicker
    /// rationale.
    func current() async -> (today: DayTotals, prev: DayTotals?)

    /// Number of session files currently being watched. Drives the panel's
    /// and the menubar "No JSONL detected" pill. Nonisolated so the HTTP
    /// handler can read it without hopping into the actor mid-scan.
    nonisolated func filesWatched() -> Int

    /// True once the cold backfill scan has completed.
    func isWarm() async -> Bool

    /// Subscription rate-limit windows the CLI last reported, newest
    /// observation wins. Empty for a provider that surfaces none — the
    /// default implementation covers those, so a reader only overrides it
    /// when its session log actually carries limits.
    ///
    /// Nonisolated on purpose: the aggregator reads this while the emitting
    /// provider still holds its actor, so an actor hop here would deadlock
    /// the pair.
    nonisolated func currentWindows() -> [UsageWindow]

    /// Subscription plan the vendor names for this account, as the vendor's
    /// own lowercase token (`max`, `plus`) rather than a display label — the
    /// app renders it, the same division `UsageFormat.providerName` already
    /// draws, so a tier a vendor ships tomorrow still reaches the panel.
    /// Nil for a provider that names none; the default implementation covers
    /// those.
    ///
    /// Nonisolated for the same reason as `currentWindows()`: the aggregator
    /// reads this while the emitting provider still holds its actor.
    nonisolated func currentPlan() -> String?

    /// Limit tier the plan is metered at, as the vendor's own token
    /// (`max_5x`). Nil for every provider that publishes no such thing, which
    /// is all of them but Claude Code. Never set without a plan: a tier alone
    /// names nothing a reader could place.
    nonisolated func currentPlanTier() -> String?

    /// How the provider's day splits across projects, as of its last emit.
    /// Empty for a provider whose format names no working directory.
    ///
    /// Nonisolated for the reason the windows are: the aggregator reads it
    /// while building a slice, inside the hop that produced the totals beside
    /// it, and an actor hop here would pair a breakdown from one moment with
    /// totals from another.
    nonisolated func currentProjects() -> [ProjectTotals]

    /// Swap in a freshly fetched rate catalog. Each provider takes the slice
    /// matching its upstream vendor and consults it between the user's
    /// `pricingOverride` and the embedded generated seed. Called once before
    /// the cold backfill and again on every successful refresh; a refresh
    /// applies to subsequently ingested events and does not reprice
    /// accumulated totals.
    func applyPriceCatalog(_ catalog: PriceCatalog) async
}

extension UsageProvider {
    /// A provider that keeps no archive has nothing that could rewrite a day
    /// the user deleted.
    func forgetArchivedDays() async {}

    nonisolated func currentWindows() -> [UsageWindow] { [] }
    nonisolated func currentPlan() -> String? { nil }
    nonisolated func currentPlanTier() -> String? { nil }
    nonisolated func currentProjects() -> [ProjectTotals] { [] }
}
