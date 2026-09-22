import Foundation

/// Claude Code's out-of-band facts. None is anything the tail parsed: the
/// windows come from whichever usage source the user switched on, and the
/// plan, the account and the credits from the CLI's own config file — which is
/// why the last three are readable whether or not the user turned limits on.
///
/// Whichever limits source is answering answers for everything it can, credits
/// included — and answers for them even when its answer is "none". Not a
/// chain of fallbacks: the config file's copy is not a second opinion to fill
/// in behind a live reader. That copy is the
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
    /// What each linked session turned out to be, which is the only place an
    /// account reached through a session alone is named: it has no archived
    /// CLI credential, so the account index holds nothing for it.
    let webLinks: LockedValue<[String: ClaudeWebLink]>
    let profile: ClaudeProfileSource
    /// Who the CLI is signed in as, which is the account the probe's reading
    /// and the config file's identity both belong to. Read from the registry
    /// rather than from `.claude.json`, because only the CLI writes that file
    /// and a switch Sissy made is not in it until some `claude` runs.
    let accounts: ClaudeAccountRegistry

    func currentSignals() -> ProviderSignals {
        let sources = webSources.load()
        let signedIn = accounts.currentSnapshot()
        let file = profile.currentAttributed()
        let active = Self.activeAccount(file, signedIn)
        var reading = Self.merge(
            profile: Self.attributed(file, to: signedIn),
            web: Self.webReading(for: active, among: sources),
            probe: limitsProbe?.currentSignals())
        reading.accounts = Self.perAccount(
            reading, sources: sources, known: signedIn, active: active, links: webLinks.load())
        return reading
    }

    /// Who the row is for: the registry's answer where it has one, and the
    /// config file's own stamp where it has none.
    ///
    /// The registry has none whenever it has never identified a credential —
    /// offline at launch, a keychain that would not answer, an engine built
    /// without one. That used to mean nobody was named at all, and every
    /// judgement below stood down: a lone session was laid over the row
    /// whoever it belonged to, and a `cachedUsageUtilization` stamped with
    /// another account was kept. `.claude.json` names its own owner, so
    /// something is named even then, and it is the CLI's own answer for which
    /// account it is signed in as.
    static func activeAccount(
        _ reading: ClaudeProfileSource.Attributed,
        _ signedIn: ClaudeAccountRegistry.Snapshot
    ) -> String? {
        signedIn.activeUUID ?? reading.profileOwner
    }

    /// The config file's reading, kept only for the account it belongs to.
    ///
    /// `.claude.json` is Claude Code's and only Claude Code writes it, so a
    /// switch Sissy made reaches the keychain at once and that file not at
    /// all — until some `claude` re-fetches its profile. Measured 2026-09-16:
    /// a switch at 16:26:53 left a file rewritten at 16:29:31 whose
    /// `oauthAccount` had been fetched at 12:28:10 and had not moved, so the
    /// row carried one account's id under another account's name, which is
    /// the pairing `ProviderSignals` exists to prevent.
    ///
    /// The file names its own owner, so the reading is attributed rather than
    /// trusted: an identity that contradicts the signed-in account gives way
    /// to the registry's, and credits that contradict it are dropped, because
    /// nothing else on the row can say whose money they were. The two halves
    /// are judged separately for the reason `Attributed` carries two owners.
    ///
    /// Where either uuid is unknown there is no contradiction, and the
    /// reading stands exactly as it always has: an older CLI writes no
    /// `accountUuid`, and a registry that has identified nobody claims no
    /// active account — which is every install that never switched.
    ///
    /// Agreement keeps the file whole rather than substituting anyway: it is
    /// the richer of the two, and the only one of them that names the seat.
    static func attributed(
        _ reading: ClaudeProfileSource.Attributed,
        to signedIn: ClaudeAccountRegistry.Snapshot
    ) -> ProviderSignals {
        var signals = reading.signals
        let active = activeAccount(reading, signedIn)
        if contradicts(reading.profileOwner, active) {
            let identity = signedIn.accounts.first { $0.uuid == active }
            signals.account = identity?.providerAccount
            signals.plan = identity?.plan
            signals.planTier = identity?.planTier
        }
        if contradicts(reading.creditsOwner, active) {
            signals.credits = nil
        }
        return signals
    }

    private static func contradicts(_ owner: String?, _ active: String?) -> Bool {
        guard let owner, let active else { return false }
        return owner != active
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
    /// The exception is an account nobody has named — neither the registry
    /// nor the config file, which is a Mac whose CLI keeps no credential at
    /// all. There a single session is the only answer there is, and no
    /// identity exists for it to contradict. More than one and there is a
    /// choice to get wrong, so it answers with none. The caller passes
    /// `activeAccount`, never the registry's field alone: a file naming its
    /// own owner is a name, and laying another account's session over it is
    /// the pairing this whole type exists to prevent.
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
    ///
    /// `active` is who the caller resolved the signed-in account to be, which
    /// is the registry's answer or the config file's own stamp. Defaulting to
    /// the registry's field keeps a caller that has no file reading — every
    /// test of this rule — saying what it always said.
    ///
    /// The link names an account before the archive does, and this is the one
    /// branch where that is not arbitrary: it draws the accounts the CLI is
    /// *not* on, and an archived identity is frozen at the build that filed
    /// it. Sissy cannot re-ask — `captureActive` only ever reads the active
    /// slot, and an archived access token expires with no refresh Sissy is
    /// allowed to spend — so the link is the only identity a non-active
    /// account can still update. Measured 2026-09-16: an account archived
    /// before `seat` existed kept badging "Team" against a live "Team
    /// Premium", and would have kept it through a fresh link.
    static func perAccount(
        _ reading: ProviderSignals,
        sources: [ClaudeWebSource],
        known: ClaudeAccountRegistry.Snapshot,
        active: String? = nil,
        links: [String: ClaudeWebLink] = [:]
    ) -> [AccountSignals] {
        let signedInUUID = active ?? known.activeUUID
        var byAccount: [String: AccountSignals] = [:]
        if let active = signedInUUID {
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
        for source in sources where source.account != signedInUUID {
            let identity =
                links[source.account]?.identity
                ?? known.accounts.first { $0.uuid == source.account }
            let signals = source.currentSignals()
            byAccount[source.account] = AccountSignals(
                id: source.account,
                account: identity.map(\.providerAccount) ?? signals.account,
                plan: identity?.plan ?? signals.plan,
                planTier: identity?.planTier ?? signals.planTier,
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
    /// answering laid over it.
    ///
    /// A reader that has produced a reading answers; failing that, the one
    /// with something to say about why it has not — a stopped source is
    /// silent, a running one that was refused still has to explain itself,
    /// and the notice is the only way back from most of those states.
    ///
    /// Asking *which* rather than preferring the web source by position is
    /// the older half of the rule: both are constructed at launch whether or
    /// not either runs, so `webSource != nil` answers "was one built", never
    /// "is one reading", and taking it for the second silently took the OAuth
    /// probe's windows off the panel for everyone who had not imported a
    /// session.
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
        guard let live = answering(among: readings) else { return reading }
        reading.windows = live.windows
        reading.limitsState = live.limitsState
        reading.limitsObservedAt = live.limitsObservedAt
        reading.credits = live.credits
        return reading
    }

    /// Which reader the row takes its windows from, given that both of them
    /// run: the engine starts the probe and every session beside it.
    ///
    /// Rank first, and the rank is the CLI's own credential — it is the
    /// vendor's own endpoint, where the session is the fallback for a Mac
    /// that keeps no credential to read. What unseats it is the vendor
    /// refusing it: a reader being told to come back later stops being the
    /// freshest thing on the row the moment the other has a later reading.
    /// Measured 2026-09-17, the probe was refused from 15:15 and the row held
    /// its own 15:12 reading with only its age moving, on an account with a
    /// claude.ai reader polling beside it that could not take the row however
    /// much later its reading was. It is the rule `CodexSignals.merge`
    /// settles its own two sources with, narrowed to the case where rank is
    /// the thing that goes wrong.
    ///
    /// Only readers that have read anything are compared by stamp. One with
    /// nothing read yet cannot be newer than anything, and its state reaching
    /// the row is a separate question the fallback answers. Two readings of
    /// the same moment keep the ranked one, which is rank doing its job.
    private static func answering(among readings: [ProviderSignals]) -> ProviderSignals? {
        let read = readings.filter { $0.limitsObservedAt != nil }
        guard let preferred = read.first else {
            return readings.first { $0.limitsState != .quiet }
        }
        guard case .rateLimited = preferred.limitsState else { return preferred }
        return read.max { ($0.limitsObservedAt ?? .distantPast) < ($1.limitsObservedAt ?? .distantPast) }
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
        webLinks: LockedValue<[String: ClaudeWebLink]>,
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
                limitsProbe: limitsProbe, webSources: webSources, webLinks: webLinks,
                profile: profile, accounts: accounts)
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

    /// The `system` line Claude Code writes when a turn ends, which carries
    /// how long it ran in `durationMs` and bills nothing.
    static let turnDurationSubtype = "turn_duration"
    private static let turnDurationBytes: [UInt8] = Array("\"\(turnDurationSubtype)\"".utf8)
    /// The longest a `turn_duration` line is looked for in. It is a control
    /// line of a dozen fields — measured 2026-09-23 across 2904 of them, 395
    /// to 551 bytes — so the second scan skips the tool results and pasted
    /// files that make up the long lines, which are most of a tree's bytes.
    private static let turnDurationLineLimit = 2048

    /// The tool that spawns a sub-agent, under both names it has had.
    static let agentToolNames: Set<String> = ["Agent", "Task"]

    /// Where Claude Code files a sub-agent's own transcript, beside its
    /// parent's file.
    static let subagentDirectory = "subagents"

    func lineMayCount(_ buf: UnsafePointer<UInt8>, from: Int, to: Int) -> Bool {
        Self.bufferContainsAssistantMarker(buf, from: from, to: to)
            || (to - from <= Self.turnDurationLineLimit
                && Self.bufferContains(buf, from: from, to: to, pattern: Self.turnDurationBytes))
    }

    private static func bufferContains(
        _ buf: UnsafePointer<UInt8>, from: Int, to: Int, pattern: [UInt8]
    ) -> Bool {
        var i = from
        while i <= to - pattern.count {
            if matches(buf, at: i, pattern: pattern) { return true }
            i += 1
        }
        return false
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
    func event(
        from line: SourceLine,
        seen: inout [String: SeenEvent],
        activity: inout [AgentActivityEvent]
    ) -> UsageEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: line.data) as? [String: Any]
        else { return nil }
        if obj["type"] as? String == "system" {
            timeTurn(obj, line: line, into: &activity)
            return nil
        }
        guard obj["type"] as? String == "assistant",
            let msg = obj["message"] as? [String: Any],
            let tsStr = obj["timestamp"] as? String
        else { return nil }

        guard let ts = UsageReaderShared.parseTimestamp(tsStr) else { return nil }

        if ts < line.retainCutoff { return nil }

        let delegated = Self.isSubagentTurn(obj, url: line.url)

        countAgents(in: msg, at: ts, seen: &seen, into: &activity)
        countSession(obj, url: line.url, at: ts, seen: &seen, into: &activity)

        guard let usage = msg["usage"] as? [String: Any],
            let model = msg["model"] as? String
        else { return nil }

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
                model: model, project: project, at: ts, outputTokens: output - already,
                delegated: delegated, effort: obj["effort"] as? String)
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
            cost: cost,
            delegated: delegated,
            effort: obj["effort"] as? String
        )
    }

    /// Whether a sub-agent spent this turn rather than the session itself.
    ///
    /// Two answers because neither covers the history alone, and they are the
    /// same pair `countSession` already reasons about: recent Claude Code
    /// files a sub-agent's transcript under `<session>/subagents/`, and the
    /// line itself carries `isSidechain` on the versions that write the two
    /// into one file. Read off the object the turn was billed from, so it
    /// costs no second parse.
    static func isSubagentTurn(_ object: [String: Any], url: URL) -> Bool {
        if url.deletingLastPathComponent().lastPathComponent == Self.subagentDirectory {
            return true
        }
        return object["isSidechain"] as? Bool == true
    }

    /// Reads how long a turn ran off the line Claude Code writes when it ends.
    ///
    /// Claimed in no ledger, because what it feeds is a maximum: a line read
    /// twice lands on the figure it already set.
    private func timeTurn(
        _ object: [String: Any], line: SourceLine, into activity: inout [AgentActivityEvent]
    ) {
        guard object["subtype"] as? String == Self.turnDurationSubtype,
            let milliseconds = object["durationMs"] as? Int, milliseconds > 0,
            let timestamp = (object["timestamp"] as? String).flatMap(
                UsageReaderShared.parseTimestamp),
            timestamp >= line.retainCutoff
        else { return }
        activity.append(
            AgentActivityEvent(timestamp: timestamp, kind: .turnCompleted(milliseconds: milliseconds)))
    }

    /// Counts the sub-agents an assistant turn spawned.
    ///
    /// The evidence is the `tool_use` block itself, not the transcript the
    /// agent writes. Claude Code files a sub-agent's own log under
    /// `<session>/subagents/agent-*.jsonl`, and counting those files instead
    /// would be both later — the file appears when the agent starts, the block
    /// when the turn that asked for it was written — and narrower, since only
    /// recent versions write them at all. Measured 2026-09-18 across 30 days,
    /// the two agree: 189 blocks against 188 files, the odd one a call that
    /// produced no transcript.
    ///
    /// Two names because the tool was renamed: `Task` is what every version
    /// before the rename wrote, and a reader that knows only the current name
    /// silently reports zero for every day it can still see.
    ///
    /// Keyed on the block's own id rather than on the line's dedup key: Claude
    /// Code rewrites an assistant line two to four times while the answer
    /// streams, and the tool id is what is stable across the copies. It is
    /// claimed in the same ledger the tokens use, so a turn whose copies land
    /// either side of a relaunch still counts one agent.
    private func countAgents(
        in message: [String: Any],
        at timestamp: Date,
        seen: inout [String: SeenEvent],
        into activity: inout [AgentActivityEvent]
    ) {
        guard let content = message["content"] as? [[String: Any]] else { return }
        let day = Calendar.current.startOfDay(for: timestamp)
        for block in content {
            guard block["type"] as? String == "tool_use",
                let name = block["name"] as? String,
                Self.agentToolNames.contains(name),
                let id = block["id"] as? String, !id.isEmpty
            else { continue }
            let key = AgentActivityKey.agent(id)
            guard seen[key] == nil else { continue }
            seen[key] = SeenEvent(day: day, billedOutputTokens: nil)
            activity.append(AgentActivityEvent(timestamp: timestamp, kind: .agentSpawned))
        }
    }

    /// Counts a session the first time one of its turns is read.
    ///
    /// A sub-agent's transcript is not a session: it is the agent already
    /// counted above, and counting it here would report every delegation
    /// twice. The tree says which is which — Claude Code writes a sub-agent's
    /// log into a `subagents` directory beside its parent's file — so the
    /// question is answered by where the line came from rather than by a field
    /// on it, which is also the only answer available on the versions that
    /// wrote no `agentId`.
    ///
    /// Counted at the session's first *turn* rather than at its first line,
    /// because a turn is the only line shape this adapter is handed. What that
    /// makes the number is sessions that got an answer, which is the honest
    /// reading: a `claude` opened and closed without asking anything spent
    /// nothing and did nothing.
    private func countSession(
        _ object: [String: Any],
        url: URL,
        at timestamp: Date,
        seen: inout [String: SeenEvent],
        into activity: inout [AgentActivityEvent]
    ) {
        guard url.deletingLastPathComponent().lastPathComponent != Self.subagentDirectory,
            let sessionID = object["sessionId"] as? String, !sessionID.isEmpty
        else { return }
        let key = AgentActivityKey.session(sessionID)
        guard seen[key] == nil else { return }
        seen[key] = SeenEvent(
            day: Calendar.current.startOfDay(for: timestamp), billedOutputTokens: nil)
        activity.append(AgentActivityEvent(timestamp: timestamp, kind: .sessionStarted))
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
    ///
    /// It names its effort and starts no turn. A copy is the turn already
    /// counted, so only the first sighting of a request id adds to the count —
    /// but the output it carries was spent at the effort the turn was set at,
    /// and a remainder that named none dropped that spend out of the split.
    private func streamedRemainder(
        model: String, project: String?, at timestamp: Date, outputTokens: Int, delegated: Bool,
        effort: String?
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
            ),
            delegated: delegated,
            effort: effort,
            startsTurn: false
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
        webLinks: LockedValue<[String: ClaudeWebLink]> = LockedValue([:]),
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
                webLinks: webLinks,
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
