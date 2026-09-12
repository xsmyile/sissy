import Foundation

/// Claude Code's out-of-band facts. Neither is anything the tail parsed: the
/// windows come from the usage endpoint the limits probe polls, and the plan
/// from the CLI's own config file — which is why the plan is readable whether
/// or not the user turned the probe on.
private struct ClaudeCodeSignals: SourceSignals {
    let limitsProbe: ClaudeLimitsProbe?
    let profile: ClaudeProfileSource

    func currentWindows() -> [UsageWindow] { limitsProbe?.currentWindows() ?? [] }
    func currentPlan() -> String? { profile.currentPlan() }
    func currentPlanTier() -> String? { profile.currentPlanTier() }
}

/// Claude Code's `~/.claude/projects/**/*.jsonl`: one `assistant` line per
/// streamed chunk of a turn, each carrying the turn's final usage and its own
/// model, deduped by request id.
final class ClaudeCodeAdapter: SourceAdapter {
    let descriptor: SourceDescriptor

    /// Per-model price overrides from `ServerConfig.pricingOverride`. When a
    /// model matches an override entry (exact or longest-prefix) the override
    /// outranks both the runtime catalog and the embedded seed.
    private let pricingOverride: [String: ModelPricing]?
    /// Anthropic slice of the runtime `PriceCatalog`. Sits between the user's
    /// override and the embedded generated seed, so a model that launched after
    /// this build was cut still prices correctly. Refreshed in place by
    /// `applyPriceCatalog`; a refresh applies to events ingested from then on
    /// and does not reprice accumulated totals.
    private var priceCatalog: PricingTable?
    /// Models already reported as unpriced. Keeps the warning to one line per
    /// model per run instead of one per ingested event.
    private var loggedUnpricedModels: Set<String> = []
    private let profile: ClaudeProfileSource

    init(
        claudeDir: URL,
        pricingOverride: [String: ModelPricing]?,
        limitsProbe: ClaudeLimitsProbe?,
        profile: ClaudeProfileSource
    ) {
        self.pricingOverride = pricingOverride
        self.profile = profile
        self.descriptor = SourceDescriptor(
            id: "claude-code",
            root: claudeDir,
            watcherLabel: "sissy.usage.fswatch",
            signals: ClaudeCodeSignals(limitsProbe: limitsProbe, profile: profile)
        )
    }

    func applyPriceCatalog(_ catalog: PriceCatalog) {
        priceCatalog = catalog.table(for: .anthropic)
        // Re-arm the log: a model the previous catalog lacked may now resolve,
        // and the operator wants to see that it healed.
        loggedUnpricedModels.removeAll()
    }

    /// Cheap by construction: the source stats the file and re-parses only
    /// when it actually moved, and no more often than its own floor.
    func willPoll() { profile.refresh() }

    /// Ahead of the first frame for the same reason `willPoll` re-reads it: a
    /// relaunch that resumes from a snapshot emits before any line is parsed,
    /// and the plan is what the panel badges that row with.
    func prepareToStart() -> Bool {
        profile.refresh()
        return false
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
        sissyLog(
            "sissy: no rate for '\(model)' in any pricing source — its tokens "
                + "bill at $0; add a `pricingOverride` entry in server.json")
    }

    /// Bytes for `"type"` and `"assistant"`. Used as a cheap prefilter on raw
    /// line bytes before paying the JSON-parse cost: a line passes only if it
    /// contains `"type"` followed (with optional JSON whitespace and a `:`) by
    /// `"assistant"`. Tolerating whitespace matters — `json.dumps` defaults
    /// emit `"type": "assistant"`, and pretty-printed rollouts otherwise slip
    /// past a strict-compact prefilter.
    private static let typeKeyBytes: [UInt8] = Array("\"type\"".utf8)
    private static let assistantValueBytes: [UInt8] = Array("\"assistant\"".utf8)

    func lineMayCount(_ buf: UnsafePointer<UInt8>, from: Int, to: Int) -> Bool {
        Self.bufferContainsAssistantMarker(buf, from: from, to: to)
    }

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

    /// One assistant line's contribution, which is the whole turn the first
    /// time its key is seen and the growth in output on every copy after.
    ///
    /// A copy carrying no more output than was already billed owes nothing,
    /// and that covers one carrying *less*: a request id whose count goes
    /// backwards is not something this layer can act on, and re-reading a
    /// file from an earlier offset walks the same copies again by design.
    func event(from line: SourceLine, seen: inout [String: SeenEvent]) -> UsageEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: line.data) as? [String: Any],
            obj["type"] as? String == "assistant",
            let msg = obj["message"] as? [String: Any],
            let usage = msg["usage"] as? [String: Any],
            let model = msg["model"] as? String,
            let tsStr = obj["timestamp"] as? String
        else { return nil }

        guard let ts = UsageReaderShared.parseTimestamp(tsStr) else { return nil }

        if ts < line.retainCutoff { return nil }

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

        let output = UsageReaderShared.tokenCount(usage["output_tokens"])
        if let billed = seen[dedupeKey] {
            guard let already = billed.billedOutputTokens, output > already else { return nil }
            seen[dedupeKey]?.billedOutputTokens = output
            return streamedRemainder(model: model, at: ts, outputTokens: output - already)
        }
        seen[dedupeKey] = SeenEvent(
            day: Calendar.current.startOfDay(for: ts), billedOutputTokens: output)

        let input = UsageReaderShared.tokenCount(usage["input_tokens"])
        let cacheRead = UsageReaderShared.tokenCount(usage["cache_read_input_tokens"])

        // Cache writes bill at two rates: 5-minute (1.25× input) and 1-hour
        // (2× input). Prefer the nested `cache_creation` split; fall back to
        // the aggregate `cache_creation_input_tokens` priced entirely at the
        // 5m rate for pre-split logs. The nested sum equals the aggregate on
        // every Claude Code line observed, so token totals are unaffected.
        let cacheCreation5m: Int
        let cacheCreation1h: Int
        if let split = usage["cache_creation"] as? [String: Any] {
            cacheCreation5m = UsageReaderShared.tokenCount(split["ephemeral_5m_input_tokens"])
            cacheCreation1h = UsageReaderShared.tokenCount(split["ephemeral_1h_input_tokens"])
        } else {
            cacheCreation5m = UsageReaderShared.tokenCount(usage["cache_creation_input_tokens"])
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
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreation,
            cost: cost
        )
    }

    /// What a later copy of a message already counted once still owes.
    ///
    /// Only the output count grows between the copies: the input and cache
    /// counts were fixed when the request was made and every copy repeats
    /// them, so a remainder that carried them again would bill the same cache
    /// read two, three, four times. Measured on a day of real logs against
    /// `ccusage`, which lands on all four token counts exactly this way.
    ///
    /// The remainder carries its own copy's timestamp, so a turn that streams
    /// across local midnight is billed partly to each day rather than moved
    /// whole to the later one. Both days are right about what was spent in
    /// them, and the earlier one may already be archived by the time the
    /// later copy lands — a day the tail has closed is not one it reopens.
    private func streamedRemainder(model: String, at timestamp: Date, outputTokens: Int)
        -> UsageEvent
    {
        UsageEvent(
            timestamp: timestamp,
            model: model,
            inputTokens: 0,
            outputTokens: outputTokens,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            cost: Pricing.cost(
                model: model,
                input: 0,
                output: outputTokens,
                cacheRead: 0,
                cacheCreation: (fiveMinute: 0, oneHour: 0),
                override: pricingOverride,
                catalog: priceCatalog
            )
        )
    }
}

extension LocalUsageProvider {
    /// Claude Code's tail. Keeps the legacy unqualified `usage-state.json`
    /// persistence path where callers pass one — existing installs already
    /// wrote it, and renaming it would strand their offsets.
    static func claudeCode(
        claudeDir: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects"),
        retainDays: Int = 2,
        pollInterval: Duration = .seconds(60),
        persistenceURL: URL? = nil,
        historyRoot: URL? = nil,
        pricingOverride: [String: ModelPricing]? = nil,
        limitsProbe: ClaudeLimitsProbe? = nil,
        profile: ClaudeProfileSource = ClaudeProfileSource()
    ) -> LocalUsageProvider {
        LocalUsageProvider(
            adapter: ClaudeCodeAdapter(
                claudeDir: claudeDir,
                pricingOverride: pricingOverride,
                limitsProbe: limitsProbe,
                profile: profile
            ),
            retainDays: retainDays,
            pollInterval: pollInterval,
            persistenceURL: persistenceURL,
            historyRoot: historyRoot
        )
    }
}
