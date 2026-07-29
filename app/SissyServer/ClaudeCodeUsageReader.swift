import Foundation

#if canImport(Darwin)
import Darwin
#endif

struct UsageEvent: Sendable, Equatable {
    let timestamp: Date
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    let cost: Decimal
}

/// Lock-protected counter shared between the reader actor and the
/// HTTP `/health` + `/stats` handlers. Without this, both handlers had to
/// `await reader.filesWatched()`, which queued behind the long initial
/// backfill scan and made `/health` time out (`URLRequest.timeoutInterval`
/// = 2 s) for the first 1–3 s after daemon start. The menubar's health
/// status then flipped `.up`/`.down` on every probe until the backfill
/// finished, producing a visible icon flicker.
final class AtomicIntCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int = 0
    func load() -> Int { lock.withLock { value } }
    func store(_ v: Int) { lock.withLock { value = v } }
}

actor ClaudeCodeUsageReader: UsageProvider {
    /// Stable provider id surfaced via `/stats`. The persistence URL is
    /// injected; this reader still writes the legacy `usage-state.json` path
    /// for upgrade smoothness, not `usage-state-claude-code.json`.
    nonisolated let id: String = "claude-code"

    private let claudeDir: URL
    private let retainDays: Int
    private let pollInterval: Duration
    /// When non-nil, the reader snapshots its state to this URL on a
    /// throttle and on stop. On the first `poll` it tries to load + reconcile
    /// the snapshot so a daemon restart skips the cold backfill. Nil disables
    /// persistence entirely — used by `--scan` and tests that want a fresh
    /// reader without touching the user's saved state.
    private let persistenceURL: URL?
    /// Per-model price overrides from `ServerConfig.pricingOverride`. When a
    /// model matches an override entry (exact or longest-prefix) the override
    /// outranks both the runtime catalog and the embedded seed.
    private let pricingOverride: [String: ModelPricing]?
    /// Anthropic slice of the runtime `PriceCatalog`. Sits between the user's
    /// override and the embedded generated seed, so a model that launched after
    /// this daemon was built still prices correctly. Refreshed in place by
    /// `applyPriceCatalog`; a refresh applies to events ingested from then on
    /// and does not reprice accumulated totals.
    private var priceCatalog: PricingTable?
    /// Models already reported as unpriced. Keeps the warning to one line per
    /// model per daemon run instead of one per ingested event.
    private var loggedUnpricedModels: Set<String> = []
    private var fileOffsets: [URL: UInt64] = [:]
    private var fileMTimes: [URL: TimeInterval] = [:]
    private var dailyTotals: [Date: DayTotals] = [:]
    /// Dedup keys tagged with the event day. The day tag lets `trim()` evict
    /// keys older than the retain window (previously the set grew unbounded
    /// across long-running daemon sessions) and lets the persistence layer
    /// store only today's keys without losing the streaming-across-restart
    /// safety net.
    private var seenRequestKeys: [String: Date] = [:]
    private var pollTask: Task<Void, Never>?
    private var onChange: (@Sendable (DayTotals, DayTotals?) async -> Void)?
    nonisolated private let watchedCounter = AtomicIntCounter()
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
    /// the daemon has produced a real frame.
    private var lastEmittedDayKey: Date?
    /// False until the initial backfill scan has finished parsing every
    /// in-window JSONL. While false, `current()` suppresses `prev` (passes
    /// nil) so consumers can't make ratio decisions on a partially populated
    /// "yesterday" total. Without this guard `FrameBuilder.pickState` would
    /// transiently emit `"trend"` mid-scan: yesterday's daily total is
    /// rebuilt incrementally as the reader walks the JSONL file containing
    /// it, so for a few hundred ms `today` looks like a >=1.3× spike vs a
    /// not-yet-finalised `prev`. The flag flips once after `start()` runs
    /// its blocking cold pass; FSEvents-driven incremental ingest from
    /// then on operates on a fully consistent `prev`.
    private var coldScanComplete = false
    /// Max wall-clock between throttled saves. SIGKILL/power loss bounds
    /// progress loss to this window; SIGTERM still flushes cleanly via
    /// `stop()`. Five seconds keeps SSD churn low on long-running daemons.
    private static let saveThrottle: TimeInterval = 5

    /// FSEvents coalescing window. Higher = more batching (lower CPU, more
    /// notifications coalesced into one wake); lower = snappier UI updates.
    /// 1.0 s matches the previous polling cadence — users experienced no
    /// latency change in the migration, and burst-write turns get one wake
    /// instead of many.
    private static let fsEventsLatency: CFTimeInterval = 1.0

    // `ISO8601DateFormatter.date(from:)` is documented thread-safe on Apple
    // platforms (only `formatOptions` mutation is not). We only ever read
    // these instances; `nonisolated(unsafe)` is the right escape hatch under
    // Swift 6 strict concurrency.
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoFormatterNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Bytes for `"type"` and `"assistant"`. Used as a cheap prefilter on raw
    /// line bytes before paying the JSON-parse cost: a line passes only if it
    /// contains `"type"` followed (with optional JSON whitespace and a `:`) by
    /// `"assistant"`. Tolerating whitespace matters — `json.dumps` defaults
    /// emit `"type": "assistant"`, and pretty-printed rollouts otherwise slip
    /// past a strict-compact prefilter.
    private static let typeKeyBytes: [UInt8] = Array("\"type\"".utf8)
    private static let assistantValueBytes: [UInt8] = Array("\"assistant\"".utf8)

    static func bufferContainsAssistantMarker(
        _ buf: UnsafePointer<UInt8>,
        from: Int,
        to: Int
    ) -> Bool {
        let key = typeKeyBytes
        let val = assistantValueBytes
        var i = from
        let keyLimit = to - key.count
        while i <= keyLimit {
            if !matches(buf, at: i, pattern: key) {
                i += 1
                continue
            }
            var j = i + key.count
            while j < to, isJSONWhitespace(buf[j]) { j += 1 }
            guard j < to, buf[j] == 0x3A else {  // ':'
                i += 1
                continue
            }
            j += 1
            while j < to, isJSONWhitespace(buf[j]) { j += 1 }
            if j + val.count <= to, matches(buf, at: j, pattern: val) {
                return true
            }
            i += 1
        }
        return false
    }

    private static func matches(
        _ buf: UnsafePointer<UInt8>, at start: Int, pattern: [UInt8]
    ) -> Bool {
        for k in 0..<pattern.count where buf[start + k] != pattern[k] { return false }
        return true
    }

    private static func isJSONWhitespace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
    }

    /// Manual parser for the `YYYY-MM-DDTHH:MM:SS[.fff]Z` shape Claude Code
    /// writes to JSONL. Foundation's `ISO8601DateFormatter` allocates on
    /// every call and walks Calendar+locale, costing tens of µs per parse.
    /// Across the cold-start workload (~44k assistant lines) that alone is
    /// over a second of pure formatter overhead. This path is digit-math +
    /// `timegm`, sub-µs/line. Returns nil for any unexpected shape so the
    /// caller can fall back to the Foundation formatter, keeping forward
    /// compatibility if the upstream timestamp format ever shifts.
    static func parseISODate(_ s: String) -> Date? {
        let bytes = Array(s.utf8)
        if bytes.count < 20 { return nil }
        // Fixed-offset digit check on the date+time skeleton. Bails on the
        // first wrong separator so a slightly different shape ("+00:00"
        // timezones, etc.) falls through to the formatter path.
        guard bytes[4] == 0x2D, bytes[7] == 0x2D, bytes[10] == 0x54,
            bytes[13] == 0x3A, bytes[16] == 0x3A
        else { return nil }
        func d(_ i: Int) -> Int { Int(bytes[i] &- 0x30) }
        for idx in [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18] {
            let v = bytes[idx]
            if v < 0x30 || v > 0x39 { return nil }
        }
        let year = d(0) * 1000 + d(1) * 100 + d(2) * 10 + d(3)
        let month = d(5) * 10 + d(6)
        let day = d(8) * 10 + d(9)
        let hour = d(11) * 10 + d(12)
        let minute = d(14) * 10 + d(15)
        let second = d(17) * 10 + d(18)
        var i = 19
        var frac: Double = 0
        if i < bytes.count && bytes[i] == 0x2E {  // '.'
            i += 1
            var num = 0
            var div = 1
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
                num = num * 10 + Int(bytes[i] &- 0x30)
                div *= 10
                i += 1
            }
            if div > 1 { frac = Double(num) / Double(div) }
        }
        guard i < bytes.count, bytes[i] == 0x5A else { return nil }  // 'Z'
        var tmStruct = tm()
        tmStruct.tm_year = Int32(year - 1900)
        tmStruct.tm_mon = Int32(month - 1)
        tmStruct.tm_mday = Int32(day)
        tmStruct.tm_hour = Int32(hour)
        tmStruct.tm_min = Int32(minute)
        tmStruct.tm_sec = Int32(second)
        let epoch = timegm(&tmStruct)
        if epoch == -1 { return nil }
        return Date(timeIntervalSince1970: TimeInterval(epoch) + frac)
    }

    init(
        claudeDir: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects"),
        retainDays: Int = 2,
        pollInterval: Duration = .seconds(60),
        persistenceURL: URL? = nil,
        pricingOverride: [String: ModelPricing]? = nil
    ) {
        self.claudeDir = claudeDir
        self.retainDays = retainDays
        self.pollInterval = pollInterval
        self.persistenceURL = persistenceURL
        self.pricingOverride = pricingOverride
    }

    func applyPriceCatalog(_ catalog: PriceCatalog) {
        priceCatalog = catalog.table(for: .anthropic)
        // Re-arm the log: a model the previous catalog lacked may now resolve,
        // and the operator wants to see that it healed.
        loggedUnpricedModels.removeAll()
    }

    /// Claude Code writes `<synthetic>` as the model for assistant turns it
    /// produced locally (interrupts, error notices). Every such event carries
    /// all-zero usage, so it is legitimately unpriced — warning about it would
    /// fire on every run and train the operator to ignore the real warnings.
    private static let nonBillableModels: Set<String> = ["<synthetic>"]

    /// Reports an unpriced model once per model: its tokens contribute $0 to the
    /// day's cost, which is otherwise indistinguishable from a quiet day.
    private func logUnpricedModelOnce(for model: String) {
        guard !Self.nonBillableModels.contains(model) else { return }
        guard !loggedUnpricedModels.contains(model) else { return }
        guard Pricing.price(for: model, override: pricingOverride, catalog: priceCatalog) == nil
        else { return }
        loggedUnpricedModels.insert(model)
        daemonLog(
            "sissy-serverd: no rate for '\(model)' in any pricing source — its tokens "
                + "bill at $0; add a `pricingOverride` entry in server.json")
    }

    func start(onChange: @escaping @Sendable (DayTotals, DayTotals?) async -> Void) async {
        self.onChange = onChange
        let loaded = loadAndApplyPersistedState()
        // If we restored a snapshot, fire the callback immediately so Hub
        // builds a cached frame for fresh WS clients. Without this emit the
        // first broadcast waits for the next JSONL append — minutes idle
        // between Claude turns — and the menubar stays at the "Looking for
        // Sissy…" placeholder despite valid totals being in memory.
        if loaded {
            let (today, prev) = current()
            lastEmittedDayKey = Calendar.current.startOfDay(for: Date())
            await onChange(today, prev)
        }
        await poll()
        // Cold backfill done: from here on `prev` is consistent with the
        // full in-window JSONL state, safe to expose to `pickState`. Order
        // matters — set this before any further emit so the first
        // post-backfill frame is the one that introduces `prev` to the UI.
        coldScanComplete = true
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

    func stop() async {
        // Force a final flush so a clean SIGTERM never loses unsaved offset
        // progress. Best-effort: save errors are swallowed (consistent with
        // the per-save site) — nothing actionable on the shutdown path.
        saveSnapshotIfDirty(force: true)
        fsWatcher?.stop()
        fsWatcher = nil
        pollTask?.cancel()
        pollTask = nil
        // Release the broadcast callback so the aggregator that captured
        // `self` via the closure can be reclaimed. Without this clear the
        // strong-self capture in `UsageAggregator.start` would keep the
        // aggregator (and therefore every provider) alive for the rest of
        // the process — irrelevant for the daemon's normal lifetime, but
        // it shows up as a leak in test harnesses that boot+stop many
        // readers within one process.
        onChange = nil
    }

    /// Boots an FSEvents watcher rooted at `claudeDir`. FSEvents wakes are
    /// the primary trigger for JSONL ingest; the surviving `pollTask` runs
    /// at the configured cadence (default 60s) as a safety net for missed
    /// events and midnight rollover with no JSONL activity.
    private func startFSWatcher() {
        let watcher = FSWatcher(label: "sissy.usage.fswatch")
        let ok = watcher.start(path: claudeDir, latency: Self.fsEventsLatency) { [weak self] event in
            await self?.ingestEventPaths(
                event.urls, rescanAll: event.rescanAll, rootChanged: event.rootChanged)
        }
        if ok {
            fsWatcher = watcher
        }
        // On failure (e.g. unsupported filesystem) we fall back to pure
        // polling — the `pollTask` below still runs. No fatal here.
    }

    /// FSEvents callback target. Ingests new bytes from each `.jsonl` URL and
    /// emits a fresh frame if anything changed. `rescanAll` widens scope to
    /// the full directory enumeration (handles UserDropped/KernelDropped/
    /// MustScanSubDirs). `rootChanged` tears down + restarts the watcher
    /// because the watched path was renamed or deleted under us.
    private func ingestEventPaths(
        _ urls: [URL], rescanAll: Bool, rootChanged: Bool
    ) async {
        if rootChanged {
            fsWatcher?.stop()
            fsWatcher = nil
            startFSWatcher()
        }
        var dirty = false
        if rescanAll {
            let files = enumerateJSONLSortedByMTime()
            watchedCounter.store(files.count)
            for url in files {
                if ingestNewLines(in: url) { dirty = true }
            }
        } else {
            // Dedup via Set: a single Claude turn can produce multiple events
            // for the same JSONL within the 1s coalesce window.
            var seen = Set<URL>()
            for url in urls where url.pathExtension == "jsonl" {
                if !seen.insert(url).inserted { continue }
                if ingestNewLines(in: url) { dirty = true }
            }
            // Keep watchedCounter (drives /health usageReader status + menubar
            // "No JSONL detected" pill) in sync with reality. Without this,
            // an FSEvents-only daemon that boots into an empty tree and then
            // sees the first Claude turn would still report files=0 because
            // the counter only updates on enumerate() calls.
            watchedCounter.store(max(watchedCounter.load(), fileOffsets.count))
        }
        let todayKey = Calendar.current.startOfDay(for: Date())
        if dirty, let cb = onChange {
            let (today, prev) = current()
            lastEmittedDayKey = todayKey
            await cb(today, prev)
        } else if let cb = onChange,
            let lastKey = lastEmittedDayKey,
            lastKey != todayKey
        {
            let (today, prev) = current()
            lastEmittedDayKey = todayKey
            await cb(today, prev)
        }
        trim()
        saveSnapshotIfDirty()
    }

    func current() -> (today: DayTotals, prev: DayTotals?) {
        let cal = Calendar.current
        let todayKey = cal.startOfDay(for: Date())
        let prevKey = cal.date(byAdding: .day, value: -1, to: todayKey)!
        // Suppress `prev` until the cold backfill scan finishes — see
        // `coldScanComplete` for the rationale (avoid spurious `trend`
        // mid-scan when yesterday's total is half-rebuilt).
        let prev = coldScanComplete ? dailyTotals[prevKey] : nil
        return (
            dailyTotals[todayKey] ?? DayTotals(totalTokens: 0, totalCost: 0),
            prev
        )
    }

    nonisolated func filesWatched() -> Int { watchedCounter.load() }

    /// True once the initial backfill scan has finished. Lets callers gate
    /// behavior that depends on `today.totalTokens` reflecting the full
    /// in-window state instead of a partial mid-scan aggregate — most
    /// importantly milestone firing, which would otherwise re-announce
    /// crossings as cold-scan emits walk past them.
    func isWarm() -> Bool { coldScanComplete }

    private func poll() async {
        // Newest files first so the active project's JSONL — the only one
        // that can contain today's usage — is parsed before any historical
        // file. Combined with the throttled broadcast below this means the
        // menubar gets a usable frame within ~100 ms of daemon start even on
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
        for (i, url) in files.enumerated() {
            if ingestNewLines(in: url) { dirtySinceEmit = true }
            // Cooperative concurrency: without these yields the actor pins
            // one Swift concurrency thread for the entire backfill scan,
            // starving the NIO HTTP/WS handler Tasks that await on this
            // actor. Cancellation check immediately after the yield is what
            // lets `stop()` interrupt an in-flight cold scan instead of
            // waiting for every file to drain.
            if i % 4 == 3 {
                await Task.yield()
                if Task.isCancelled { return }
            }
            // Stream partial totals out during backfill. Hub.broadcast caches
            // each payload, so a late-arriving WS client still gets the most
            // recent in-progress total replayed on connect.
            if dirtySinceEmit,
                Date().timeIntervalSince(lastEmitAt) > emitThrottle,
                let cb = onChange
            {
                let (today, prev) = current()
                lastEmittedDayKey = todayKey
                await cb(today, prev)
                lastEmitAt = Date()
                dirtySinceEmit = false
            }
        }
        trim()
        if dirtySinceEmit, let cb = onChange {
            let (today, prev) = current()
            lastEmittedDayKey = todayKey
            await cb(today, prev)
        } else if let cb = onChange,
            let lastKey = lastEmittedDayKey,
            lastKey != todayKey
        {
            // Calendar day rolled since the last emit and nothing wrote a
            // new JSONL line. Force a synthetic broadcast so the menubar +
            // OLED reset to a fresh "today=0, prev=yesterday" frame instead
            // of holding the stale frame until the next Claude turn. Covers
            // both the trivial case (Mac stays awake across midnight) and
            // the wake-after-sleep case (system slept across one or more
            // midnights, first poll after wake observes the day shift).
            let (today, prev) = current()
            lastEmittedDayKey = todayKey
            await cb(today, prev)
        }
        // Throttled persistence: only writes if state changed since the
        // last save AND `saveThrottle` seconds have elapsed. SIGKILL/power
        // loss therefore bounds progress loss to one throttle window; a
        // graceful SIGTERM forces a final flush via `stop()`.
        saveSnapshotIfDirty()
    }

    private func enumerateJSONLSortedByMTime() -> [URL] {
        guard
            let it = FileManager.default.enumerator(
                at: claudeDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        let cutoff = Date().addingTimeInterval(Double(-retainDays * 86400))
        // Carry mtime through so we can sort the candidate set without a
        // second `attributesOfItem` pass.
        var candidates: [(url: URL, mtime: TimeInterval)] = []
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
            candidates.append((u, mtimeDate.timeIntervalSince1970))
        }
        candidates.sort { $0.mtime > $1.mtime }
        return candidates.map(\.url)
    }

    private func parseLine(_ data: Data) -> UsageEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            obj["type"] as? String == "assistant",
            let msg = obj["message"] as? [String: Any],
            let usage = msg["usage"] as? [String: Any],
            let model = msg["model"] as? String,
            let tsStr = obj["timestamp"] as? String
        else { return nil }

        let ts: Date
        if let fast = Self.parseISODate(tsStr) {
            ts = fast
        } else if let slow = Self.isoFormatter.date(from: tsStr)
            ?? Self.isoFormatterNoFrac.date(from: tsStr)
        {
            ts = slow
        } else {
            return nil
        }

        let cutoff = Date().addingTimeInterval(Double(-retainDays * 86400))
        if ts < cutoff { return nil }

        // Claude Code logs the same assistant turn 2-3 times per JSONL file
        // (streaming chunks share the same final usage). Dedupe by requestId.
        let dedupeKey: String
        if let rid = obj["requestId"] as? String, !rid.isEmpty {
            dedupeKey = "rid:\(rid)"
        } else if let mid = msg["id"] as? String, !mid.isEmpty {
            dedupeKey = "mid:\(mid)"
        } else if let uuid = obj["uuid"] as? String, !uuid.isEmpty {
            dedupeKey = "uuid:\(uuid)"
        } else {
            return nil
        }
        if seenRequestKeys[dedupeKey] != nil { return nil }
        seenRequestKeys[dedupeKey] = Calendar.current.startOfDay(for: ts)

        let input = (usage["input_tokens"] as? Int) ?? 0
        let output = (usage["output_tokens"] as? Int) ?? 0
        let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0

        // Cache writes bill at two rates: 5-minute (1.25× input) and 1-hour
        // (2× input). Prefer the nested `cache_creation` split; fall back to
        // the aggregate `cache_creation_input_tokens` priced entirely at the
        // 5m rate for pre-split logs. The nested sum equals the aggregate on
        // every Claude Code line observed, so token totals are unaffected.
        let cacheCreation5m: Int
        let cacheCreation1h: Int
        if let split = usage["cache_creation"] as? [String: Any] {
            cacheCreation5m = (split["ephemeral_5m_input_tokens"] as? Int) ?? 0
            cacheCreation1h = (split["ephemeral_1h_input_tokens"] as? Int) ?? 0
        } else {
            cacheCreation5m = (usage["cache_creation_input_tokens"] as? Int) ?? 0
            cacheCreation1h = 0
        }
        let cacheCreation = cacheCreation5m + cacheCreation1h
        logUnpricedModelOnce(for: model)
        let cost = Pricing.cost(
            model: model,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheCreation: (fiveMinute: cacheCreation5m, oneHour: cacheCreation1h),
            override: pricingOverride,
            catalog: priceCatalog
        )
        return UsageEvent(
            timestamp: ts,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreation,
            cost: cost
        )
    }

    private func ingest(_ event: UsageEvent) {
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
    }

    private func trim() {
        let cal = Calendar.current
        let cutoff = cal.startOfDay(for: Date().addingTimeInterval(Double(-retainDays * 86400)))
        dailyTotals = dailyTotals.filter { $0.key >= cutoff }
        // Evict dedup keys for days that have aged out so the set's memory
        // footprint stays bounded across long-running daemon sessions.
        seenRequestKeys = seenRequestKeys.filter { $0.value >= cutoff }
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
        // Buffer for a line that straddles a chunk boundary. Parses without
        // the byte-level marker prefilter — at most one carry per chunk, and
        // `parseLine` rejects non-assistant lines cheaply via the `type`
        // string match.
        var carry = Data()

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
                        if !carry.isEmpty {
                            // Stitch the trailing bytes of the previous chunk
                            // onto the head of this line.
                            if i > lineStart {
                                carry.append(chunk.subdata(in: lineStart..<i))
                            }
                            if let event = parseLine(carry) {
                                ingest(event)
                                anyIngested = true
                            }
                            carry.removeAll(keepingCapacity: true)
                        } else if i > lineStart,
                            Self.bufferContainsAssistantMarker(base, from: lineStart, to: i)
                        {
                            let lineData = chunk.subdata(in: lineStart..<i)
                            if let event = parseLine(lineData) {
                                ingest(event)
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
    /// still matches the disk. Any mismatch (rotation, truncation, deleted
    /// file) discards the snapshot entirely and falls back to a cold rescan
    /// — cheap enough (<1 s on a 350 MB tree) that partial reconciliation
    /// isn't worth the complexity.
    private func loadAndApplyPersistedState() -> Bool {
        guard let url = persistenceURL else { return false }
        let outcome = UsageStatePersistence.load(from: url)
        guard case .ok(let snapshot) = outcome else { return false }

        let expectedHash = UsageStatePersistence.hashDataDir(claudeDir)
        guard snapshot.claudeDataDirHash == expectedHash else { return false }
        guard snapshot.retainDays == retainDays else { return false }

        let fm = FileManager.default
        let cutoffDate = Date().addingTimeInterval(Double(-retainDays * 86400))
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
        var newKeys: [String: Date] = [:]
        for k in snapshot.dedupKeysToday {
            guard let dayDate = dayFmt.date(from: k.day) else { continue }
            let dayKey = cal.startOfDay(for: dayDate)
            if dayKey < cutoffDay { continue }
            newKeys[k.key] = dayKey
        }
        fileOffsets = newOffsets
        fileMTimes = newMTimes
        dailyTotals = newDaily
        seenRequestKeys = newKeys
        return true
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
        // briefly show the "sleep" mascot with 0 tokens before the cold
        // rescan rebuilds totals. Leaving the file absent forces a clean
        // cold path instead.
        if fileOffsets.isEmpty && dailyTotals.isEmpty { return }

        let cal = Calendar.current
        let dayFmt = UsageReaderShared.dayFormatter
        let todayKey = cal.startOfDay(for: now)

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
        // Persist today's keys only — by design (see field doc above), older
        // days are safe to drop because by the time a restart happens any
        // duplicate write for that day has already been seen and counted in
        // the in-process set.
        let todayKeys: [UsageStateSnapshot.DedupKey] = seenRequestKeys.compactMap {
            (key, day) -> UsageStateSnapshot.DedupKey? in
            guard day == todayKey else { return nil }
            return UsageStateSnapshot.DedupKey(key: key, day: dayFmt.string(from: day))
        }

        let snapshot = UsageStateSnapshot(
            schemaVersion: UsageStateSnapshot.currentSchemaVersion,
            savedAt: now,
            claudeDataDirHash: UsageStatePersistence.hashDataDir(claudeDir),
            retainDays: retainDays,
            files: files,
            dailyTotals: daily,
            dedupKeysToday: todayKeys
        )
        do {
            try UsageStatePersistence.save(snapshot, to: url)
            lastSaveAt = now
            persistDirty = false
        } catch {
            // Disk full / permission denied / etc. Keep in-memory state and
            // retry next throttle. Don't log per save — the throttle bounds
            // log spam; rare and recoverable.
        }
    }
}
