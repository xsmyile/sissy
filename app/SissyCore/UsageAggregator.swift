import Foundation

/// The two values a frame is built from, kept together because they only
/// describe a reading while they describe the same one.
struct UsageReading: Sendable {
    let today: DayTotals
    let slices: [ProviderSlice]
}

/// Fans N `UsageProvider` streams into a single combined today's-total
/// frame. The frame's own scalars stay unaware of multi-provider: the engine
/// sums per-day totals before emitting and carries the split alongside them.
actor UsageAggregator {
    private struct Snapshot {
        var today: DayTotals
    }

    /// Nonisolated so the HTTP path can read it (and `filesWatched()`) without
    /// hopping into the actor. Provider list is set once in init and never
    /// mutated; each provider's own counter is itself nonisolated.
    nonisolated private let providers: [any UsageProvider]
    private var perProvider: [String: Snapshot] = [:]
    private var onChange: (@Sendable (DayTotals, [ProviderSlice]) async -> Void)?

    init(providers: [any UsageProvider]) {
        self.providers = providers
    }

    /// Boots every provider in parallel. Each provider's `onChange` routes
    /// through `handleProviderEmit` which updates the per-provider snapshot
    /// and re-emits the aggregated `(today, slices)` to the outer callback.
    /// `slices` is captured against the **same** `perProvider` snapshot as
    /// `today` so a concurrent emit racing through actor reentrancy can't
    /// desync the aggregate scalars from the per-provider breakdown.
    func start(onChange: @escaping @Sendable (DayTotals, [ProviderSlice]) async -> Void) async {
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
                    await provider.start { today in
                        await me.handleProviderEmit(id: pid, today: today)
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

    /// Fans the archive deletion out, so no provider can rewrite a day the
    /// user has just asked Sissy to forget.
    func forgetArchivedDays() async {
        for p in providers { await p.forgetArchivedDays() }
    }

    /// What a frame would be built from right now.
    ///
    /// Both halves are recomputed here rather than replayed: a rate-limit
    /// refresh changes no token total, so slices captured at the last ingest
    /// would keep shipping the windows from before it — invisible until the
    /// CLI happened to write another event. And they are recomputed in one
    /// hop, with no suspension between them, so a caller cannot pair totals
    /// from one moment with a breakdown from another.
    func currentReading() -> UsageReading {
        UsageReading(today: aggregate(), slices: currentProviderSlices())
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

    private func handleProviderEmit(id: String, today: DayTotals) async {
        perProvider[id] = Snapshot(today: today)
        let combinedToday = aggregate()
        // Build slices from the same `perProvider` map that just produced
        // `combinedToday` — both before the upcoming `await`. A concurrent
        // emit can re-enter the actor at the suspension below, but it
        // can't retroactively rewrite the local `slices` we already
        // captured, so the outgoing frame stays internally consistent.
        let slices = currentProviderSlices()
        if let cb = onChange {
            await cb(combinedToday, slices)
        }
    }

    /// Hands one provider the chance to re-read its own out-of-band files.
    /// Unknown ids are a no-op: the caller names a provider that may not be
    /// built on this run.
    func refreshSignals(for id: String) async {
        guard let provider = providers.first(where: { $0.id == id }) else { return }
        await provider.refreshSignals()
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
                planTier: p.currentPlanTier(),
                credits: p.currentCredits(),
                projects: p.currentProjects(),
                account: p.currentAccount(),
                limitsState: p.currentLimitsState()
            )
        }
        return FrameBuilder.activeSlices(raw)
    }

    private func aggregate() -> DayTotals {
        var todayTok = 0
        var todayCost: Decimal = 0
        for s in perProvider.values {
            todayTok += s.today.totalTokens
            todayCost += s.today.totalCost
        }
        return DayTotals(totalTokens: todayTok, totalCost: todayCost)
    }
}
