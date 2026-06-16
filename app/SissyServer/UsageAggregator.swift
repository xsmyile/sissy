import Foundation

/// Fans N `UsageProvider` streams into a single combined `(today, prev)`
/// frame. The wire protocol — and therefore the firmware — stays unaware of
/// multi-provider; the daemon sums per-day totals before broadcast.
///
/// `prev` is emitted as non-nil only when every active provider has produced
/// a non-nil `prev`. If any provider is still warming (e.g. a fresh Codex
/// reader on the first poll after install) the aggregated `prev` is nil so
/// `FrameBuilder.pickState` can't trip the `"trend"` branch on a
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
        // for the daemon's full lifetime, and the aggregator outlives both
        // providers and the NIO server. Using `[weak self]` here trips the
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

    func current() -> (today: DayTotals, prev: DayTotals?) {
        aggregate()
    }

    /// Live sum of each provider's `filesWatched()`. Computed on demand
    /// because providers' own counters update during cold-scan / poll even
    /// when no `onChange` fires (e.g. restart from a persisted snapshot
    /// where every offset is already at EOF). A cached value would let
    /// `/health` return `no-jsonl-found` indefinitely until the next token
    /// event nudged it.
    nonisolated func filesWatched() -> Int {
        providers.reduce(0) { $0 + $1.filesWatched() }
    }

    /// True once every provider has finished its cold scan. Empty provider
    /// list returns true so a zero-provider daemon (auto-detect disabled all
    /// of them) doesn't pin the menubar in the cold-start placeholder
    /// forever.
    func isWarm() async -> Bool {
        for p in providers {
            if await !p.isWarm() { return false }
        }
        return true
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

    /// Breakdown slices for the wire: every provider that spent tokens today,
    /// in canonical order. Providers with no usage today (still-warming or
    /// simply unused) are omitted so the menubar Breakdown shows the day's
    /// actual per-CLI split instead of stale `$0` rows.
    private func currentProviderSlices() -> [ProviderSlice] {
        let raw = providers.compactMap { p -> ProviderSlice? in
            guard let s = perProvider[p.id] else { return nil }
            return ProviderSlice(id: p.id, tokens: s.today.totalTokens, cost: s.today.totalCost)
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
