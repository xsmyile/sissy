import Foundation

struct UsageEvent: Sendable, Equatable {
    let timestamp: Date
    /// The model the adapter priced this event at, carried on the event
    /// because that is the only place it is known: the tail sees bytes and a
    /// cost, and the archive needs a row per model.
    let model: String
    /// Repository the work was in, resolved from the working directory the
    /// line named. Nil when it named none — an adapter reading a format that
    /// does not carry one, or a line written outside any directory Sissy can
    /// resolve.
    let project: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    let cost: Decimal
}

/// One line of a session log, as handed to a `SourceAdapter`.
///
/// `byteOffset` is the line's absolute position in the file, which is what
/// Codex dedups on; `retainCutoff` is recomputed per line so a scan that runs
/// across the window's edge admits exactly what it would have a moment ago.
struct SourceLine {
    let data: Data
    let url: URL
    let byteOffset: UInt64
    let retainCutoff: Date
}

/// The facts `LocalUsageProvider` copies out of its adapter at init, so it can
/// answer them from outside its own actor.
struct SourceDescriptor: Sendable {
    /// Stable provider id, also the key its row is drawn under and the suffix
    /// on its persistence file.
    let id: String
    /// Root of the session-log tree: enumerated on every poll, watched by
    /// FSEvents, and hashed into the snapshot so pointing the provider
    /// somewhere else invalidates it.
    let root: URL
    /// FSEvents queue label, one per source so a stack trace names the tail
    /// it came from.
    let watcherLabel: String
    /// Everything the adapter answers for that is not a token count, readable
    /// without entering the provider's actor.
    let signals: SourceSignals
}

/// What the dedup ledger remembers about a key it has already counted.
///
/// The day is what the ledger is trimmed by. The output count is what makes a
/// repeat something other than a line to drop: Claude Code writes the same
/// message several times while the answer streams, and `output_tokens` grows
/// with each write while the input and cache counts — fixed when the request
/// was made — repeat unchanged. A reader that keeps the first copy bills the
/// first partial and never the rest of the answer.
struct SeenEvent: Equatable, Sendable {
    var day: Date
    /// Output tokens already billed for this key, or nil for a key restored
    /// from a snapshot written before the ledger carried one. Nil claims the
    /// key and owes nothing further: the amount cannot be recovered, and
    /// under-counting one day's in-flight messages once, on the first launch
    /// after an upgrade, beats billing them twice.
    var billedOutputTokens: Int?
}

/// One CLI's log format, behind the tail every local provider shares.
///
/// An adapter owns exactly three things: which bytes on a line are worth
/// parsing, what a line costs, and which of its own state has to survive a
/// relaunch. Everything else — offsets, mtimes, the watcher, the poll, the
/// dedup ledger, the day buckets, persistence, the emit throttle — belongs to
/// `LocalUsageProvider`.
///
/// Adapters are only ever touched from inside the provider's actor, which is
/// what lets them hold plain mutable parsing state.
protocol SourceAdapter: AnyObject {
    var descriptor: SourceDescriptor { get }

    /// The one resolver this provider answers project questions with, the
    /// adapter's own because the adapter is what reads a working directory off
    /// a line. The provider borrows it for the paths it reads back off disk:
    /// two resolvers would disagree about a deleted checkout as soon as one of
    /// them had seen it alive and the other had not.
    var projects: ProjectResolver { get }

    /// True when the bytes of one line are worth a JSON parse. Run on the raw
    /// chunk before any allocation: on both formats the overwhelming majority
    /// of lines carry no usage at all.
    func lineMayCount(_ buf: UnsafePointer<UInt8>, from: Int, to: Int) -> Bool

    /// Turns one line into a billable event, nil for every other shape.
    ///
    /// The adapter claims its own dedup key in `seen` — the key's shape is the
    /// format's business, while the ledger is the provider's because the
    /// provider is what persists and trims it. Events older than
    /// `line.retainCutoff` are dropped without claiming a key.
    ///
    /// `activity` is the second thing a line can report, and it is an `inout`
    /// accumulator for the reason `seen` is: both are state the provider owns
    /// and the adapter contributes to, and both have to be filled from the one
    /// JSON parse this call is allowed. A line that spawns an agent is a line
    /// that also spent tokens — measured 2026-09-18, 189 of 189 `Agent` blocks
    /// rode an assistant line carrying `message.usage` — so asking the adapter
    /// twice would parse the same bytes twice to learn two halves of one
    /// reading. Appending nothing is the ordinary answer.
    func event(
        from line: SourceLine,
        seen: inout [String: SeenEvent],
        activity: inout [AgentActivityEvent]
    ) -> UsageEvent?

    /// Swap in a freshly fetched rate catalog. The adapter takes the slice
    /// matching its upstream vendor.
    func applyPriceCatalog(_ catalog: PriceCatalog)

    /// Ran once after any snapshot load and before the first emit, for state
    /// the adapter reads out of band rather than off a log line. True when it
    /// changed something the next snapshot should carry.
    func prepareToStart() -> Bool

    /// Ran at the top of every wake — the FSEvents batch a turn raises as well
    /// as the safety-net poll — for out-of-band state that goes stale. The
    /// adapter decides what that costs: this runs at whatever rate the CLI
    /// writes, so anything expensive behind it needs its own floor.
    func willRead()

    /// Re-reads the out-of-band state on demand, for the one surface that
    /// asks: a user pressing refresh. True when something changed that the
    /// next snapshot should carry.
    func refreshOutOfBandState() -> Bool

    /// Drops per-file state for files the provider no longer tracks, so an
    /// adapter's own maps age out with the offsets they describe.
    func trim(retaining files: Set<URL>)

    /// Takes the adapter's slice of a snapshot, before the provider commits
    /// any of its own. Returning false discards the whole snapshot and forces
    /// a cold scan, so an adapter that refuses must do it without having
    /// mutated anything.
    func resume(from snapshot: UsageStateSnapshot, offsets: [URL: UInt64]) -> Bool

    /// The adapter's slice of the snapshot being written. The field is named
    /// for the one source that has ever needed it.
    func resumeState() -> UsageStateSnapshot.CodexResume?
}

extension SourceAdapter {
    func prepareToStart() -> Bool { false }
    func willRead() {}
    func refreshOutOfBandState() -> Bool { false }
    func trim(retaining files: Set<URL>) {}
    func resume(from snapshot: UsageStateSnapshot, offsets: [URL: UInt64]) -> Bool { true }
    func resumeState() -> UsageStateSnapshot.CodexResume? { nil }
}

/// The tail behind every provider that reads a CLI's session logs off local
/// disk: file enumeration, per-file offsets and mtimes, the FSEvents watcher,
/// the safety-net poll, dedup, day buckets, snapshot persistence and the
/// throttled emit. What differs per CLI lives in its `SourceAdapter`.
actor LocalUsageProvider: UsageProvider {
    nonisolated let id: String
    nonisolated private let signals: SourceSignals

    private let adapter: any SourceAdapter
    private let root: URL
    private let watcherLabel: String
    private let retainDays: Int
    private let pollInterval: Duration
    /// When non-nil, the provider snapshots its state to this URL on a
    /// throttle and on stop. On `start` it tries to load + reconcile the
    /// snapshot so a relaunch skips the cold backfill. Nil disables
    /// persistence entirely — used by `--scan` and tests that want a fresh
    /// provider without touching the user's saved state.
    private let persistenceURL: URL?
    /// Parent of the archive tree, following the config that named the trees
    /// being metered exactly as the snapshot does. Nil turns the archive off
    /// entirely — a retention of zero days, `--scan`, and any test that has no
    /// business writing one. Retention itself is the engine's: it prunes every
    /// provider directory there is, including one whose provider is switched
    /// off and therefore never built.
    private let historyRoot: URL?
    /// The span of events this provider counts, when it is a backfill pass
    /// rather than the live tail.
    ///
    /// Non-nil turns the whole instance around: it counts this fixed range
    /// instead of the rolling window, it is driven by `backfillArchive()`
    /// rather than `start()`, and it writes day files and nothing else — no
    /// snapshot, no watcher, no emit. The range ends where the tail's window
    /// begins, so the two never write the same day and no coverage check has
    /// to arbitrate between them.
    private let backfill: Range<Date>?

    private var fileOffsets: [URL: UInt64] = [:]
    private var fileMTimes: [URL: TimeInterval] = [:]
    private var dailyTotals: [Date: DayTotals] = [:]
    /// The same days as `dailyTotals`, split by model, which is the grain the
    /// archive keeps. Fed by the same `ingest` and trimmed by the same
    /// `trim()`, so the two cannot describe different days.
    private var dailyModelTotals: [Date: [UsageHistoryRow: UsageHistoryTotals]] = [:]
    /// The same days again, counted rather than measured: how many sessions
    /// were started and how many agents they spawned.
    ///
    /// A third map rather than a field on the two above, because it is a third
    /// grain: `dailyTotals` is one pair of scalars for the provider's day and
    /// `dailyModelTotals` a row per model per project, while a count belongs to
    /// the provider's day and to no model at all. Fed by the same `ingest` and
    /// trimmed by the same `trim()`, so no day can exist in one and not the
    /// others.
    private var dailyAgentCounts: [Date: AgentCounts] = [:]
    /// Days whose archive file is behind what is in memory.
    private var historyDirtyDays: Set<Date> = []
    /// Days this process must not write, because it cannot vouch for them: a
    /// snapshot restored totals for a day it carries no per-model rows for,
    /// which is what the first launch after the archive shipped looks like.
    /// Writing one then would freeze a day that counts only from the upgrade
    /// onwards. A missing day is recoverable — a wrong one, once it ages out
    /// of the retain window, is permanent.
    private var historySuppressedDays: Set<Date> = []
    private var lastHistorySaveAt: Date = .distantPast
    /// Dedup keys tagged with the event day. The day tag lets `trim()` evict
    /// keys older than the retain window (previously the set grew unbounded
    /// across long-running sessions) and lets the persistence layer
    /// store only today's keys without losing the streaming-across-restart
    /// safety net.
    private var seenEventKeys: [String: SeenEvent] = [:]
    /// Today's project split, republished on every emit so the aggregator
    /// can read it without an actor hop.
    private let publishedProjects = LockedValue<[ProjectTotals]>([])
    /// Today's agent counters, republished on every emit for the reason the
    /// project split is: the aggregator reads them while this provider still
    /// holds its own actor, so an `await` here would deadlock the emit that
    /// produced them.
    private let publishedAgents = LockedValue<AgentCounts>(.none)
    private let publishedUsage = LockedValue(ProviderSignals())
    private var lastPublishedSignals: ProviderSignals?
    private var pollTask: Task<Void, Never>?
    private var onChange: (@Sendable (DayTotals) async -> Void)?
    nonisolated private let watchedCounter = LockedValue(0)
    /// FSEvents-backed primary wake source. When non-nil, kernel-level
    /// notifications drive `ingestEventPaths` directly and the `pollTask`
    /// timer only runs as a low-frequency safety net (missed events,
    /// midnight rollover with no JSONL activity).
    private var fsWatcher: FSWatcher?

    private var persistDirty = false
    private var lastSaveAt: Date = .distantPast
    /// startOfDay of the most recent `onChange` emit. When `poll()` observes a
    /// different `startOfDay(now)` it forces an emit even without new JSONL
    /// activity so the UI rolls over to a fresh "today" frame at midnight
    /// (and on the first poll after a long system sleep that crossed it).
    /// Nil until the first emit so we never fire a synthetic rollover before
    /// the provider has produced a real frame.
    private var lastEmittedDayKey: Date?
    /// False until the initial backfill scan has finished parsing every
    /// in-window JSONL. What `isWarm()` answers, and so what the panel and
    /// the Providers tab read to tell a reader that has found nothing yet
    /// from one that has finished and found nothing. The flag flips once
    /// after `start()` runs its blocking cold pass.
    private var coldScanComplete = false
    /// A provider runs once. `stopped` is terminal for the same reason
    /// `UsageEngine.lifecycle` is: the app builds a fresh engine, and with it
    /// fresh providers, when it needs one, so reviving this instance would
    /// leave two tails on the same tree.
    private enum Lifecycle {
        case idle
        case running
        case stopped
    }

    /// Where this provider is in that sequence.
    ///
    /// `start()` re-reads this after the cold scan, because a `stop()` can
    /// land in any of the suspensions the scan is made of: the actor is
    /// released on every `Task.yield()` and every emit. Until it was read
    /// back, the rest of `start()` overtook the teardown — declaring the
    /// scan complete on a partial pass, then arming an FSEvents stream and a
    /// 60 s loop that nothing was left to cancel.
    ///
    /// It is also what an FSEvents batch already in flight is answered with,
    /// and what makes `poll()`'s post-yield check true to its comment: a
    /// teardown, not only a cancelled boot task, now interrupts a cold scan.
    private var lifecycle: Lifecycle = .idle
    /// Max wall-clock between throttled saves. SIGKILL/power loss bounds
    /// progress loss to this window; SIGTERM still flushes cleanly via
    /// `stop()`. Five seconds keeps SSD churn low on a long-running process.
    private static let saveThrottle: TimeInterval = 5

    /// The oldest instant a line may carry and still count.
    ///
    /// A rolling window of absolute time rather than a span of calendar days,
    /// and derived in one place so every reader of it agrees: the day the
    /// parser cuts, the day the buckets drop and the day the archive refuses
    /// to freeze are all the same day.
    ///
    /// A backfill pass answers with its own range instead. It is computed once
    /// and fixed, where the tail's slides with the clock: the pass takes tens
    /// of seconds, and a window that moved underneath it would admit a
    /// different set of days at its end than at its start.
    private var retainWindowStart: Date {
        backfill?.lowerBound ?? Self.liveWindowStart(retainDays: retainDays)
    }

    /// The oldest instant a live tail counts, derived here so the backfill can
    /// end its own window exactly where this begins.
    ///
    /// Rolling absolute time, not calendar days — which is why the backfill
    /// must ask rather than recompute: across a daylight-saving boundary a
    /// day is 23 or 25 hours, so two subtractions written two ways disagree
    /// about which day this lands in, and the two windows would then either
    /// both claim a day or leave one to nobody.
    static func liveWindowStart(retainDays: Int, now: Date = Date()) -> Date {
        now.addingTimeInterval(-Double(retainDays) * secondsPerDay)
    }

    private static let secondsPerDay: TimeInterval = 86_400

    /// Files consumed between cooperative yields. Without them the actor pins
    /// one Swift concurrency thread for a whole scan, and the check after the
    /// yield is what lets a teardown interrupt one.
    private static let yieldInterval = 4

    /// Days the live tail answers for. Two, since v0.1.0.
    ///
    /// It bounds three separate things — the cold scan at launch, the dedup
    /// ledger and day buckets held in memory, and **which days the tail owns
    /// in the archive**. Only the third is a statement about the archive, and
    /// `ArchiveBackfill` owns every day older than it.
    static let defaultRetainDays = 2

    /// FSEvents coalescing window. Higher = more batching (lower CPU, more
    /// notifications coalesced into one wake); lower = snappier UI updates.
    /// 1.0 s matches the previous polling cadence — users experienced no
    /// latency change in the migration, and burst-write turns get one wake
    /// instead of many.
    private static let fsEventsLatency: CFTimeInterval = 1.0

    init(
        adapter: sending any SourceAdapter,
        retainDays: Int = LocalUsageProvider.defaultRetainDays,
        pollInterval: Duration = .seconds(60),
        persistenceURL: URL? = nil,
        historyRoot: URL? = nil,
        backfill: Range<Date>? = nil
    ) {
        let descriptor = adapter.descriptor
        self.adapter = adapter
        self.id = descriptor.id
        self.root = descriptor.root
        self.watcherLabel = descriptor.watcherLabel
        self.signals = descriptor.signals
        self.retainDays = retainDays
        self.pollInterval = pollInterval
        self.persistenceURL = persistenceURL
        self.historyRoot = historyRoot
        self.backfill = backfill
    }

    /// The adapter's own reading, with the live-activity marker this tail
    /// keeps for it: an adapter answers for its vendor's files, and only the
    /// tail knows when its cold scan stopped and the day became live.
    nonisolated func currentSignals() -> ProviderSignals {
        var reading = signals.currentSignals().live()
        reading.lastActivityAt = publishedUsage.load().lastActivityAt
        return reading
    }

    /// Hands the adapter the chance to re-read its own out-of-band files. The
    /// engine re-emits afterwards, so nothing is published from here.
    func refreshSignals() async {
        if adapter.refreshOutOfBandState() { persistDirty = true }
    }

    func applyPriceCatalog(_ catalog: PriceCatalog) {
        adapter.applyPriceCatalog(catalog)
    }

    func start(onChange: @escaping @Sendable (DayTotals) async -> Void) async {
        guard backfill == nil else {
            sissyLog("sissy: \(id) refused to tail — this provider is a backfill pass")
            return
        }
        guard lifecycle == .idle else { return }
        lifecycle = .running
        self.onChange = onChange
        let loaded = loadAndApplyPersistedState()
        if !loaded { suppressTheDayAColdScanCuts() }
        // Ahead of the cold scan the line above may have just forced: the scan
        // is what reads lines naming checkouts that have to be recognised, and
        // the ones still on disk are recognised only if git has been asked
        // about them first.
        adapter.projects.ledger.refreshKnownRepositories()
        // The pass that matters: the resolver caches its answer per directory
        // for the life of the process, including the nil, so a checkout the
        // cold scan below asks about is pinned to whatever the ledger knew
        // before it started.
        adapter.projects.ledger.ingestInbox()
        // Ahead of the restored-snapshot emit below, so the first frame a
        // relaunch replays already carries what the adapter reads out of band
        // — a plan the log itself will not name again until the next turn.
        if adapter.prepareToStart() { persistDirty = true }
        // If we restored a snapshot, fire the callback immediately. Without
        // this emit the first frame waits for the next JSONL append — minutes
        // of idle between turns — and the panel sits on its empty-day
        // placeholder despite valid totals being in memory.
        if loaded { await emitReading() }
        await poll()
        // The scan above ends either because it finished or because it was cut
        // short, and only the first may be taken for a complete pass. A
        // cancelled boot task bails `poll()` out of its file loop; a `stop()`
        // can land in any of the suspensions it is made of. Resuming past this
        // guard used to arm a stream and a loop the teardown had no handle
        // left to cancel.
        guard lifecycle == .running, !Task.isCancelled else { return }
        coldScanComplete = true
        // Read back once more before arming anything: `pollTask` is
        // unstructured and inherits nothing, so a boot cancelled during the
        // emit above would otherwise leave a 60 s loop behind it.
        guard lifecycle == .running, !Task.isCancelled else { return }
        startFSWatcher()
        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                await self?.poll()
            }
        }
    }

    /// Writes the archive for every day older than the window the live tail
    /// owns, reading the CLIs' own logs, and answers with how many day files
    /// it wrote. The one entry point for a provider built with a `backfill`
    /// range.
    ///
    /// It reads the same trees through the same adapter as the tail, which is
    /// the whole design: the rules that make a metered day land on `ccusage`
    /// exactly — a Claude turn billed by the growth in its output, a Codex
    /// `token_count` whose running total has not moved, a forked session
    /// replaying its parent — are the tail's, so a backfilled day inherits
    /// them rather than reimplementing them. It keeps none of what it learns:
    /// no snapshot is written, so the tail resumes from the byte it left off
    /// at whether this ran or not.
    ///
    /// Days are flushed as they are *proved* complete rather than at the end.
    /// Files come newest first, so once one of mtime `M` has been consumed no
    /// unread file can carry an event later than `M`, and every day after
    /// `M`'s is final. Writing them then is what fills the panel's windows in
    /// while the pass runs; writing only them is what stops an interrupted
    /// pass from freezing a day it had read half of, which `isCoveredBy`
    /// would refuse to repair on a machine where a worktree has since been
    /// deleted.
    ///
    /// The ledger is asked about git before the first byte is read, so the
    /// attribution a pass can give does not depend on whether the live tail
    /// happened to be scheduled first — both are detached, and nothing orders
    /// them. What is *not* done here is the inbox: it is consumed on read, and
    /// a pass that drained it would take entries out from under the tail's own
    /// resolver, which caches what it is told for the life of the process.
    func backfillArchive(onDaysWritten: @Sendable () async -> Void = {}) async -> Int {
        guard backfill != nil, historyRoot != nil, lifecycle == .idle else { return 0 }
        lifecycle = .running
        defer { lifecycle = .stopped }
        adapter.projects.ledger.refreshKnownRepositories()
        let files = enumerateJSONLSortedByMTime()
        watchedCounter.store(files.count)
        let cal = Calendar.current
        var written = 0
        var interrupted = false
        for (index, file) in files.enumerated() {
            _ = ingestNewLines(in: file.url)
            if index % Self.yieldInterval == Self.yieldInterval - 1 {
                await Task.yield()
                if Task.isCancelled {
                    interrupted = true
                    break
                }
            }
            let complete = saveHistoryIfDirty(
                finalizedAfter: cal.startOfDay(for: Date(timeIntervalSince1970: file.mtime)))
            if complete > 0 {
                written += complete
                await onDaysWritten()
            }
        }
        if !interrupted {
            let remaining = saveHistoryIfDirty(force: true)
            if remaining > 0 {
                written += remaining
                await onDaysWritten()
            }
        }
        sissyLog(
            "sissy: \(id) backfill read \(files.count) log file(s) and wrote \(written) "
                + "archived day(s)\(interrupted ? " before it was cancelled" : "")")
        return written
    }

    func stop() async {
        guard lifecycle != .stopped else { return }
        // Ahead of the flush, so a `poll()` or an FSEvents batch queued behind
        // this one bails instead of writing after the final snapshot.
        lifecycle = .stopped
        // Force a final flush so a clean SIGTERM never loses unsaved offset
        // progress. Best-effort: a save failure is logged where it happens and
        // nothing on the shutdown path can act on it.
        adapter.projects.ledger.saveIfDirty()
        saveSnapshotIfDirty(force: true)
        saveHistoryIfDirty(force: true)
        fsWatcher?.stop()
        fsWatcher = nil
        pollTask?.cancel()
        pollTask = nil
        // Release the emit callback so the aggregator that captured
        // `self` via the closure can be reclaimed. Without this clear the
        // strong-self capture in `UsageAggregator.start` would keep the
        // aggregator (and therefore every provider) alive for the rest of
        // the process — irrelevant for a normal app lifetime, but
        // it shows up as a leak in test harnesses that boot+stop many
        // providers within one process.
        onChange = nil
    }

    /// Boots an FSEvents watcher rooted at the source tree. FSEvents wakes are
    /// the primary trigger for JSONL ingest; the surviving `pollTask` runs
    /// at the configured cadence (default 60s) as a safety net for missed
    /// events and midnight rollover with no JSONL activity. The stream is
    /// rooted at the tree, so subdirectories a CLI creates on demand — a new
    /// project folder, Codex's dated rollout dirs — are followed without
    /// restarting it.
    private func startFSWatcher() {
        let watcher = FSWatcher(label: watcherLabel)
        let ok = watcher.start(path: root, latency: Self.fsEventsLatency) { [weak self] event in
            await self?.ingestEventPaths(
                event.urls, rescanAll: event.rescanAll, rootChanged: event.rootChanged)
        }
        if ok {
            fsWatcher = watcher
        }
        // On failure (e.g. unsupported filesystem) we fall back to pure
        // polling — the `pollTask` still runs. No fatal here.
    }

    /// FSEvents callback target. Ingests new bytes from each `.jsonl` URL and
    /// emits a fresh frame if anything changed. `rescanAll` widens scope to
    /// the full directory enumeration (handles UserDropped/KernelDropped/
    /// MustScanSubDirs). `rootChanged` tears down + restarts the watcher
    /// because the watched path was renamed or deleted under us.
    private func ingestEventPaths(
        _ urls: [URL], rescanAll: Bool, rootChanged: Bool
    ) async {
        // A batch can already be in flight when `stop()` releases the watcher:
        // `FSWatcher.dispatch` reads its handler under the lock and then hops
        // off the FSEvents queue, so the hop can land here after the teardown.
        // One carrying `rootChanged` would otherwise build a fresh stream that
        // nothing is left to stop.
        guard lifecycle == .running else { return }
        // FSEvents is the primary wake and the poll only the safety net, so
        // re-reading the out-of-band files on the poll alone left every frame a
        // turn produced carrying fresh tokens beside a plan and a credits
        // figure from up to two polls back: the adapter's own floor is the poll
        // interval, which made it skip alternate polls. Driven from here the
        // floor sets that cadence rather than aliasing against it.
        adapter.willRead()
        if rootChanged {
            fsWatcher?.stop()
            fsWatcher = nil
            startFSWatcher()
        }
        var dirty = false
        if rescanAll {
            let files = enumerateJSONLSortedByMTime()
            watchedCounter.store(files.count)
            for file in files {
                if ingestNewLines(in: file.url) { dirty = true }
            }
        } else {
            // Dedup via Set: a single turn can produce multiple events for the
            // same JSONL within the 1s coalesce window.
            var seen = Set<URL>()
            for url in urls where url.pathExtension == "jsonl" {
                if !seen.insert(url).inserted { continue }
                if ingestNewLines(in: url) { dirty = true }
            }
            // Keep watchedCounter (which decides whether the panel says "no
            // session logs found") in sync with reality. Without this, an
            // FSEvents-only run that starts against an empty tree and then
            // sees the first turn would still report files=0 because the
            // counter only updates on enumerate() calls.
            watchedCounter.store(max(watchedCounter.load(), fileOffsets.count))
        }
        let todayKey = Calendar.current.startOfDay(for: Date())
        if dirty || signalsChanged {
            await emitReading()
        } else if let lastKey = lastEmittedDayKey, lastKey != todayKey {
            await emitReading()
        }
        trim()
        adapter.projects.ledger.saveIfDirty()
        saveSnapshotIfDirty()
        saveHistoryIfDirty()
    }

    /// Whether anything this provider answers for besides its totals has moved
    /// since the last emit — an authorization that lapsed, a plan the CLI
    /// rewrote, an account switched. None of those move a token count, and
    /// before this the panel kept showing the old one until the next turn
    /// landed, which on the day a keychain grant expires may be never.
    ///
    /// False until something has actually been published. A provider that read
    /// nothing has no reading to contradict, and emitting a frame for it would
    /// take the panel off the one sentence a user with no session logs at all
    /// can act on.
    private var signalsChanged: Bool {
        guard let lastPublishedSignals else { return false }
        return currentSignals() != lastPublishedSignals
    }

    /// Publishes today's totals, recording the day and the reading that went
    /// out with them.
    ///
    /// Every emit goes through here so the record cannot drift from what was
    /// sent: `lastPublishedSignals` is what lets the next pass tell a provider
    /// whose plan, account or authorization changed from one that merely read
    /// the same numbers again, and a branch that emitted without updating it
    /// would emit on every poll forever after.
    private func emitReading() async {
        guard let onChange else { return }
        lastEmittedDayKey = Calendar.current.startOfDay(for: Date())
        lastPublishedSignals = currentSignals()
        await onChange(current())
    }

    /// What today adds up to right now.
    ///
    /// Every emit goes through here, which is why this is also where the
    /// project split is republished: recomputing it per emit costs a walk over
    /// today's rows, where doing it per event would cost a lock per line.
    func current() -> DayTotals {
        let todayKey = Calendar.current.startOfDay(for: Date())
        publishedProjects.store(projectTotals(on: todayKey))
        publishedAgents.store(dailyAgentCounts[todayKey] ?? .none)
        return dailyTotals[todayKey] ?? DayTotals(totalTokens: 0, totalCost: 0)
    }

    nonisolated func filesWatched() -> Int { watchedCounter.load() }

    nonisolated func currentProjects() -> [ProjectTotals] { publishedProjects.load() }

    nonisolated func currentAgents() -> AgentCounts { publishedAgents.load() }

    /// One day's rows folded down to a total per project. A row naming no
    /// project is left out rather than grouped under a made-up one: the panel
    /// shows where the money went, and "nowhere nameable" is not an answer a
    /// row should assert.
    private func projectTotals(on day: Date) -> [ProjectTotals] {
        var tokens: [String: Int] = [:]
        var cost: [String: Decimal] = [:]
        for (row, totals) in dailyModelTotals[day] ?? [:] {
            guard let project = row.project else { continue }
            tokens[project, default: 0] += totals.totalTokens
            cost[project, default: 0] += totals.cost
        }
        return tokens.keys.map {
            ProjectTotals(
                path: $0,
                tokens: tokens[$0] ?? 0,
                cost: cost[$0] ?? 0,
                remote: adapter.projects.repositoryRemote(for: $0)
            )
        }
    }

    /// True once the initial backfill scan has finished. Lets callers gate
    /// behavior that depends on `today.totalTokens` reflecting the full
    /// in-window state instead of a partial mid-scan aggregate.
    func isWarm() -> Bool { coldScanComplete }

    private func poll() async {
        guard lifecycle == .running else { return }
        adapter.willRead()
        // Before a byte is read, so a worktree alive right now is answered for
        // whenever its lines are read — which may be after it is deleted.
        adapter.projects.ledger.refreshKnownRepositories()
        // Only reaches directories this process has not resolved yet, for the
        // reason the call in `start()` documents. It costs one listing of a
        // directory that is usually empty, and it is what keeps a session
        // opened an hour ago from waiting for a relaunch.
        adapter.projects.ledger.ingestInbox()
        // Newest files first so the active session's JSONL — the only one
        // that can contain today's usage — is parsed before any historical
        // file. Combined with the throttled emit below this means the
        // menubar gets a usable frame within ~100 ms of launch even on
        // a cold cache, instead of waiting for the entire backfill to
        // complete (~12 s on a 300 MB tree).
        let files = enumerateJSONLSortedByMTime()
        watchedCounter.store(files.count)
        // Compute the calendar day key once per poll. `Calendar.current` walks
        // locale + timezone on each call (tens of µs); the old code paid this
        // 3-4 times per poll across the emit branches.
        let todayKey = Calendar.current.startOfDay(for: Date())
        var dirtySinceEmit = false
        var lastEmitAt = Date.distantPast
        let emitThrottle = UsageReaderShared.pollEmitThrottle
        for (i, file) in files.enumerated() {
            if ingestNewLines(in: file.url) { dirtySinceEmit = true }
            // Cooperative concurrency: without these yields the actor pins
            // one Swift concurrency thread for the entire backfill scan,
            // starving everything else that awaits on it — the readiness
            // poll behind the panel's warming state included. The check
            // immediately after the yield is what lets a teardown interrupt
            // an in-flight cold scan instead of waiting for every file to
            // drain: a cancelled boot task on the way down, or a `stop()`
            // that landed while the yield had the actor released.
            if i % Self.yieldInterval == Self.yieldInterval - 1 {
                await Task.yield()
                if Task.isCancelled || lifecycle == .stopped { return }
            }
            // Stream partial totals out during backfill, so the panel counts
            // up while the scan runs instead of sitting blank until it ends.
            if dirtySinceEmit, Date().timeIntervalSince(lastEmitAt) > emitThrottle {
                await emitReading()
                lastEmitAt = Date()
                dirtySinceEmit = false
            }
        }
        trim()
        if dirtySinceEmit || signalsChanged {
            await emitReading()
        } else if let lastKey = lastEmittedDayKey, lastKey != todayKey {
            // Calendar day rolled since the last emit and nothing wrote a
            // new JSONL line. Force a synthetic emit so the menubar
            // resets to a fresh "today=0" frame instead of holding the
            // stale frame until the next turn. Covers both the trivial case
            // (Mac stays awake across midnight) and the wake-after-sleep
            // case (system slept across one or more midnights, first poll
            // after wake observes the day shift).
            await emitReading()
        }
        // Throttled persistence: only writes if state changed since the
        // last save AND `saveThrottle` seconds have elapsed. SIGKILL/power
        // loss therefore bounds progress loss to one throttle window; a
        // graceful SIGTERM forces a final flush via `stop()`.
        adapter.projects.ledger.saveIfDirty()
        saveSnapshotIfDirty()
        saveHistoryIfDirty()
    }

    /// One candidate session log and the mtime it was ordered by.
    ///
    /// The mtime is carried rather than recomputed because the backfill reads
    /// the ordering as a guarantee: files come newest first, so once a file of
    /// mtime `M` has been consumed no unread file can hold an event later than
    /// `M`, and every day after `M`'s is therefore complete.
    private struct ScannedFile {
        let url: URL
        let mtime: TimeInterval
    }

    /// Every `.jsonl` under the tree, newest first. Any name is accepted —
    /// Codex writes `rollout-*.jsonl` and Claude Code a UUID, and a fork that
    /// renames either still gets read.
    private func enumerateJSONLSortedByMTime() -> [ScannedFile] {
        guard
            let it = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        let cutoff = retainWindowStart
        var candidates: [ScannedFile] = []
        while let u = it.nextObject() as? URL {
            guard u.pathExtension == "jsonl" else { continue }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: u.path),
                let mtimeDate = attrs[.modificationDate] as? Date
            else { continue }
            if mtimeDate < cutoff, fileOffsets[u] == nil {
                // Stale file we've never read; its data is outside the
                // retain window so skip permanently.
                continue
            }
            candidates.append(ScannedFile(url: u, mtime: mtimeDate.timeIntervalSince1970))
        }
        candidates.sort { $0.mtime > $1.mtime }
        return candidates
    }

    private func ingest(_ event: UsageEvent) {
        if coldScanComplete {
            publishedUsage.update {
                $0.lastActivityAt = max($0.lastActivityAt ?? event.timestamp, event.timestamp)
            }
        }
        let key = Calendar.current.startOfDay(for: event.timestamp)
        let totalTokens =
            event.inputTokens
            + event.outputTokens
            + event.cacheReadTokens
            + event.cacheCreationTokens
        let existing = dailyTotals[key] ?? DayTotals(totalTokens: 0, totalCost: 0)
        dailyTotals[key] = DayTotals(
            totalTokens: existing.totalTokens + totalTokens,
            totalCost: existing.totalCost + event.cost
        )
        var byRow = dailyModelTotals[key] ?? [:]
        byRow[UsageHistoryRow(model: event.model, project: event.project), default: .init()]
            .add(event)
        dailyModelTotals[key] = byRow
        guard historyRoot != nil, !historySuppressedDays.contains(key) else { return }
        historyDirtyDays.insert(key)
    }

    /// Buckets one agent observation into the day it happened on.
    ///
    /// Idempotent across a cold scan for the same reason the token totals are:
    /// the count lands in a day bucket that the archive writes *whole*, so a
    /// re-derived day replaces its file rather than adding to it. What stops
    /// it double-counting inside one run is the dedup ledger the adapter
    /// claimed its key in before this was called.
    ///
    /// A day this process must not write is still counted in memory. The
    /// suppression is about the archive — a day the tail cannot vouch for is
    /// left unwritten rather than written short — and the panel's own reading
    /// of today is not an archive write.
    private func ingest(_ activity: AgentActivityEvent) {
        let key = Calendar.current.startOfDay(for: activity.timestamp)
        dailyAgentCounts[key, default: .none].record(activity.kind)
        guard historyRoot != nil, !historySuppressedDays.contains(key) else { return }
        historyDirtyDays.insert(key)
    }

    private func trim() {
        let cal = Calendar.current
        let cutoff = cal.startOfDay(for: retainWindowStart)
        // A day that leaves the retain window is a day nothing will rewrite,
        // so anything of it still only in memory would be lost rather than
        // frozen. Only then — otherwise the throttle would never hold.
        if historyDirtyDays.contains(where: { $0 < cutoff }) {
            saveHistoryIfDirty(force: true)
        }
        dailyTotals = dailyTotals.filter { $0.key >= cutoff }
        dailyModelTotals = dailyModelTotals.filter { $0.key >= cutoff }
        dailyAgentCounts = dailyAgentCounts.filter { $0.key >= cutoff }
        historySuppressedDays = historySuppressedDays.filter { $0 >= cutoff }
        // Evict dedup keys for days that have aged out so the set's memory
        // footprint stays bounded across long-running sessions.
        seenEventKeys = seenEventKeys.filter { $0.value.day >= cutoff }
        let retained = UsageReaderShared.retainedFiles(
            mtimes: fileMTimes, cutoff: cutoff.timeIntervalSince1970)
        fileOffsets = fileOffsets.filter { retained.contains($0.key) }
        fileMTimes = fileMTimes.filter { retained.contains($0.key) }
        adapter.trim(retaining: retained)
    }

    /// Hands one line to the adapter and buckets whatever it makes of it.
    private func consume(_ data: Data, url: URL, byteOffset: UInt64) -> Bool {
        let line = SourceLine(
            data: data,
            url: url,
            byteOffset: byteOffset,
            retainCutoff: retainWindowStart
        )
        var observed: [AgentActivityEvent] = []
        let event = adapter.event(from: line, seen: &seenEventKeys, activity: &observed)
        var counted = false
        for activity in observed {
            if let backfill, activity.timestamp >= backfill.upperBound { continue }
            ingest(activity)
            counted = true
        }
        guard let event else { return counted }
        // Rejected here rather than at the adapter's own cutoff, and
        // deliberately after it has been asked: Codex's per-file bookkeeping —
        // which turn a copy repeats, where its running total stands — is
        // updated for events it does not bill, and an upper bound enforced
        // inside the adapter would skip that for every day the tail owns.
        if let backfill, event.timestamp >= backfill.upperBound { return false }
        ingest(event)
        return true
    }

    private func ingestNewLines(in url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let mtimeDate = attrs[.modificationDate] as? Date,
            let size = (attrs[.size] as? NSNumber)?.uint64Value
        else { return false }
        let mtime = mtimeDate.timeIntervalSince1970

        let prevMTime = fileMTimes[url] ?? 0
        let prevOffset = fileOffsets[url] ?? 0

        if mtime == prevMTime && size == prevOffset { return false }
        if size < prevOffset {
            // Truncated or rotated; restart from 0.
            fileOffsets[url] = 0
        }

        let readFrom = fileOffsets[url] ?? 0
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        do { try fh.seek(toOffset: readFrom) } catch { return false }
        fileMTimes[url] = mtime

        var anyIngested = false
        // Absolute position (relative to file start) just past the most
        // recent terminating newline. The persisted offset advances to this
        // value so a mid-line write is left for the next poll instead of
        // half-parsed.
        var lastNewlineAbs: UInt64 = readFrom
        // Chunk-relative cursor: absolute position of byte 0 of the current
        // chunk in the file.
        var chunkBaseAbs: UInt64 = readFrom
        var totalRead: UInt64 = 0
        // Buffer for a line that straddles a chunk boundary, and where it
        // started in the file — a dedup key built from the offset has to name
        // the line's own start, not the chunk it finished in. Parses without
        // the byte-level prefilter: at most one carry per chunk, and the
        // adapter rejects a line it cannot use cheaply.
        var carry = Data()
        var carryStartAbs: UInt64 = readFrom

        while true {
            let chunk: Data
            do {
                chunk = try fh.read(upToCount: UsageReaderShared.ingestChunkSize) ?? Data()
            } catch {
                break
            }
            if chunk.isEmpty { break }
            totalRead += UInt64(chunk.count)

            chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }
                let n = raw.count
                var lineStart = 0
                var i = 0
                while i < n {
                    if base[i] == 0x0A {
                        let absLineStart =
                            carry.isEmpty ? chunkBaseAbs + UInt64(lineStart) : carryStartAbs
                        if !carry.isEmpty {
                            // Stitch the trailing bytes of the previous chunk
                            // onto the head of this line.
                            if i > lineStart {
                                carry.append(chunk.subdata(in: lineStart..<i))
                            }
                            if consume(carry, url: url, byteOffset: absLineStart) {
                                anyIngested = true
                            }
                            carry.removeAll(keepingCapacity: true)
                        } else if i > lineStart,
                            adapter.lineMayCount(base, from: lineStart, to: i)
                        {
                            let lineData = chunk.subdata(in: lineStart..<i)
                            if consume(lineData, url: url, byteOffset: absLineStart) {
                                anyIngested = true
                            }
                        }
                        lineStart = i + 1
                        lastNewlineAbs = chunkBaseAbs + UInt64(lineStart)
                    }
                    i += 1
                }
                // Anything past the last newline carries to the next chunk.
                if lineStart < n {
                    if carry.isEmpty { carryStartAbs = chunkBaseAbs + UInt64(lineStart) }
                    carry.append(chunk.subdata(in: lineStart..<n))
                }
            }
            chunkBaseAbs += UInt64(chunk.count)
        }

        if totalRead == 0 {
            // Even an empty read here may have advanced past an mtime-only
            // touch (atime / metadata change). Don't mark persistDirty since
            // nothing offset-relevant changed.
            return false
        }

        fileOffsets[url] = lastNewlineAbs
        persistDirty = true
        return anyIngested
    }

    /// Reads the persisted snapshot and applies it if every per-file mtime
    /// still matches the disk, and the adapter accepts its own slice of it.
    /// Any mismatch (rotation, truncation, deleted file) discards the snapshot
    /// entirely and falls back to a cold rescan — cheap enough (<1 s on a
    /// 350 MB tree) that partial reconciliation isn't worth the complexity.
    private func loadAndApplyPersistedState() -> Bool {
        guard let url = persistenceURL else { return false }
        let outcome = UsageStatePersistence.load(from: url)
        guard case .ok(let snapshot) = outcome else { return false }

        // Before the first guard below, and deliberately: which directory was
        // a checkout of which repository is true whatever the offsets beside
        // it turn out to be worth, and a snapshot refused here is followed by
        // the cold scan that needs it most.
        adapter.projects.ledger.adopt(snapshot.projectCheckouts ?? [])

        let expectedHash = UsageStatePersistence.hashDataDir(root)
        guard snapshot.claudeDataDirHash == expectedHash else { return false }
        guard snapshot.retainDays == retainDays else { return false }

        let fm = FileManager.default
        let cutoffDate = retainWindowStart
        var newOffsets: [URL: UInt64] = [:]
        var newMTimes: [URL: TimeInterval] = [:]
        var stale = false
        for entry in snapshot.files {
            let fileURL = URL(fileURLWithPath: entry.path)
            guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                let mtimeDate = attrs[.modificationDate] as? Date,
                let size = (attrs[.size] as? NSNumber)?.uint64Value
            else {
                // File referenced by snapshot no longer exists. Its events
                // are baked into dailyTotals so we can't reuse the totals
                // without also keeping its row — bail.
                stale = true
                break
            }
            if mtimeDate < cutoffDate {
                // File aged out of the retain window — drop without staling.
                continue
            }
            let diskMTime = mtimeDate.timeIntervalSince1970
            if diskMTime + UsageReaderShared.mtimeTolerance < entry.mtimeUnix || size < entry.offset {
                // Rotated or truncated since save.
                stale = true
                break
            }
            newOffsets[fileURL] = entry.offset
            newMTimes[fileURL] = entry.mtimeUnix
        }
        if stale { return false }

        let cal = Calendar.current
        let dayFmt = UsageReaderShared.dayFormatter
        let cutoffDay = cal.startOfDay(for: cutoffDate)
        var newDaily: [Date: DayTotals] = [:]
        for t in snapshot.dailyTotals {
            guard let dayDate = dayFmt.date(from: t.day) else { continue }
            let dayKey = cal.startOfDay(for: dayDate)
            if dayKey < cutoffDay { continue }
            let cost = Decimal(string: t.cost) ?? 0
            newDaily[dayKey] = DayTotals(totalTokens: t.tokens, totalCost: cost)
        }
        var newKeys: [String: SeenEvent] = [:]
        for k in snapshot.dedupKeysToday {
            guard let dayDate = dayFmt.date(from: k.day) else { continue }
            let dayKey = cal.startOfDay(for: dayDate)
            if dayKey < cutoffDay { continue }
            newKeys[k.key] = SeenEvent(day: dayKey, billedOutputTokens: k.outputTokens)
        }
        // Last, and before anything is committed: an adapter that cannot
        // resume from this snapshot costs a cold scan, not a wrong resume with
        // the offsets already at EOF.
        guard adapter.resume(from: snapshot, offsets: newOffsets) else { return false }
        fileOffsets = newOffsets
        fileMTimes = newMTimes
        dailyTotals = newDaily
        seenEventKeys = newKeys
        restoreModelTotals(from: snapshot)
        return true
    }

    /// Seeds the day-by-model totals from the snapshot that has just restored
    /// the day totals beside them, and marks every day it seeded dirty so the
    /// first flush writes the archive back to the moment the offsets describe.
    ///
    /// The snapshot is the only thing that may seed them. It is written from
    /// the same in-memory state as the archive and read back with the offsets
    /// that produced it, so a day resumed from here continues at exactly the
    /// byte the last run stopped at — where the day file on disk can be a
    /// throttle window behind or ahead of that byte, depending on which of the
    /// two writes was interrupted. Reconciling it is what the dirty mark is
    /// for: the day is rewritten whole from a seed that matches the offsets,
    /// which is why neither write order nor a failed write can leave the two
    /// disagreeing.
    ///
    /// A day the snapshot has totals for but no rows for is a day this process
    /// cannot vouch for: the events behind those totals are already consumed,
    /// so a file written from here would hold what came after the upgrade and
    /// call it the day.
    ///
    /// The rows are restored whether or not the archive is on. They are what
    /// the panel splits today by, and a disk-retention setting must not
    /// quietly take a live answer away with it.
    private func restoreModelTotals(from snapshot: UsageStateSnapshot) {
        let cal = Calendar.current
        let dayFmt = UsageReaderShared.dayFormatter
        // Deliberately not gated on the day having token totals, which the
        // rows below are: a day can be counted without being billed, and such
        // a day has no entry there at all. `trim()` is what bounds these, the
        // same as it bounds the totals themselves.
        for row in snapshot.historyResume?.dailyAgentCounts ?? [] {
            guard let dayDate = dayFmt.date(from: row.day) else { continue }
            dailyAgentCounts[cal.startOfDay(for: dayDate)] = AgentCounts(
                sessions: row.sessions, agents: row.agents)
        }
        var restored: [Date: [UsageHistoryRow: UsageHistoryTotals]] = [:]
        for row in snapshot.historyResume?.dailyModelTotals ?? [] {
            guard let dayDate = dayFmt.date(from: row.day) else { continue }
            let dayKey = cal.startOfDay(for: dayDate)
            guard dailyTotals[dayKey] != nil else { continue }
            let key = UsageHistoryRow(
                model: row.model,
                project: row.project.flatMap { adapter.projects.project(for: $0) }
            )
            restored[dayKey, default: [:]][key, default: .init()].add(
                UsageHistoryTotals(
                    inputTokens: row.inputTokens,
                    outputTokens: row.outputTokens,
                    cacheReadTokens: row.cacheReadTokens,
                    cacheCreationTokens: row.cacheCreationTokens,
                    cost: Decimal(string: row.cost) ?? 0
                ))
        }
        for day in dailyTotals.keys {
            guard let totals = restored[day] else {
                guard historyRoot != nil else { continue }
                historySuppressedDays.insert(day)
                dropArchivedDayIfShort(day)
                continue
            }
            dailyModelTotals[day] = totals
            if historyRoot != nil { historyDirtyDays.insert(day) }
        }
    }

    /// Removes the file for a suppressed day that an earlier run had already
    /// written short — the archive was switched off, or the build that wrote
    /// it kept no split, and the day went on being metered afterwards.
    ///
    /// The snapshot's own total for the day is the proof: a file below it is
    /// wrong, and it cannot be corrected from here, because the rows it would
    /// need are exactly what this day has none of. A week that says the day is
    /// missing is readable; one that quietly counts a fraction of it is not.
    private func dropArchivedDayIfShort(_ day: Date) {
        guard let historyRoot, let metered = dailyTotals[day] else { return }
        let dayKey = UsageReaderShared.dayFormatter.string(from: day)
        guard let stored = UsageHistoryStore.load(provider: id, day: dayKey, in: historyRoot),
            stored.totalTokens < metered.totalTokens
        else { return }
        do {
            try FileManager.default.removeItem(
                at: UsageHistoryStore.url(provider: id, day: dayKey, in: historyRoot))
            sissyLog("sissy: \(id) dropped a short archive day — \(dayKey)")
        } catch {
            sissyLog("sissy: \(id) could not drop the short archive day \(dayKey): \(error)")
        }
    }

    /// Keeps the archive off the one day a cold scan cannot see whole.
    ///
    /// The retain window is a rolling 48 hours, not two calendar days, so the
    /// oldest day a scan reaches starts mid-afternoon: every event before the
    /// cutoff is refused at parse time. Archiving that day would freeze a
    /// fraction of it as the day — and where a previous run had already
    /// written it complete, a scan forced by a lost snapshot would replace a
    /// whole day with a part of one. Every later day is whole, because a day
    /// is inside the window for the whole of itself and the whole of the next.
    private func suppressTheDayAColdScanCuts() {
        guard historyRoot != nil else { return }
        let cal = Calendar.current
        historySuppressedDays.insert(
            cal.startOfDay(for: retainWindowStart))
    }

    /// Forgets every archived day before today, on the one ask there is for
    /// it. The files are gone by the time this lands; what it clears is the
    /// memory that would put them back — a straggler event stamped yesterday,
    /// arriving minutes after midnight, would otherwise rewrite a day the user
    /// asked Sissy to forget.
    ///
    /// Today survives, and its file went with the rest, so it is left dirty:
    /// the dialog promises today keeps counting, and a day still being counted
    /// has to be back on disk at the next flush rather than at the next
    /// relaunch.
    func forgetArchivedDays() async {
        let today = Calendar.current.startOfDay(for: Date())
        for day in dailyModelTotals.keys where day < today {
            historySuppressedDays.insert(day)
        }
        dailyModelTotals = dailyModelTotals.filter { $0.key >= today }
        historyDirtyDays = Set(dailyModelTotals.keys)
    }

    /// Throttled whole-day writes, on the same schedule and for the same
    /// reasons as the snapshot's. Each dirty day is written complete, so a
    /// rewrite replaces rather than accumulates.
    ///
    /// A day file may be left behind or ahead of the snapshot beside it — the
    /// two are written under their own throttles and either can fail on its
    /// own — and neither costs anything, because the archive is a projection
    /// of what the snapshot carries rather than a second record: a resume
    /// seeds the day from the snapshot and rewrites the file whole from there.
    ///
    /// A day is only ever replaced by a reading at least as complete as the
    /// one it holds, model by model. What a cold scan derives is bounded by
    /// the tree as it is now, and the commonest reason a snapshot goes stale
    /// is a session log that is no longer there — so a re-derivation can be
    /// short where the run that archived the day was not, and that day is
    /// past, which means nothing will ever grow it back. The comparison is
    /// per model because a scan that lost one model's log while another model
    /// went on spending adds up to more than the file and still knows less
    /// than it. A file this build cannot read is left alone for the same
    /// reason, one step further along: there is no reading here that knows
    /// what it holds.
    ///
    /// A day whose write fails is kept dirty and retried on the next flush;
    /// the others are still attempted, because one unwritable day must not
    /// cost the day that is about to leave the retain window.
    @discardableResult
    private func saveHistoryIfDirty(force: Bool = false, finalizedAfter: Date? = nil) -> Int {
        guard let historyRoot, !historyDirtyDays.isEmpty else { return 0 }
        let now = Date()
        if !force, finalizedAfter == nil,
            now.timeIntervalSince(lastHistorySaveAt) < Self.saveThrottle
        {
            return 0
        }
        let dayFmt = UsageReaderShared.dayFormatter
        var unwritten: Set<Date> = []
        var written = 0
        for day in historyDirtyDays {
            if let finalizedAfter, day <= finalizedAfter {
                unwritten.insert(day)
                continue
            }
            let totals = dailyModelTotals[day] ?? [:]
            let counts = dailyAgentCounts[day] ?? .none
            // A day can be counted without being billed: Codex writes a
            // rollout's `session_meta` when it opens, so a session somebody
            // started and never asked anything is one session and no tokens.
            // Skipped on the token rows alone, such a day left the dirty set
            // here and was never retried, so its count aged out unwritten.
            guard !totals.isEmpty || !counts.isEmpty else { continue }
            if refusesUnpricedDays, Self.holdsAnUnpricedModel(totals) {
                sissyLog(
                    "sissy: \(id) left \(dayFmt.string(from: day)) out of the archive — it holds "
                        + "a model no pricing source carries, and a day written short is frozen "
                        + "short")
                continue
            }
            var record = UsageHistoryDay(
                day: dayFmt.string(from: day),
                provider: id,
                updatedAt: now,
                totals: totals,
                agents: counts
            )
            switch UsageHistoryStore.stored(provider: id, day: record.day, in: historyRoot) {
            case .unreadable:
                continue
            case .day(let onDisk)
            where !onDisk.reattributed(by: { adapter.projects.project(for: $0) })
                .isCoveredBy(record):
                continue
            case .day(let onDisk):
                record = record.merging(counts: onDisk.agents)
            case .absent:
                break
            }
            do {
                try UsageHistoryStore.save(record, in: historyRoot)
                written += 1
            } catch {
                // Same call as the snapshot's: the day stays dirty and the
                // next flush retries it. Logged because an archive that
                // silently stops growing is indistinguishable from a quiet
                // week.
                sissyLog(
                    "sissy: \(id) history save failed for \(record.day) at "
                        + "\(historyRoot.path): \(error)")
                unwritten.insert(day)
            }
        }
        historyDirtyDays = unwritten
        lastHistorySaveAt = now
        return written
    }

    /// Whether a day may be refused for holding a model no rate covers.
    ///
    /// Only a backfill pass may. The tail meters a day that is still running:
    /// a refusal there would keep today out of the archive for the whole of
    /// it, because `applyPriceCatalog` prices events from the refresh onwards
    /// and never reprices what is already counted. A backfilled day is past
    /// and nothing will grow it back, so writing it short freezes it short —
    /// which is the worse of the two, and the one this guards.
    private var refusesUnpricedDays: Bool { backfill != nil }

    /// Whether any row here is a model no pricing source carried.
    ///
    /// Read off the rows rather than carried on the event, because it is
    /// already there: `Pricing.cost` answers zero only when no rate resolved,
    /// and Claude Code's one legitimately free shape — the `<synthetic>` turn
    /// it writes for its own local notices — carries no tokens either, so
    /// tokens without cost names an unpriced model and nothing else.
    private static func holdsAnUnpricedModel(
        _ totals: [UsageHistoryRow: UsageHistoryTotals]
    ) -> Bool {
        totals.contains { $0.value.totalTokens > 0 && $0.value.cost == 0 }
    }

    /// Throttled atomic save. `force=true` bypasses throttle (used by stop).
    /// Caller must already hold the actor.
    private func saveSnapshotIfDirty(force: Bool = false) {
        guard let url = persistenceURL else { return }
        if !force && !persistDirty { return }
        let now = Date()
        if !force && now.timeIntervalSince(lastSaveAt) < Self.saveThrottle { return }
        // Don't write a useless empty snapshot. If SIGTERM hits before the
        // first poll has ingested anything, in-memory state is empty —
        // persisting it would make the next boot load an empty snapshot and
        // briefly show the "sleep" pose with 0 tokens before the cold
        // rescan rebuilds totals. Leaving the file absent forces a clean
        // cold path instead.
        if fileOffsets.isEmpty && dailyTotals.isEmpty { return }

        let cal = Calendar.current
        let dayFmt = UsageReaderShared.dayFormatter

        let files: [UsageStateSnapshot.FileEntry] = fileOffsets.map { (k, v) in
            UsageStateSnapshot.FileEntry(
                path: k.path,
                offset: v,
                mtimeUnix: fileMTimes[k] ?? 0
            )
        }
        let daily: [UsageStateSnapshot.DailyTotal] = dailyTotals.map { (k, v) in
            UsageStateSnapshot.DailyTotal(
                day: dayFmt.string(from: k),
                tokens: v.totalTokens,
                cost: NSDecimalNumber(decimal: v.totalCost).stringValue
            )
        }
        var modelTotals: [UsageStateSnapshot.DailyModelTotal] = []
        for (day, byRow) in dailyModelTotals {
            let dayString = dayFmt.string(from: day)
            for (row, totals) in byRow {
                modelTotals.append(
                    UsageStateSnapshot.DailyModelTotal(
                        day: dayString,
                        model: row.model,
                        project: row.project,
                        inputTokens: totals.inputTokens,
                        outputTokens: totals.outputTokens,
                        cacheReadTokens: totals.cacheReadTokens,
                        cacheCreationTokens: totals.cacheCreationTokens,
                        cost: NSDecimalNumber(decimal: totals.cost).stringValue
                    ))
            }
        }
        let agentCounts: [UsageStateSnapshot.DailyAgentCount] = dailyAgentCounts.compactMap {
            day, counts in
            guard !counts.isEmpty else { return nil }
            return UsageStateSnapshot.DailyAgentCount(
                day: dayFmt.string(from: day),
                sessions: counts.sessions,
                agents: counts.agents)
        }
        let retainedCutoff = cal.startOfDay(for: retainWindowStart)
        let retainedKeys: [UsageStateSnapshot.DedupKey] = seenEventKeys.compactMap { key, entry in
            guard entry.day >= retainedCutoff else { return nil }
            return UsageStateSnapshot.DedupKey(
                key: key,
                day: dayFmt.string(from: entry.day),
                outputTokens: entry.billedOutputTokens
            )
        }

        let snapshot = UsageStateSnapshot(
            schemaVersion: UsageStateSnapshot.currentSchemaVersion,
            savedAt: now,
            claudeDataDirHash: UsageStatePersistence.hashDataDir(root),
            retainDays: retainDays,
            files: files,
            dailyTotals: daily,
            dedupKeysToday: retainedKeys,
            historyResume: modelTotals.isEmpty && agentCounts.isEmpty
                ? nil
                : UsageStateSnapshot.HistoryResume(
                    dailyModelTotals: modelTotals,
                    dailyAgentCounts: agentCounts.isEmpty ? nil : agentCounts),
            codexResume: adapter.resumeState(),
            projectCheckouts: nil
        )
        do {
            try UsageStatePersistence.save(snapshot, to: url)
            lastSaveAt = now
            persistDirty = false
        } catch {
            // Retried on the next dirty save rather than propagated: a
            // snapshot is an optimisation, and losing one costs a cold scan,
            // not a reading. Logged because the failure is otherwise
            // invisible and every later launch pays for it.
            sissyLog("sissy: \(id) snapshot save failed at \(url.path): \(error)")
        }
    }
}
