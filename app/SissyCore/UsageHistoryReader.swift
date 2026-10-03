import Foundation

/// Where the engine's readings of the archive are taken: the frame's rollups
/// and a span picked on a calendar, through one `ProjectResolver` and one
/// `UsageHistoryDayCache`, both of which only this actor touches.
///
/// An actor of its own rather than the engine's, because a cold rollup is
/// work the frame path cannot wait on: measured 2026-10-03 on a synthetic
/// archive of 60 days naming 400 distinct project paths, two thirds of them
/// repositories, a rollup with a cold resolver took 50 ms, 30 ms of it the
/// resolver's walks, against 3.2 ms warm, and one naming 100 paths 16 ms
/// against 1.1 ms. On the engine's actor that would have held every emit
/// behind it; here the engine serves the rollups it already has and takes the
/// new ones when they land.
///
/// One resolver for both readings is what makes them agree: attribution is
/// read at the fold rather than kept in the cache, so a preset and a span
/// over the same days split a repository the same way. It is kept for the
/// engine's life on the terms every tail's resolver runs on, an answer pinned
/// until the next launch, which is also what keeps a warm rollup from
/// walking or reading a remote at all. Its isolation is this actor's rather
/// than a convention: the resolver is built here and never handed out.
actor UsageHistoryReader {
    private let directory: URL
    private let projects: ProjectResolver
    private var cache = UsageHistoryDayCache()
    /// The generation `cache` was filled for. A caller moves the generation
    /// whenever what the cache holds can no longer answer, the pricing having
    /// changed, the archive having been deleted or switched off, and the next
    /// rollup starts a cache at the pricing it is handed.
    private var cacheGeneration: Int?

    init(directory: URL, ledger: ProjectLedger) {
        self.directory = directory
        self.projects = ProjectResolver(ledger: ledger)
    }

    /// The rollup of every window in `periods`, at `pricing`, through the
    /// day cache kept for `generation`.
    func rollups(
        for periods: Set<UsagePeriod>, now: Date, pricing: ProviderPricing, generation: Int
    ) -> [UsagePeriod: UsageHistoryRollup] {
        var files = cacheGeneration == generation ? cache : UsageHistoryDayCache(pricing: pricing)
        defer {
            cache = files
            cacheGeneration = generation
        }
        return UsageHistoryStore.rollups(
            for: periods, in: directory, now: now, cache: &files, projects: projects)
    }

    /// What the archive holds for `span`, at `pricing`.
    func reading(over span: UsageDaySpan, pricing: ProviderPricing) -> UsageSpanReading {
        UsageHistoryStore.reading(over: span, in: directory, pricing: pricing, projects: projects)
    }
}
