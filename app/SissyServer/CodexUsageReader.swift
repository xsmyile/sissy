import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Tails `~/.codex/sessions/**/rollout-*.jsonl` and emits aggregated daily
/// usage to `UsageAggregator`. Codex rolls one JSONL per session; each
/// `event_msg` of type `token_count` carries a `last_token_usage` block which
/// is the *per-turn delta* (verified on real data: summing `last_token_usage`
/// across events in a file equals the final `total_token_usage` cumulative).
/// That makes the ingest path materially simpler than the cumulative-delta
/// dance the OpenAI docs suggest.
///
/// Model id lives in `turn_context.payload.model`, carried per-file. Falls
/// back to `"gpt-5-codex"` when absent so pricing still resolves.
actor CodexUsageReader: UsageProvider {
    nonisolated let id: String = "codex"

    private let codexDir: URL
    private let retainDays: Int
    private let pollInterval: Duration
    private let persistenceURL: URL?
    private let pricingOverride: [String: ModelPricing]?

    private var fileOffsets: [URL: UInt64] = [:]
    private var fileMTimes: [URL: TimeInterval] = [:]
    /// Per-file "last seen model id" so a `token_count` event resolves to the
    /// `turn_context.payload.model` that immediately preceded it in the same
    /// rollout. Codex bumps the model mid-session if the user reassigns the
    /// agent; keeping per-file state preserves that correctly.
    private var fileModels: [URL: String] = [:]
    private var dailyTotals: [Date: DayTotals] = [:]
    private var seenLineKeys: [String: Date] = [:]
    private var pollTask: Task<Void, Never>?
    private var onChange: (@Sendable (DayTotals, DayTotals?) async -> Void)?
    nonisolated private let watchedCounter = AtomicIntCounter()
    private var fsWatcher: FSWatcher?

    private var persistDirty = false
    private var lastSaveAt: Date = .distantPast
    private var lastEmittedDayKey: Date?
    private var coldScanComplete = false
    private static let saveThrottle: TimeInterval = 5
    private static let fsEventsLatency: CFTimeInterval = 1.0

    /// Default model id used when a rollout's `turn_context` never named one
    /// (older Codex versions wrote `model_provider` but no `model`). Matches
    /// what ccusage falls back to for the same reason.
    static let defaultModel = "gpt-5-codex"

    /// Bytes for `"token_count"`. Same prefilter idea as the assistant marker
    /// in `ClaudeCodeUsageReader`: ~90% of rollout lines are `response_item`s
    /// (agent_message, function_call, function_call_output) and only ~5% are
    /// billable token_count events. Cheap substring check before paying the
    /// JSON-parse cost.
    private static let tokenCountMarker: [UInt8] = Array("\"token_count\"".utf8)

    static func bufferContainsTokenCountMarker(
        _ buf: UnsafePointer<UInt8>, from: Int, to: Int
    ) -> Bool {
        let pat = tokenCountMarker
        let m = pat.count
        let n = to - from
        if m > n { return false }
        let limit = to - m
        var i = from
        while i <= limit {
            if buf[i] == pat[0] {
                var j = 1
                while j < m && buf[i + j] == pat[j] { j += 1 }
                if j == m { return true }
            }
            i += 1
        }
        return false
    }

    /// `turn_context` lines also matter (they update the per-file model). The
    /// marker keeps the slow path bounded — we walk both prefilters on each
    /// candidate line.
    private static let turnContextMarker: [UInt8] = Array("\"turn_context\"".utf8)

    static func bufferContainsTurnContextMarker(
        _ buf: UnsafePointer<UInt8>, from: Int, to: Int
    ) -> Bool {
        let pat = turnContextMarker
        let m = pat.count
        let n = to - from
        if m > n { return false }
        let limit = to - m
        var i = from
        while i <= limit {
            if buf[i] == pat[0] {
                var j = 1
                while j < m && buf[i + j] == pat[j] { j += 1 }
                if j == m { return true }
            }
            i += 1
        }
        return false
    }

    init(
        codexDir: URL = CodexUsageReader.defaultDir(),
        retainDays: Int = 2,
        pollInterval: Duration = .seconds(60),
        persistenceURL: URL? = nil,
        pricingOverride: [String: ModelPricing]? = nil
    ) {
        self.codexDir = codexDir
        self.retainDays = retainDays
        self.pollInterval = pollInterval
        self.persistenceURL = persistenceURL
        self.pricingOverride = pricingOverride
    }

    /// Resolves the default rollout directory. Honors `CODEX_HOME` if set
    /// (matches `codex` CLI semantics) so an installation that relocates the
    /// home (e.g. dotfile manager symlinking) still gets picked up.
    static func defaultDir() -> URL {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appendingPathComponent("sessions")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    }

    func start(onChange: @escaping @Sendable (DayTotals, DayTotals?) async -> Void) async {
        self.onChange = onChange
        let loaded = loadAndApplyPersistedState()
        if loaded {
            let (today, prev) = current()
            lastEmittedDayKey = Calendar.current.startOfDay(for: Date())
            await onChange(today, prev)
        }
        await poll()
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
        saveSnapshotIfDirty(force: true)
        fsWatcher?.stop()
        fsWatcher = nil
        pollTask?.cancel()
        pollTask = nil
        // See ClaudeCodeUsageReader.stop for the rationale on clearing
        // onChange — breaks the strong-self capture the aggregator made
        // via the broadcast closure.
        onChange = nil
    }

    private func startFSWatcher() {
        // Codex creates dated subdirectories on demand (the first session of
        // a new month). FSWatcher follows new subdirs automatically because
        // the stream is rooted at `codexDir` — same behavior the Claude
        // reader relies on for project-folder creation.
        let watcher = FSWatcher(label: "sissy.codex.fswatch")
        let ok = watcher.start(path: codexDir, latency: Self.fsEventsLatency) { [weak self] event in
            await self?.ingestEventPaths(
                event.urls, rescanAll: event.rescanAll, rootChanged: event.rootChanged)
        }
        if ok {
            fsWatcher = watcher
        }
    }

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
            var seen = Set<URL>()
            for url in urls where url.pathExtension == "jsonl" {
                if !seen.insert(url).inserted { continue }
                if ingestNewLines(in: url) { dirty = true }
            }
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
        let prev = coldScanComplete ? dailyTotals[prevKey] : nil
        return (
            dailyTotals[todayKey] ?? DayTotals(totalTokens: 0, totalCost: 0),
            prev
        )
    }

    nonisolated func filesWatched() -> Int { watchedCounter.load() }
    func isWarm() -> Bool { coldScanComplete }

    private func poll() async {
        let files = enumerateJSONLSortedByMTime()
        watchedCounter.store(files.count)
        let todayKey = Calendar.current.startOfDay(for: Date())
        var dirtySinceEmit = false
        var lastEmitAt = Date.distantPast
        let emitThrottle: TimeInterval = 0.2
        for (i, url) in files.enumerated() {
            if ingestNewLines(in: url) { dirtySinceEmit = true }
            // Same cooperative-cancellation pattern as ClaudeCodeUsageReader:
            // yield + bail on Task cancellation so `stop()` can interrupt
            // an in-flight cold scan.
            if i % 4 == 3 {
                await Task.yield()
                if Task.isCancelled { return }
            }
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
            let (today, prev) = current()
            lastEmittedDayKey = todayKey
            await cb(today, prev)
        }
        saveSnapshotIfDirty()
    }

    private func enumerateJSONLSortedByMTime() -> [URL] {
        guard
            let it = FileManager.default.enumerator(
                at: codexDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        let cutoff = Date().addingTimeInterval(Double(-retainDays * 86400))
        var candidates: [(url: URL, mtime: TimeInterval)] = []
        while let u = it.nextObject() as? URL {
            guard u.pathExtension == "jsonl" else { continue }
            // Codex names files `rollout-...jsonl`; tolerate other shapes
            // (some forks rename) by accepting any .jsonl under the tree.
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: u.path),
                let mtimeDate = attrs[.modificationDate] as? Date
            else { continue }
            if mtimeDate < cutoff, fileOffsets[u] == nil { continue }
            candidates.append((u, mtimeDate.timeIntervalSince1970))
        }
        candidates.sort { $0.mtime > $1.mtime }
        return candidates.map(\.url)
    }

    /// Updates per-file model from a `turn_context` line. Idempotent; called
    /// from the streaming reader before any subsequent `token_count` event.
    private func applyTurnContext(_ data: Data, url: URL) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            obj["type"] as? String == "turn_context",
            let payload = obj["payload"] as? [String: Any],
            let model = payload["model"] as? String,
            !model.isEmpty
        else { return }
        fileModels[url] = model
    }

    /// Parses a `token_count` event line. Returns nil for any non-billable
    /// shape, dedup hit, or event outside the retain window.
    private func parseTokenCount(_ data: Data, url: URL, byteOffset: UInt64) -> UsageEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            obj["type"] as? String == "event_msg",
            let payload = obj["payload"] as? [String: Any],
            payload["type"] as? String == "token_count",
            let info = payload["info"] as? [String: Any],
            let last = info["last_token_usage"] as? [String: Any]
        else { return nil }

        // Timestamp lives on the wrapper, ISO with fractional seconds. Reuse
        // ClaudeCodeUsageReader.parseISODate — identical shape on Codex
        // rollouts, no need for a parallel implementation.
        let ts: Date
        if let tsStr = obj["timestamp"] as? String,
            let parsed = ClaudeCodeUsageReader.parseISODate(tsStr)
        {
            ts = parsed
        } else {
            // Without a timestamp we can't bucket the event, but rather than
            // dropping it we attribute it to "now" so live ingest still
            // surfaces. Cold-scan backfill drops if it falls outside the
            // retain window below.
            ts = Date()
        }

        let cutoff = Date().addingTimeInterval(Double(-retainDays * 86400))
        if ts < cutoff { return nil }

        // Dedup by file + byte offset of the line. Belt-and-suspenders since
        // the per-file offset already prevents re-reading, but it survives a
        // snapshot rollback or hand-edited usage-state file. Today-only
        // persistence — `trim()` evicts older keys.
        let dedupKey = "codex:\(url.path):\(byteOffset)"
        if seenLineKeys[dedupKey] != nil { return nil }
        seenLineKeys[dedupKey] = Calendar.current.startOfDay(for: ts)

        let input = (last["input_tokens"] as? Int) ?? 0
        let cached = (last["cached_input_tokens"] as? Int) ?? 0
        let output = (last["output_tokens"] as? Int) ?? 0
        // Codex `input_tokens` is gross input (cached + uncached). ccusage and
        // OpenAI's pricing both treat cached as a separate billable channel,
        // so we strip the cached component out before passing along.
        let uncached = max(input - cached, 0)
        // `output_tokens` is already gross — it includes reasoning tokens.
        // Verified against real rollouts: `total_tokens == input + output`
        // (reasoning is NOT added on top). `reasoning_output_tokens` is a
        // sub-breakdown for observability, not an additive counter. ccusage
        // uses `output_tokens` alone for the same reason.

        let model = fileModels[url] ?? Self.defaultModel
        let cost = OpenAIPricing.cost(
            model: model,
            input: uncached,
            output: output,
            cacheRead: cached,
            override: pricingOverride
        )
        return UsageEvent(
            timestamp: ts,
            model: model,
            inputTokens: uncached,
            outputTokens: output,
            cacheReadTokens: cached,
            cacheCreationTokens: 0,
            cost: cost
        )
    }

    private func ingest(_ event: UsageEvent) {
        let key = Calendar.current.startOfDay(for: event.timestamp)
        let totalTokens =
            event.inputTokens
            + event.outputTokens
            + event.cacheReadTokens
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
        seenLineKeys = seenLineKeys.filter { $0.value >= cutoff }
    }

    private static let ingestChunkSize = 64 * 1024

    private func ingestNewLines(in url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let mtimeDate = attrs[.modificationDate] as? Date,
            let size = (attrs[.size] as? NSNumber)?.uint64Value
        else { return false }
        let mtime = mtimeDate.timeIntervalSince1970
        let prevMTime = fileMTimes[url] ?? 0
        let prevOffset = fileOffsets[url] ?? 0
        if mtime == prevMTime && size == prevOffset { return false }
        if size < prevOffset { fileOffsets[url] = 0 }

        let readFrom = fileOffsets[url] ?? 0
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        do { try fh.seek(toOffset: readFrom) } catch { return false }
        fileMTimes[url] = mtime

        var anyIngested = false
        var lastNewlineAbs: UInt64 = readFrom
        var chunkBaseAbs: UInt64 = readFrom
        var totalRead: UInt64 = 0
        var carry = Data()
        var carryStartAbs: UInt64 = readFrom

        while true {
            let chunk: Data
            do {
                chunk = try fh.read(upToCount: Self.ingestChunkSize) ?? Data()
            } catch { break }
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
                        let absLineStart = !carry.isEmpty ? carryStartAbs : chunkBaseAbs + UInt64(lineStart)
                        if !carry.isEmpty {
                            if i > lineStart {
                                carry.append(chunk.subdata(in: lineStart..<i))
                            }
                            processLine(carry, url: url, byteOffset: absLineStart, anyIngested: &anyIngested)
                            carry.removeAll(keepingCapacity: true)
                        } else if i > lineStart {
                            let hasTokenCount = Self.bufferContainsTokenCountMarker(
                                base, from: lineStart, to: i)
                            let hasTurnContext =
                                !hasTokenCount
                                && Self.bufferContainsTurnContextMarker(base, from: lineStart, to: i)
                            if hasTokenCount || hasTurnContext {
                                let lineData = chunk.subdata(in: lineStart..<i)
                                processLine(
                                    lineData, url: url, byteOffset: absLineStart, anyIngested: &anyIngested)
                            }
                        }
                        lineStart = i + 1
                        lastNewlineAbs = chunkBaseAbs + UInt64(lineStart)
                    }
                    i += 1
                }
                if lineStart < n {
                    if carry.isEmpty { carryStartAbs = chunkBaseAbs + UInt64(lineStart) }
                    carry.append(chunk.subdata(in: lineStart..<n))
                }
            }
            chunkBaseAbs += UInt64(chunk.count)
        }

        if totalRead == 0 { return false }

        fileOffsets[url] = lastNewlineAbs
        persistDirty = true
        return anyIngested
    }

    /// Routes a JSONL line to the right parser. `turn_context` lines update
    /// the per-file model state; `event_msg/token_count` lines produce a
    /// billable `UsageEvent`. Any other shape is silently dropped.
    private func processLine(_ data: Data, url: URL, byteOffset: UInt64, anyIngested: inout Bool) {
        // Try token_count first (most lines past the prefilter) and fall
        // through to turn_context only on miss. turn_context is sparse —
        // one per turn — so the redundant parse on hit is fine.
        if let event = parseTokenCount(data, url: url, byteOffset: byteOffset) {
            ingest(event)
            anyIngested = true
            return
        }
        applyTurnContext(data, url: url)
    }

    private func loadAndApplyPersistedState() -> Bool {
        guard let url = persistenceURL else { return false }
        let outcome = UsageStatePersistence.load(from: url)
        guard case .ok(let snapshot) = outcome else { return false }

        let expectedHash = UsageStatePersistence.hashDataDir(codexDir)
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
                stale = true
                break
            }
            if mtimeDate < cutoffDate { continue }
            let diskMTime = mtimeDate.timeIntervalSince1970
            if diskMTime + 0.0005 < entry.mtimeUnix || size < entry.offset {
                stale = true
                break
            }
            newOffsets[fileURL] = entry.offset
            newMTimes[fileURL] = entry.mtimeUnix
        }
        if stale { return false }

        let cal = Calendar.current
        let dayFmt = Self.dayFormatter
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
        seenLineKeys = newKeys
        // `fileModels` is not in the snapshot — it's derived from the
        // `turn_context` lines preceding each `token_count`. After a restart
        // that resumed past a turn_context but before its matching
        // token_count, the next event would otherwise fall back to
        // `defaultModel` and mis-price the turn. Backfill from disk now,
        // before any ingest can fire.
        for (url, offset) in newOffsets where offset > 0 {
            if let model = scanLastModel(in: url, upTo: offset) {
                fileModels[url] = model
            }
        }
        return true
    }

    /// Read the file from byte 0 up to `upTo`, looking only for
    /// `turn_context` lines. Returns the model id from the latest match (or
    /// nil if no turn_context appeared before the offset). Used once per
    /// loaded file at startup; cost is bounded by rollout size (~hundreds
    /// of KB) and the byte-marker prefilter skips ~95% of lines without
    /// JSON parse.
    private func scanLastModel(in url: URL, upTo: UInt64) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        var remaining = upTo
        var carry = Data()
        var latest: String? = nil
        while remaining > 0 {
            let want = min(remaining, UInt64(Self.ingestChunkSize))
            let chunk: Data
            do {
                chunk = try fh.read(upToCount: Int(want)) ?? Data()
            } catch { break }
            if chunk.isEmpty { break }
            remaining -= UInt64(chunk.count)
            let combined = carry + chunk
            carry.removeAll(keepingCapacity: true)
            var lineStart = combined.startIndex
            for i in combined.indices {
                if combined[i] == 0x0A {
                    let lineData = combined.subdata(in: lineStart..<i)
                    let lineCount = lineData.count
                    if lineCount > 0 {
                        let hasMarker = lineData.withUnsafeBytes {
                            (raw: UnsafeRawBufferPointer) -> Bool in
                            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
                            else { return false }
                            return Self.bufferContainsTurnContextMarker(base, from: 0, to: lineCount)
                        }
                        if hasMarker,
                            let obj = try? JSONSerialization.jsonObject(with: lineData)
                                as? [String: Any],
                            obj["type"] as? String == "turn_context",
                            let payload = obj["payload"] as? [String: Any],
                            let model = payload["model"] as? String, !model.isEmpty
                        {
                            latest = model
                        }
                    }
                    lineStart = i + 1
                }
            }
            if lineStart < combined.endIndex {
                carry = combined.subdata(in: lineStart..<combined.endIndex)
            }
        }
        return latest
    }

    private func saveSnapshotIfDirty(force: Bool = false) {
        guard let url = persistenceURL else { return }
        if !force && !persistDirty { return }
        let now = Date()
        if !force && now.timeIntervalSince(lastSaveAt) < Self.saveThrottle { return }
        if fileOffsets.isEmpty && dailyTotals.isEmpty { return }

        let cal = Calendar.current
        let dayFmt = Self.dayFormatter
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
        let todayKeys: [UsageStateSnapshot.DedupKey] = seenLineKeys.compactMap {
            (key, day) -> UsageStateSnapshot.DedupKey? in
            guard day == todayKey else { return nil }
            return UsageStateSnapshot.DedupKey(key: key, day: dayFmt.string(from: day))
        }

        let snapshot = UsageStateSnapshot(
            schemaVersion: UsageStateSnapshot.currentSchemaVersion,
            savedAt: now,
            claudeDataDirHash: UsageStatePersistence.hashDataDir(codexDir),
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
            // Same swallow-and-retry policy as ClaudeCodeUsageReader.
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()
}
