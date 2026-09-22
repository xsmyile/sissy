import Foundation

/// Pluggable source of per-day token + cost totals. Each implementation tails
/// one CLI's session log (Claude Code or Codex JSONL), parses
/// usage events, and pushes today's totals through `onChange` whenever state
/// changes. The aggregator fans these into a single combined frame so the
/// frame stays unaware of multi-provider.
///
/// Conforming types are typically actors; protocol leaves isolation up to the
/// implementation but every stateful method is `async` so callers don't need
/// to know.
protocol UsageProvider: AnyObject, SourceSignals {
    /// Stable identifier used as the key in the per-provider breakdown
    /// and (where applicable) as the suffix on provider-specific persistence
    /// files. Kebab-case, lowercase. Claude is the exception: it keeps the
    /// legacy unqualified `usage-state.json` for upgrade smoothness.
    nonisolated var id: String { get }

    /// Boot the provider. Does any persisted-state load, initial cold scan,
    /// and starts the FSEvents watcher + safety-net poll. The supplied
    /// callback fires on every observed state change.
    func start(onChange: @Sendable @escaping (DayTotals) async -> Void) async

    /// Tear down. Flushes any pending persistence, cancels timers, releases
    /// the FSEvents stream. Idempotent.
    func stop() async

    /// Drops whatever the provider still holds of the days the archive has
    /// just been told to forget. Today is untouched — it is still being
    /// counted, and the archive takes it back on the next flush.
    func forgetArchivedDays() async

    /// Latest totals for today as observed by this provider.
    func current() async -> DayTotals

    /// Number of session files currently being watched. Drives the panel's
    /// and menu bar readiness. Readable without waiting behind the scan.
    nonisolated func filesWatched() -> Int

    /// True once the cold backfill scan has completed.
    func isWarm() async -> Bool

    /// How the provider's day splits across projects, as of its last emit.
    /// Empty for a provider whose format names no working directory.
    ///
    /// Nonisolated for the reason the windows are: the aggregator reads it
    /// while building a slice, inside the hop that produced the totals beside
    /// it, and an actor hop here would pair a breakdown from one moment with
    /// totals from another.
    nonisolated func currentProjects() -> [ProjectTotals]

    /// How the provider's day splits across models, as of its last emit.
    /// Empty for a provider that has read nothing.
    ///
    /// Nonisolated for the reason the projects are, and it matters as much
    /// here: these rows add up to the totals beside them exactly, so a
    /// breakdown fetched across an actor hop would print a split that does
    /// not reach the figure it is the split of.
    nonisolated func currentModels() -> [ModelTotals]

    /// How many sessions this provider saw started today and how many agents
    /// they spawned, as of its last emit.
    ///
    /// Nonisolated for the reason the projects are: the aggregator reads it
    /// inside the hop that produced the totals beside it, so an actor hop here
    /// would pair a count from one moment with a cost from another.
    ///
    /// `.none` for a provider whose format names neither, which is a reading
    /// of zero rather than an absence — the caller knows whether the provider
    /// has read at all, because a provider that has not has no slice.
    nonisolated func currentAgents() -> AgentCounts

    /// Which minutes of today this provider was working in, and which of those
    /// its sub-agents were. `.none` for a provider whose format cannot say, on
    /// the same terms as the counts above.
    nonisolated func currentActivity() -> AgentActivityDay

    /// What each model spent at each effort today, as of this provider's last
    /// emit. Empty for a provider whose format names no effort, on the same
    /// terms as the model split above.
    nonisolated func currentEffort() -> [EffortSplit]

    /// Re-reads whatever this provider keeps out of band — the files it reads
    /// for a plan and an account, which no log line carries. What a user
    /// pressing refresh on this provider reaches; a provider with nothing out
    /// of band takes the default and does nothing.
    func refreshSignals() async

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
    func refreshSignals() async {}

    nonisolated func currentProjects() -> [ProjectTotals] { [] }
    nonisolated func currentModels() -> [ModelTotals] { [] }
    nonisolated func currentAgents() -> AgentCounts { .none }
    nonisolated func currentActivity() -> AgentActivityDay { .none }
    nonisolated func currentEffort() -> [EffortSplit] { [] }
}
