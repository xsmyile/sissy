import Foundation

/// Pluggable source of per-day token + cost totals. Each implementation tails
/// one CLI's session log (Claude Code JSONL today, Codex JSONL next), parses
/// usage events, and pushes a `(today, prev)` pair through `onChange` whenever
/// state changes. The aggregator fans these into a single combined frame so
/// the wire protocol stays unaware of multi-provider.
///
/// Conforming types are typically actors; protocol leaves isolation up to the
/// implementation but every stateful method is `async` so callers don't need
/// to know.
protocol UsageProvider: AnyObject, Sendable {
    /// Stable identifier used as the key in `/stats` per-provider breakdown
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

    /// Latest `(today, prev)` totals as observed by this provider. `prev` is
    /// suppressed (nil) until the cold scan has finished — see
    /// `ClaudeCodeUsageReader.coldScanComplete` for the trend-flicker
    /// rationale.
    func current() async -> (today: DayTotals, prev: DayTotals?)

    /// Number of session files currently being watched. Drives /health
    /// and the menubar "No JSONL detected" pill. Nonisolated so the HTTP
    /// handler can read it without hopping into the actor mid-scan.
    nonisolated func filesWatched() -> Int

    /// True once the cold backfill scan has completed.
    func isWarm() async -> Bool

    /// Swap in a freshly fetched rate catalog. Each provider takes the slice
    /// matching its upstream vendor and consults it between the user's
    /// `pricingOverride` and the embedded generated seed. Called once before
    /// the cold backfill and again on every successful refresh; a refresh
    /// applies to subsequently ingested events and does not reprice
    /// accumulated totals.
    func applyPriceCatalog(_ catalog: PriceCatalog) async
}
