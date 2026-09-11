import Foundation

/// Fans N `UsageProvider` streams into a single combined `(today, prev)`
/// frame. The frame's own scalars stay unaware of multi-provider: the engine
/// sums per-day totals before emitting and carries the split alongside them.
///
/// `prev` is emitted as non-nil only when every active provider has produced
/// a non-nil `prev`. If any provider is still warming (e.g. a fresh Codex
/// reader on the first poll after install) the aggregated `prev` is nil, so
/// the app shows no day-over-day delta rather than one measured against a
/// half-populated yesterday.
actor UsageAggregator {
    private struct Snapshot {
        var today: DayTotals
        var prev: DayTotals?
    }

    /// Nonisolated so the HTTP path can read it (and `filesWatched()`) without
    /// hopping into the actor. Provider list is set once in init and never
    /// mutated; each provider's own counter is itself nonisolated.
    nonisolated private let providers: [any UsageProvider]
    private var perProvider: [String: Snapshot] = [:]
    private var onChange: (@Sendable (DayTotals, DayTotals?, [ProviderSlice]) async -> Void)?

    init(providers: [any UsageProvider]) {
        self.providers = providers
    }

    /// Boots every provider in parallel. Each provider's `onChange` routes
    /// through `handleProviderEmit` which updates the per-provider snapshot
    /// and re-emits the aggregated `(today, prev, slices)` to the outer
    /// callback. `slices` is captured against the **same** `perProvider`
    /// snapshot as `today`/`prev` so a concurrent emit racing through actor
    /// reentrancy can't desync the aggregate scalars from the per-provider
    /// breakdown.
    func start(onChange: @escaping @Sendable (DayTotals, DayTotals?, [ProviderSlice]) async -> Void) async {
        self.onChange = onChange
        // Strong-self capture is intentional: provider callbacks must fire
        // for the engine's full lifetime, and the aggregator outlives both
        // providers and whatever is rendering them. Using `[weak self]` trips the
        // Swift 6 "capture of var self in concurrently-executing code"
        // diagnostic without buying anything — there's no retain cycle to
        // break because no provider keeps a strong ref back to us.
        let me = self
        await withTaskGroup(of: Void.self) { group in
            for p in providers {
                let pid = p.id
                let provider = p
                group.addTask {
                    await provider.start { today, prev in
                        await me.handleProviderEmit(id: pid, today: today, prev: prev)
                    }
                }
            }
        }
    }

    func stop() async {
        for p in providers { await p.stop() }
    }

    /// Fans a refreshed rate catalog out to every provider. Each takes the
    /// slice for its own vendor.
    func applyPriceCatalog(_ catalog: PriceCatalog) async {
        for p in providers { await p.applyPriceCatalog(catalog) }
    }

    /// Slices rebuilt against each provider's *current* windows. A rate-limit
    /// refresh changes no token total, so a re-emit that replayed the
    /// cached slices would keep shipping the windows captured at the last
    /// ingest — invisible until the CLI happened to write another event.
    func currentSlices() -> [ProviderSlice] {
        currentProviderSlices()
    }

    /// Per-provider scan progress, keyed by provider id. Only the providers
    /// that are actually metering appear: a provider with no reader has no
    /// scan, and the caller renders that as its own state rather than as a
    /// scan that found nothing.
    ///
    /// Read on demand, never cached: a provider's own counters move during
    /// cold scan and poll even when no `onChange` fires — a restart from a
    /// snapshot whose offsets are all at EOF emits nothing at all — and a
    /// cached value would leave the panel saying "no session logs found"
    /// until the next token event nudged it.
    func scanProgress() async -> [String: ProviderReadiness.ScanProgress] {
        var progress: [String: ProviderReadiness.ScanProgress] = [:]
        for p in providers {
            progress[p.id] = ProviderReadiness.ScanProgress(
                filesWatched: p.filesWatched(),
                isWarm: await p.isWarm()
            )
        }
        return progress
    }

    private func handleProviderEmit(id: String, today: DayTotals, prev: DayTotals?) async {
        perProvider[id] = Snapshot(today: today, prev: prev)
        let (combinedToday, combinedPrev) = aggregate()
        // Build slices from the same `perProvider` map that just produced
        // `combinedToday` — both before the upcoming `await`. A concurrent
        // emit can re-enter the actor at the suspension below, but it
        // can't retroactively rewrite the local `slices` we already
        // captured, so the outgoing frame stays internally consistent.
        let slices = currentProviderSlices()
        if let cb = onChange {
            await cb(combinedToday, combinedPrev, slices)
        }
    }

    /// Breakdown slices for the frame: every provider that spent tokens today,
    /// in canonical order. Providers with no usage today (still-warming or
    /// simply unused) are omitted so the panel shows the day's actual per-CLI
    /// split instead of stale `$0` rows.
    ///
    /// Rate-limit windows are read through each provider's nonisolated
    /// accessor. Awaiting the provider here would deadlock: the emit that
    /// leads here runs while the provider still holds its own actor.
    private func currentProviderSlices() -> [ProviderSlice] {
        let raw = providers.compactMap { p -> ProviderSlice? in
            guard let s = perProvider[p.id] else { return nil }
            return ProviderSlice(
                id: p.id,
                tokens: s.today.totalTokens,
                cost: s.today.totalCost,
                windows: p.currentWindows(),
                plan: p.currentPlan(),
                planTier: p.currentPlanTier()
            )
        }
        return FrameBuilder.activeSlices(raw)
    }

    private func aggregate() -> (today: DayTotals, prev: DayTotals?) {
        var todayTok = 0
        var todayCost: Decimal = 0
        for s in perProvider.values {
            todayTok += s.today.totalTokens
            todayCost += s.today.totalCost
        }
        let today = DayTotals(totalTokens: todayTok, totalCost: todayCost)

        var prevTok = 0
        var prevCost: Decimal = 0
        var allHavePrev = !providers.isEmpty
        for p in providers {
            guard let snap = perProvider[p.id], let pv = snap.prev else {
                allHavePrev = false
                break
            }
            prevTok += pv.totalTokens
            prevCost += pv.totalCost
        }
        let prev: DayTotals? = allHavePrev ? DayTotals(totalTokens: prevTok, totalCost: prevCost) : nil
        return (today, prev)
    }
}
