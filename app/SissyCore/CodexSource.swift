import Foundation

/// Codex's windows and plan, both read off the CLI's own event stream and
/// handed over through the lock boxes the adapter writes from inside the
/// provider's actor.
private struct CodexSignals: SourceSignals {
    let windows: AtomicWindows
    let plan: AtomicPlan
    let account: AtomicAccount

    func currentWindows() -> [UsageWindow] { windows.live() }
    func currentPlan() -> String? { plan.load() }
    func currentAccount() -> ProviderAccount? { account.load() }
}

/// Codex's `~/.codex/sessions/**/rollout-*.jsonl`. Codex rolls one JSONL per
/// session; each `event_msg` of type `token_count` carries a
/// `last_token_usage` block which is the *per-turn delta* (verified on real
/// data: summing `last_token_usage` across events in a file equals the final
/// `total_token_usage` cumulative). That makes the ingest path materially
/// simpler than the cumulative-delta dance the OpenAI docs suggest.
///
/// Model id lives in `turn_context.payload.model`, carried per-file. Falls
/// back to `"gpt-5-codex"` when absent so pricing still resolves.
final class CodexAdapter: SourceAdapter {
    let descriptor: SourceDescriptor

    private let codexDir: URL
    private let pricingOverride: [String: ModelPricing]?
    /// OpenAI slice of the runtime `PriceCatalog`. See the twin property on
    /// `ClaudeCodeAdapter` for the precedence rationale.
    private var priceCatalog: PricingTable?
    private var loggedUnpricedModels: Set<String> = []

    /// Rate-limit buckets Codex ships on a `token_count` event. Position is
    /// not meaning: each bucket carries its own `window_minutes`.
    private static let rateLimitBuckets = ["primary", "secondary"]

    /// Newest rate-limit observation and the event timestamp it came from.
    /// A cold scan walks files in no particular order, so an older rollout
    /// must not overwrite a fresher window.
    private let latestWindows: AtomicWindows
    private var latestWindowsAt: Date?

    /// Plan Codex names on the same `rate_limits` block as the windows, so it
    /// arrives and ages exactly like them: one observation per turn, and
    /// nothing at all until the CLI has taken a turn.
    private let latestPlan: AtomicPlan

    /// Who Codex is signed in as, read once from `auth.json` at start. Held
    /// beside the plan rather than inside it: the plan has two sources and a
    /// per-turn cadence, the account has one source and never moves.
    private let latestAccount: AtomicAccount

    /// Per-file "last seen model id" so a `token_count` event resolves to the
    /// `turn_context.payload.model` that immediately preceded it in the same
    /// rollout. Codex bumps the model mid-session if the user reassigns the
    /// agent; keeping per-file state preserves that correctly.
    private var fileModels: [URL: String] = [:]

    /// Per-file project, resolved from the `cwd` on the rollout's
    /// `session_meta`. Per file because Codex names it once, on the first
    /// line, which a resumed reader is already past — the same reason
    /// `fileModels` is kept and persisted.
    private var fileProjects: [URL: String] = [:]
    private let projects = ProjectResolver()

    /// Default model id used when a rollout's `turn_context` never named one
    /// (older Codex versions wrote `model_provider` but no `model`). Matches
    /// what ccusage falls back to for the same reason.
    static let defaultModel = "gpt-5-codex"

    init(codexDir: URL, pricingOverride: [String: ModelPricing]?) {
        let windows = AtomicWindows()
        let plan = AtomicPlan()
        let account = AtomicAccount()
        self.codexDir = codexDir
        self.pricingOverride = pricingOverride
        self.latestWindows = windows
        self.latestPlan = plan
        self.latestAccount = account
        self.descriptor = SourceDescriptor(
            id: "codex",
            root: codexDir,
            watcherLabel: "sissy.codex.fswatch",
            signals: CodexSignals(windows: windows, plan: plan, account: account)
        )
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

    func applyPriceCatalog(_ catalog: PriceCatalog) {
        priceCatalog = catalog.table(for: .openai)
        loggedUnpricedModels.removeAll()
    }

    /// Reports an unpriced model once per model. See the twin on
    /// `ClaudeCodeAdapter`.
    private func logUnpricedModelOnce(for model: String) {
        guard !loggedUnpricedModels.contains(model) else { return }
        guard
            OpenAIPricing.price(for: model, override: pricingOverride, catalog: priceCatalog)
                == nil
        else { return }
        loggedUnpricedModels.insert(model)
        sissyLog(
            "sissy: no rate for '\(model)' in any pricing source — its tokens "
                + "bill at $0; add a `pricingOverride` entry in server.json")
    }

    /// Takes the account from Codex's auth file, and the plan too when
    /// neither the snapshot nor a rollout has named one yet.
    ///
    /// Without this a resumed reader shows the Codex row with no plan: the
    /// offsets are at EOF, `plan_type` rides events that were already
    /// consumed, and the badge waits on the user's next turn. The auth file
    /// answers immediately, and the first rollout event that lands overwrites
    /// it — the CLI restamps the claim per turn, this file only on a token
    /// refresh.
    ///
    /// The account is stored unconditionally because this file is its only
    /// source: no rollout line carries an address, and nothing persists one.
    /// It is also why it cannot make this return true, which means "the next
    /// snapshot has something new to carry".
    func prepareToStart() -> Bool {
        let url = CodexAuthSource.defaultURL(sessionsDir: codexDir)
        guard let identity = CodexAuthSource.load(at: url) else { return false }
        latestAccount.store(identity.account)
        guard latestPlan.load() == nil, let plan = identity.plan else { return false }
        latestPlan.store(plan)
        return true
    }

    /// Bytes for `"token_count"`. Same prefilter idea as the assistant marker
    /// in `ClaudeCodeAdapter`: ~90% of rollout lines are `response_item`s
    /// (agent_message, function_call, function_call_output) and only ~5% are
    /// billable token_count events. Cheap substring check before paying the
    /// JSON-parse cost.
    private static let tokenCountMarker: [UInt8] = Array("\"token_count\"".utf8)

    /// `turn_context` lines also matter (they update the per-file model). The
    /// marker keeps the slow path bounded — we walk both prefilters on each
    /// candidate line.
    private static let turnContextMarker: [UInt8] = Array("\"turn_context\"".utf8)

    /// `session_meta` is the rollout's first line and the only one naming the
    /// working directory the session was started in.
    private static let sessionMetaMarker: [UInt8] = Array("\"session_meta\"".utf8)

    /// Linear scan for `marker` within `buf[from..<to]`. Cheap substring
    /// prefilter run before paying the JSON-parse cost on a candidate line.
    private static func bufferContainsMarker(
        _ buf: UnsafePointer<UInt8>, from: Int, to: Int, marker: [UInt8]
    ) -> Bool {
        let m = marker.count
        let n = to - from
        if m > n { return false }
        let limit = to - m
        var i = from
        while i <= limit {
            if buf[i] == marker[0] {
                var j = 1
                while j < m && buf[i + j] == marker[j] { j += 1 }
                if j == m { return true }
            }
            i += 1
        }
        return false
    }

    static func bufferContainsTokenCountMarker(
        _ buf: UnsafePointer<UInt8>, from: Int, to: Int
    ) -> Bool {
        bufferContainsMarker(buf, from: from, to: to, marker: tokenCountMarker)
    }

    static func bufferContainsTurnContextMarker(
        _ buf: UnsafePointer<UInt8>, from: Int, to: Int
    ) -> Bool {
        bufferContainsMarker(buf, from: from, to: to, marker: turnContextMarker)
    }

    static func bufferContainsSessionMetaMarker(
        _ buf: UnsafePointer<UInt8>, from: Int, to: Int
    ) -> Bool {
        bufferContainsMarker(buf, from: from, to: to, marker: sessionMetaMarker)
    }

    func lineMayCount(_ buf: UnsafePointer<UInt8>, from: Int, to: Int) -> Bool {
        Self.bufferContainsTokenCountMarker(buf, from: from, to: to)
            || Self.bufferContainsTurnContextMarker(buf, from: from, to: to)
            || Self.bufferContainsSessionMetaMarker(buf, from: from, to: to)
    }

    /// Routes a JSONL line to the right parser. `turn_context` lines update
    /// the per-file model state; `event_msg/token_count` lines produce a
    /// billable `UsageEvent`. Any other shape is silently dropped.
    func event(from line: SourceLine, seen: inout [String: SeenEvent]) -> UsageEvent? {
        // Try token_count first (most lines past the prefilter) and fall
        // through to turn_context only on miss. turn_context is sparse —
        // one per turn — so the redundant parse on hit is fine.
        if let event = parseTokenCount(line, seen: &seen) { return event }
        applyTurnContext(line.data, url: line.url)
        applySessionMeta(line.data, url: line.url)
        return nil
    }

    /// Records the project a rollout belongs to from its `session_meta` line.
    private func applySessionMeta(_ data: Data, url: URL) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            obj["type"] as? String == "session_meta",
            let payload = obj["payload"] as? [String: Any],
            let cwd = payload["cwd"] as? String,
            !cwd.isEmpty
        else { return }
        guard let project = projects.project(for: cwd) else { return }
        fileProjects[url] = project
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

    private func captureWindows(_ raw: Any?, observedAt: Date) {
        guard let dict = raw as? [String: Any] else { return }
        if let seen = latestWindowsAt, seen >= observedAt { return }
        // Ahead of the window parse and outside its `isEmpty` bail: a rollout
        // whose buckets did not parse still named the plan, and the plan is
        // what the panel puts next to the provider whether or not there are
        // gauges under it.
        if let plan = UsageReaderShared.sanitizedPlanToken(dict["plan_type"] as? String) {
            latestPlan.store(plan)
        }
        let windows = Self.rateLimitBuckets.compactMap { key -> UsageWindow? in
            guard let bucket = dict[key] as? [String: Any],
                let minutes = bucket["window_minutes"] as? Int,
                let used = bucket["used_percent"] as? Double,
                let resets = bucket["resets_at"] as? Double
            else { return nil }
            return UsageWindow(
                minutes: minutes,
                usedPercent: used,
                resetsAt: Date(timeIntervalSince1970: resets)
            )
        }
        if windows.isEmpty { return }
        latestWindows.store(windows)
        latestWindowsAt = observedAt
    }

    /// Parses a `token_count` event line. Returns nil for any non-billable
    /// shape, dedup hit, or event outside the retain window.
    private func parseTokenCount(_ line: SourceLine, seen: inout [String: SeenEvent])
        -> UsageEvent?
    {
        guard let obj = try? JSONSerialization.jsonObject(with: line.data) as? [String: Any],
            obj["type"] as? String == "event_msg",
            let payload = obj["payload"] as? [String: Any],
            payload["type"] as? String == "token_count",
            let info = payload["info"] as? [String: Any],
            let last = info["last_token_usage"] as? [String: Any]
        else { return nil }

        // Timestamp lives on the wrapper, ISO with fractional seconds. The
        // shape is identical to Claude Code's, so both go through
        // `UsageReaderShared.parseTimestamp`.
        let ts: Date
        if let tsStr = obj["timestamp"] as? String,
            let parsed = UsageReaderShared.parseTimestamp(tsStr)
        {
            ts = parsed
        } else {
            // Without a timestamp we can't bucket the event, but rather than
            // dropping it we attribute it to "now" so live ingest still
            // surfaces. Cold-scan backfill drops if it falls outside the
            // retain window below.
            ts = Date()
        }

        captureWindows(payload["rate_limits"], observedAt: ts)

        if ts < line.retainCutoff { return nil }

        // Dedup by file + byte offset of the line. Belt-and-suspenders since
        // the per-file offset already prevents re-reading, but it survives a
        // snapshot rollback or hand-edited usage-state file. Today-only
        // persistence — `trim()` evicts older keys.
        let dedupKey = "codex:\(line.url.path):\(line.byteOffset)"
        if seen[dedupKey] != nil { return nil }
        seen[dedupKey] = SeenEvent(day: Calendar.current.startOfDay(for: ts))

        let input = UsageReaderShared.tokenCount(last["input_tokens"])
        let cached = UsageReaderShared.tokenCount(last["cached_input_tokens"])
        let output = UsageReaderShared.tokenCount(last["output_tokens"])
        // Codex `input_tokens` is gross input (cached + uncached). ccusage and
        // OpenAI's pricing both treat cached as a separate billable channel,
        // so we strip the cached component out before passing along.
        let uncached = max(input - cached, 0)
        // `output_tokens` is already gross — it includes reasoning tokens.
        // Verified against real rollouts: `total_tokens == input + output`
        // (reasoning is NOT added on top). `reasoning_output_tokens` is a
        // sub-breakdown for observability, not an additive counter. ccusage
        // uses `output_tokens` alone for the same reason.

        let model = fileModels[line.url] ?? Self.defaultModel
        logUnpricedModelOnce(for: model)
        let cost = OpenAIPricing.cost(
            model: model,
            input: uncached,
            output: output,
            cacheRead: cached,
            override: pricingOverride,
            catalog: priceCatalog
        )
        return UsageEvent(
            timestamp: ts,
            model: model,
            project: fileProjects[line.url],
            inputTokens: uncached,
            outputTokens: output,
            cacheReadTokens: cached,
            cacheCreationTokens: 0,
            cost: cost
        )
    }

    /// `fileModels` goes with the offsets and mtimes: it is keyed the same way
    /// and is what prices a resumed file, so an entry outliving its offset
    /// would be a model map for a file nothing reads.
    func trim(retaining files: Set<URL>) {
        fileModels = fileModels.filter { files.contains($0.key) }
        fileProjects = fileProjects.filter { files.contains($0.key) }
    }

    /// Restores the state that has no cheap way back.
    ///
    /// A snapshot with no resume block is refused outright: without the
    /// persisted model map the only way to rebuild it is to re-read every byte
    /// already consumed, and the reader emits nothing until that finishes —
    /// measured at ~110 s against a 43 MB tree, because Codex writes single
    /// JSONL lines of ~175 KB. A cold scan of the same tree is ~2 s and
    /// rebuilds the map exactly, so a snapshot from before this field existed
    /// is better discarded than honoured.
    ///
    /// The model map is what keeps a resume that landed past a `turn_context`
    /// but before its matching `token_count` from pricing that turn against
    /// `defaultModel`. Entries for files the offset reconciliation dropped are
    /// skipped — they describe bytes this reader will no longer resume from.
    ///
    /// The project is read through the resolver again rather than trusted as
    /// persisted. Codex names the directory once, on the rollout's first line,
    /// so a resumed reader never sees that line again and would hand every
    /// later turn a path an older build resolved under the older rule — which
    /// is how a scratch directory came back as a project one turn after the
    /// archive had stopped naming it.
    func resume(from snapshot: UsageStateSnapshot, offsets: [URL: UInt64]) -> Bool {
        guard let resume = snapshot.codexResume else { return false }
        for entry in resume.fileModels {
            let fileURL = URL(fileURLWithPath: entry.path)
            guard offsets[fileURL] != nil else { continue }
            fileModels[fileURL] = entry.model
            fileProjects[fileURL] = entry.project.flatMap { projects.project(for: $0) }
        }
        latestPlan.store(resume.plan)
        guard !resume.rateLimitWindows.isEmpty else { return true }
        latestWindows.store(resume.rateLimitWindows)
        latestWindowsAt = resume.rateLimitWindowsAt
        return true
    }

    /// What has no cheap way back after a relaunch.
    ///
    /// A file appears here once either its model or its project is known. One
    /// whose `session_meta` named a directory but whose `turn_context` has not
    /// been read yet carries `defaultModel` — the same value the live path
    /// prices it at until that line lands, so the entry records no more than
    /// the reader would answer anyway.
    func resumeState() -> UsageStateSnapshot.CodexResume? {
        UsageStateSnapshot.CodexResume(
            fileModels: Set(fileModels.keys).union(fileProjects.keys).map { url in
                UsageStateSnapshot.FileModel(
                    path: url.path,
                    model: fileModels[url] ?? Self.defaultModel,
                    project: fileProjects[url]
                )
            },
            // Raw, not `live()`: a bucket that expires between save and load
            // is dropped on read anyway, and filtering here would throw away
            // one that still has seconds left.
            rateLimitWindows: latestWindows.load(),
            rateLimitWindowsAt: latestWindowsAt,
            plan: latestPlan.load()
        )
    }
}

extension LocalUsageProvider {
    /// Codex's tail.
    static func codex(
        codexDir: URL = CodexAdapter.defaultDir(),
        retainDays: Int = 2,
        pollInterval: Duration = .seconds(60),
        persistenceURL: URL? = nil,
        historyRoot: URL? = nil,
        pricingOverride: [String: ModelPricing]? = nil
    ) -> LocalUsageProvider {
        LocalUsageProvider(
            adapter: CodexAdapter(codexDir: codexDir, pricingOverride: pricingOverride),
            retainDays: retainDays,
            pollInterval: pollInterval,
            persistenceURL: persistenceURL,
            historyRoot: historyRoot
        )
    }
}
