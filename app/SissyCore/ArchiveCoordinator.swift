import Foundation

/// The archive as the engine drives it: the rollups the frame carries, the pass
/// that fills the archive in from the CLIs' logs, and the daily prune.
///
/// A value on the engine rather than an actor of its own, for the reason
/// `KeepAwakeController` is one: `UsageEngine.stop` cancels the pass and the
/// reader without suspending, and every call here is one more that does not. The
/// tasks it starts come back through closures the engine hands it, so anything
/// that has to happen on the engine still does. What it does not hold is the
/// setting, and deleting the archive stays the engine's, because its order runs
/// through the providers. See `UsageEngine.deleteHistory`.
struct ArchiveCoordinator {
    /// What became of a rollup the reader finished.
    enum Landing {
        /// It was started before the generation moved, so what it holds can no
        /// longer answer and it should be read again.
        case stale
        case unchanged
        case changed
    }

    /// How long the rollups are reused before the day files are read again.
    /// Long enough that frames do not walk the archive, short enough that a
    /// window is never visibly behind the day it includes.
    ///
    /// It survives the archive growing from days to years because
    /// `reader`'s day cache reads a day file again only once it changes:
    /// measured 2026-09-29, a rebuild over this Mac's 62 files went from
    /// 7.6 ms to 0.6 ms, and over a 7,300-file archive from 1,100 ms to 70 ms.
    /// What a backfill needs is not a longer interval but a frame —
    /// `invalidateHistoryRollups` — since an idle Mac emits nothing and the
    /// panel would otherwise hold yesterday's windows until the next turn.
    private static let rollupTTL: TimeInterval = 2

    private let stateDir: URL
    /// Where the rollups and a picked span are read, off the engine, through
    /// the one resolver and day cache the reader keeps for the engine's life.
    let reader: UsageHistoryReader
    private let projectLedger: ProjectLedger
    /// Last archive rollups and when they landed. The day files are written
    /// by the providers on their own throttle, so the frame re-reads them rather
    /// than being told; the cache is what keeps a burst of frames from turning
    /// into a burst of directory walks.
    private var rollups: [UsagePeriod: UsageHistoryRollup] = [:]
    private var rollupAt: Date = .distantPast
    /// The rollup the reader is taking now, so a burst of frames past the TTL
    /// starts one rather than one each.
    private var refresh: Task<Void, Never>?
    /// Moves whenever the rollups held, or the reader's day cache, can no
    /// longer answer: the pricing changed, the archive was deleted or switched
    /// off. A rollup started before the move is dropped when it lands rather
    /// than served.
    private var generation = 0
    /// Day the archive was last pruned for. Retention is measured in days, so
    /// the answer changes only when the day does — and a Mac that stays up for
    /// a month has to keep the promise the setting makes without waiting for a
    /// relaunch to enforce it.
    private var lastPruneDay: Date?
    /// Handle on the one-time archive backfill, which is a read of the whole log
    /// tree: a quit has to interrupt it rather than wait for it.
    private(set) var backfillTask: Task<Void, Never>?

    init(stateDir: URL, reader: UsageHistoryReader, projectLedger: ProjectLedger) {
        self.stateDir = stateDir
        self.reader = reader
        self.projectLedger = projectLedger
    }

    // MARK: The rollups

    /// What the archive holds for every period the panel offers, cached for a
    /// beat and read off the engine.
    ///
    /// Empty when the archive is switched off, and when it is on but empty — a
    /// control offering four windows that all come to nothing offers a feature
    /// rather than a reading, so the panel keeps the headline on today until
    /// there is something behind it. The widest window decides that for all of
    /// them: it contains the others, so nothing in it is nothing anywhere.
    ///
    /// The cache is kept even when the answer is withheld, so an empty archive
    /// costs one directory walk every `rollupTTL` rather than one per
    /// frame. Switching the archive off drops it instead: the setting can come
    /// back inside the TTL, and serving what was read before it went off would
    /// answer for days the user asked to stop recording.
    ///
    /// Past the TTL the frame is built from the rollups already held while
    /// `reader` takes new ones, and `land` emits again once they
    /// differ: a cold rollup walks every project path the archive names, which
    /// `UsageHistoryReader` measures, and every emit would otherwise wait on
    /// it. The first frame after launch therefore carries no windows, and the
    /// one after the reader lands does.
    mutating func current(
        retentionDays: Int, now: Date, pricing: ProviderPricing,
        land: @escaping @Sendable ([UsagePeriod: UsageHistoryRollup], Int) async -> Void
    ) -> [UsagePeriod: UsageHistoryRollup] {
        guard retentionDays > 0 else {
            if !rollups.isEmpty || refresh != nil {
                rollups = [:]
                generation += 1
            }
            rollupAt = .distantPast
            return [:]
        }
        if now.timeIntervalSince(rollupAt) >= Self.rollupTTL {
            refreshRollups(now: now, pricing: pricing, land: land)
        }
        return (rollups[.all]?.tokens ?? 0) > 0 ? rollups : [:]
    }

    /// Has the reader take every window's rollup, unless it is taking them
    /// already.
    mutating func refreshRollups(
        now: Date, pricing: ProviderPricing,
        land: @escaping @Sendable ([UsagePeriod: UsageHistoryRollup], Int) async -> Void
    ) {
        guard refresh == nil else { return }
        let reader = reader
        let generation = generation
        refresh = Task {
            let rollups = await reader.rollups(
                for: Set(UsagePeriod.archived), now: now, pricing: pricing, generation: generation)
            await land(rollups, generation)
        }
    }

    /// Takes a rollup the reader finished, and answers whether a frame or another
    /// read is owed.
    ///
    /// The TTL runs from here rather than from the start, so a rollup slower
    /// than the TTL is not started again the moment it lands. One started
    /// before the generation moved is dropped and read again at once, since
    /// what it holds is the archive as it stood before a deletion or priced
    /// at a catalog since replaced; the archive switched off meanwhile is
    /// not read again at all.
    mutating func land(_ landed: [UsagePeriod: UsageHistoryRollup], generation landedAt: Int) -> Landing {
        guard landedAt == generation else {
            rollupAt = .distantPast
            return .stale
        }
        rollupAt = Date()
        guard landed != rollups else { return .unchanged }
        rollups = landed
        return .changed
    }

    /// The reader is no longer taking a rollup.
    mutating func refreshEnded() {
        refresh = nil
    }

    mutating func cancelRefresh() {
        refresh?.cancel()
        refresh = nil
    }

    /// The next frame reads the day files again.
    mutating func expireRollups() {
        rollupAt = .distantPast
    }

    /// The rates moved, and the reader's day cache holds each day already priced.
    mutating func pricingChanged() {
        generation += 1
    }

    /// The archive was deleted: nothing held or being read can still answer.
    mutating func dropRollups() {
        rollups = [:]
        rollupAt = .distantPast
        generation += 1
    }

    /// Prunes the archive to what `historyRetentionDays` allows, once for each
    /// day the engine is alive across.
    ///
    /// The engine owns this rather than the tails: a provider the user has
    /// switched off is never built, and the days it recorded would otherwise
    /// sit in the archive past a retention that was supposed to bound them.
    /// It runs at boot and on the frame path: boot is what bounds an archive
    /// whose providers are all switched off and emitting nothing, and the
    /// frame path is what enforces retention on a Mac that stays up across a
    /// day boundary. The guard makes every call after the day's first free.
    mutating func pruneIfDue(retentionDays: Int, now: Date) {
        let today = Calendar.current.startOfDay(for: now)
        guard lastPruneDay != today else { return }
        lastPruneDay = today
        UsageHistoryStore.prune(keeping: retentionDays, in: stateDir, now: now)
    }

    // MARK: The pass that fills it in

    /// Fills the archive in from the CLIs' own logs, once per provider, for
    /// every day older than the window the live tail owns.
    ///
    /// Detached and at `utility`, because it reads the whole log tree — about
    /// 870 MB and 35 s on one real machine — and the app is usable throughout.
    /// Each provider gets its own pass and its own record, so a CLI switched
    /// on months from now fills its own history in without touching the one
    /// beside it.
    ///
    /// The record is written only where a pass ran to completion and read
    /// every log it listed. Until then the span is owed in the same file, so the
    /// next launch asks again whatever the tail has done since, and a provider
    /// whose pass met a log it could not read holds up its own record only: the
    /// providers after it still get their pass.
    mutating func startBackfill(
        config: ServerConfig,
        homes: [(home: ProviderHome, snapshot: URL)],
        catalog: PriceCatalog?,
        invalidated: @escaping @Sendable () async -> Void,
        record: @escaping @Sendable (String, Range<Date>, [String], URL) async -> Void
    ) {
        let retentionDays = config.resolvedHistoryRetentionDays
        guard retentionDays > 0, let window = ArchiveBackfill.window(retentionDays: retentionDays)
        else { return }
        let ledgerURL = ArchiveBackfillLedger.defaultURL(in: stateDir)
        let ledger = ArchiveBackfillLedger.load(from: ledgerURL)
        var due: [(home: ProviderHome, span: Range<Date>)] = []
        for (home, snapshot) in homes {
            guard
                let span = ArchiveBackfill.uncovered(
                    window,
                    coverage: ledger.coverage[home.id],
                    owed: ledger.owed[home.id],
                    pending: ledger.pending[home.id],
                    meteredThrough: ArchiveBackfill.lastMetered(snapshotAt: snapshot))
            else { continue }
            due.append((home: home, span: span))
        }
        guard !due.isEmpty else { return }
        ArchiveBackfillLedger.note(
            passes: due.map { (provider: $0.home.id, span: $0.span) }, within: window,
            startingAt: ledgerURL)
        let stateDir = stateDir
        let projectLedger = projectLedger
        let pricingOverride = config.pricingOverride
        backfillTask = Task.detached(priority: .utility) {
            for (home, span) in due {
                if Task.isCancelled { return }
                let provider = Self.backfillProvider(
                    home: home,
                    window: span,
                    historyRoot: stateDir,
                    pricingOverride: pricingOverride,
                    ledger: projectLedger)
                if let catalog { await provider.applyPriceCatalog(catalog) }
                let outcome = await provider.backfillArchive { await invalidated() }
                if Task.isCancelled { return }
                await record(home.id, span, outcome.unread, ledgerURL)
            }
        }
    }

    mutating func cancelBackfill() {
        backfillTask?.cancel()
    }

    mutating func clearBackfill() {
        backfillTask = nil
    }

    /// Hands over the pass in flight, for a caller that has to wait it out.
    mutating func takeBackfill() -> Task<Void, Never>? {
        defer { backfillTask = nil }
        return backfillTask
    }

    /// One provider's backfill reader: the same adapter the tail uses, over
    /// the same tree, with a window of its own and nothing persisted but day
    /// files. `sissy-cli --backfill` builds its passes through here too, so the
    /// pass CI asserts against the oracle is the one the app runs.
    static func backfillProvider(
        home: ProviderHome,
        window: Range<Date>,
        historyRoot: URL,
        pricingOverride: [String: ModelPricing]?,
        ledger: ProjectLedger
    ) -> LocalUsageProvider {
        switch home.id {
        case ProviderID.codex:
            return LocalUsageProvider.codex(
                codexDir: home.dataDir,
                id: home.id,
                historyRoot: historyRoot,
                pricingOverride: pricingOverride,
                ledger: ledger,
                backfill: window)
        default:
            return LocalUsageProvider.claudeCode(
                claudeDir: home.dataDir,
                id: home.id,
                historyRoot: historyRoot,
                pricingOverride: pricingOverride,
                profile: ClaudeProfileSource(url: home.claudeProfileURL),
                ledger: ledger,
                backfill: window)
        }
    }
}
