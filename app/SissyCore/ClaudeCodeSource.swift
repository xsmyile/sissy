import Foundation

/// Claude Code's out-of-band facts. None is anything the tail parsed: the
/// windows come from whichever usage source the user switched on, and the
/// plan, the account and the credits from the CLI's own config file — which is
/// why the last three are readable whether or not the user turned limits on.
///
/// Whichever limits source is running answers for everything it can, credits
/// included — and answers for them even when its answer is "none". Not a
/// chain of fallbacks: exactly one source is running and the config file's
/// copy is not a second opinion to fill in behind it. That copy is the
/// endpoint's reply as of the last time the CLI asked, which is only when the
/// user typed `/usage`, so pairing a live window with it would be two moments
/// on one row — and, measured 2026-09-15, two *accounts* on one row: a config
/// file naming a freshly created account still carried the previous account's
/// spend, in the previous account's currency, because signing in elsewhere
/// does not invalidate the cache. It is the answer when nothing live is
/// running, which is every user who never switched limits on, and never an
/// amendment to one that is.
struct ClaudeCodeSignals: SourceSignals {
    let limitsProbe: ClaudeLimitsProbe?
    /// The claude.ai readers, one per linked account.
    ///
    /// Held behind a `LockedValue` rather than as an array because the set
    /// changes while the adapter lives — a session linked, a session
    /// forgotten — and the adapter's signals object is built once, at
    /// construction. Read nonisolated for the reason everything here is: the
    /// aggregator asks while the emitting provider still holds its actor.
    let webSources: LockedValue<[ClaudeWebSource]>
    let profile: ClaudeProfileSource
    /// Who the CLI is signed in as, which is the account the probe's reading
    /// and the config file's identity both belong to. Read from the registry
    /// rather than from `.claude.json`, because only the CLI writes that file
    /// and a switch Sissy made is not in it until some `claude` runs.
    let accounts: ClaudeAccountRegistry

    func currentSignals() -> ProviderSignals {
        let sources = webSources.load()
        let signedIn = accounts.currentSnapshot()
        var reading = Self.merge(
            profile: profile.currentSignals(),
            web: Self.webReading(for: signedIn.activeUUID, among: sources),
            probe: limitsProbe?.currentSignals())
        reading.accounts = Self.perAccount(
            reading, sources: sources, known: signedIn)
        return reading
    }

    /// The session reading the row itself may show, which is the signed-in
    /// account's or none.
    ///
    /// A session filed under another account is never it. Laying one over the
    /// row puts that account's windows, credits and reading time under the
    /// signed-in account's name and plan — two accounts on one row, which is
    /// the failure `ProviderSignals` exists to prevent and the one #130
    /// measured on the cached copy. An account the CLI is not on is a row of
    /// its own or nothing.
    ///
    /// The exception is an active account Sissy has not identified: with
    /// nobody named there is no identity for a reading to contradict, and a
    /// single session is then the only answer on a Mac whose CLI keeps no
    /// credential at all. More than one and there is a choice to get wrong, so
    /// it answers with none.
    static func webReading(
        for activeUUID: String?, among sources: [ClaudeWebSource]
    ) -> ProviderSignals? {
        guard let activeUUID else {
            return sources.count == 1 ? sources[0].currentSignals() : nil
        }
        return sources.first { $0.account == activeUUID }?.currentSignals()
    }

    /// One entry per account Sissy can read, the signed-in one included.
    ///
    /// Published whatever its count, a lone reading included. Whether a
    /// picker is drawn at all is decided downstream and against a wider set:
    /// the accounts the registry *knows*, which holds every account signed
    /// into on this Mac whether or not a source answers for it. Withholding a
    /// single reading here on the grounds that one account needs no picker
    /// therefore withheld it exactly where a picker was drawn anyway —
    /// measured 2026-09-16, two known accounts and one live source put "no
    /// live source" under the account the CLI was signed into and reading
    /// fine.
    ///
    /// A single-account install is unchanged, because the decision that keeps
    /// it unchanged is the downstream one: one known account and one reading
    /// are one id, and no picker is offered over one choice.
    static func perAccount(
        _ reading: ProviderSignals,
        sources: [ClaudeWebSource],
        known: ClaudeAccountRegistry.Snapshot
    ) -> [AccountSignals] {
        var byAccount: [String: AccountSignals] = [:]
        if let active = known.activeUUID {
            byAccount[active] = AccountSignals(
                id: active,
                account: reading.account,
                plan: reading.plan,
                planTier: reading.planTier,
                windows: reading.windows,
                credits: reading.credits,
                limitsState: reading.limitsState,
                limitsObservedAt: reading.limitsObservedAt,
                isSignedIn: true)
        }
        for source in sources where source.account != known.activeUUID {
            let identity = known.accounts.first { $0.uuid == source.account }
            let signals = source.currentSignals()
            byAccount[source.account] = AccountSignals(
                id: source.account,
                account: identity.map {
                    ProviderAccount(email: $0.email, organization: $0.organization, seat: nil)
                } ?? signals.account,
                plan: identity?.organizationType ?? signals.plan,
                planTier: identity?.rateLimitTier ?? signals.planTier,
                windows: signals.windows,
                credits: signals.credits,
                limitsState: signals.limitsState,
                limitsObservedAt: signals.limitsObservedAt,
                isSignedIn: false)
        }
        return byAccount.values.sorted { lhs, rhs in
            (lhs.isSignedIn ? 0 : 1, lhs.id) < (rhs.isSignedIn ? 0 : 1, rhs.id)
        }
    }

    /// The config file's reading, with whichever limits reader is actually
    /// running laid over it.
    ///
    /// Exactly one reader is: the engine starts one and stops both, and a
    /// stopped one clears its reading and its state. So the answer is the one
    /// that has produced a reading, and failing that the one with something to
    /// say about why it has not — a stopped source is silent, a running one
    /// that was refused still has to explain itself.
    ///
    /// Asking *which* rather than preferring the web source by position is the
    /// whole of it: both are constructed at launch whether or not either runs,
    /// so `webSource != nil` answers "was one built", never "is one reading",
    /// and taking it for the second silently took the OAuth probe's windows
    /// off the panel for everyone who had not imported a session.
    ///
    /// Static and taking its inputs so the rule is testable without two
    /// actors, which is what it was missing when it was wrong.
    static func merge(
        profile: ProviderSignals,
        web: ProviderSignals?,
        probe: ProviderSignals?
    ) -> ProviderSignals {
        var reading = profile
        let readings = [probe, web].compactMap { $0 }
        guard
            let live = readings.first(where: { $0.limitsObservedAt != nil })
                ?? readings.first(where: { $0.limitsState != .quiet })
        else { return reading }
        reading.windows = live.windows
        reading.limitsState = live.limitsState
        reading.limitsObservedAt = live.limitsObservedAt
        reading.credits = live.credits
        return reading
    }
}

/// Claude Code's `~/.claude/projects/**/*.jsonl`: one `assistant` line per
/// streamed chunk of a turn, each carrying the turn's final usage and its own
/// model, deduped by request id.
final class ClaudeCodeAdapter: SourceAdapter {
    let descriptor: SourceDescriptor

    /// Per-model price overrides from `ServerConfig.pricingOverride`. When a
    /// model matches an override entry (exact or longest-prefix) the override
    /// outranks both the runtime catalog and the embedded seed.
    private let pricingOverride: PricingTable?
    /// Anthropic slice of the runtime `PriceCatalog`. Sits between the user's
    /// override and the embedded generated seed, so a model that launched after
    /// this build was cut still prices correctly. Refreshed in place by
    /// `applyPriceCatalog`; a refresh applies to events ingested from then on
    /// and does not reprice accumulated totals.
    private var priceCatalog: PricingTable?
    /// Models already reported as unpriced. Keeps the warning to one line per
    /// model per run instead of one per ingested event.
    private var loggedUnpricedModels: Set<String> = []
    /// Claude Code names the working directory on every assistant line,
    /// so the resolver's cache is what keeps this off the per-line path. The
    /// ledger behind it is the process's, not this adapter's.
    let projects: ProjectResolver
    private let profile: ClaudeProfileSource

    init(
        claudeDir: URL,
        id: String = ProviderID.claudeCode,
        pricingOverride: [String: ModelPricing]?,
        limitsProbe: ClaudeLimitsProbe?,
        webSources: LockedValue<[ClaudeWebSource]>,
        profile: ClaudeProfileSource,
        accounts: ClaudeAccountRegistry,
        ledger: ProjectLedger
    ) {
        self.pricingOverride = pricingOverride.map(PricingTable.init)
        self.profile = profile
        self.projects = ProjectResolver(ledger: ledger)
        self.descriptor = SourceDescriptor(
            id: id,
            root: claudeDir,
            watcherLabel: "sissy.usage.fswatch",
            signals: ClaudeCodeSignals(
                limitsProbe: limitsProbe, webSources: webSources, profile: profile,
                accounts: accounts)
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
    func willRead() { profile.refresh() }

    /// Ahead of the first frame for the same reason `willRead` re-reads it: a
    /// relaunch that resumes from a snapshot emits before any line is parsed,
    /// and the plan is what the panel badges that row with.
    func prepareToStart() -> Bool {
        profile.refresh()
        return false
    }

    /// A refresh on this provider is mostly the keychain and the usage
    /// endpoint, which the engine drives. This is the rest of it: the plan,
    /// the seat and the account all come out of the CLI's config file, and a
    /// user who just changed their plan is exactly who presses the button.
    /// False because none of it is in the snapshot.
    func refreshOutOfBandState() -> Bool {
        profile.refresh(userInitiated: true)
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

        let project = (obj["cwd"] as? String).flatMap { cwd -> String? in
            cwd.isEmpty ? nil : projects.project(for: cwd)
        }

        let output = UsageReaderShared.tokenCount(usage["output_tokens"])
        if let billed = seen[dedupeKey] {
            guard let already = billed.billedOutputTokens, output > already else { return nil }
            seen[dedupeKey]?.billedOutputTokens = output
            return streamedRemainder(
                model: model, project: project, at: ts, outputTokens: output - already)
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
            project: project,
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
    private func streamedRemainder(
        model: String, project: String?, at timestamp: Date, outputTokens: Int
    ) -> UsageEvent {
        UsageEvent(
            timestamp: timestamp,
            model: model,
            project: project,
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
        id: String = ProviderID.claudeCode,
        retainDays: Int = LocalUsageProvider.defaultRetainDays,
        pollInterval: Duration = .seconds(60),
        persistenceURL: URL? = nil,
        historyRoot: URL? = nil,
        pricingOverride: [String: ModelPricing]? = nil,
        limitsProbe: ClaudeLimitsProbe? = nil,
        webSources: LockedValue<[ClaudeWebSource]> = LockedValue([]),
        profile: ClaudeProfileSource = ClaudeProfileSource(),
        accounts: ClaudeAccountRegistry = .inert(),
        ledger: ProjectLedger = ProjectLedger(),
        backfill: Range<Date>? = nil
    ) -> LocalUsageProvider {
        LocalUsageProvider(
            adapter: ClaudeCodeAdapter(
                claudeDir: claudeDir,
                id: id,
                pricingOverride: pricingOverride,
                limitsProbe: limitsProbe,
                webSources: webSources,
                profile: profile,
                accounts: accounts,
                ledger: ledger
            ),
            retainDays: retainDays,
            pollInterval: pollInterval,
            persistenceURL: persistenceURL,
            historyRoot: historyRoot,
            backfill: backfill
        )
    }
}
