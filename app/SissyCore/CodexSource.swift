import Foundation

/// Codex's `~/.codex/sessions/**/rollout-*.jsonl`. Codex rolls one JSONL per
/// session; each `event_msg` of type `token_count` carries a
/// `last_token_usage` block which is the *per-turn delta* (verified on real
/// data: summing `last_token_usage` across events in a file equals the final
/// `total_token_usage` cumulative). That makes the ingest path materially
/// simpler than the cumulative-delta dance the OpenAI docs suggest.
///
/// Model id lives in `turn_context.payload.model`, carried per-file. Falls
/// back to `"gpt-5-codex"` when absent so pricing still resolves.
///
/// Windows, plan and account are published through one lock box the adapter
/// writes from inside the provider's actor, so the aggregator can read all of
/// them together without an actor hop.
final class CodexAdapter: SourceAdapter {
    let descriptor: SourceDescriptor

    private let codexDir: URL
    private let pricingOverride: PricingTable?
    /// OpenAI slice of the runtime `PriceCatalog`. See the twin property on
    /// `ClaudeCodeAdapter` for the precedence rationale.
    private var priceCatalog: PricingTable?
    private var loggedUnpricedModels: Set<String> = []

    /// Rate-limit buckets Codex ships on a `token_count` event. Position is
    /// not meaning: each bucket carries its own `window_minutes`.
    private static let rateLimitBuckets = ["primary", "secondary"]

    /// Locale the vendor's own numbers are read against. A balance arrives as
    /// text and `Decimal(string:)` takes the machine's separator, which on this
    /// one is a comma — left to it, `"12.5"` parses as `12`.
    private static let vendorLocale = Locale(identifier: "en_US_POSIX")

    /// Everything this adapter answers for besides tokens: the windows, the
    /// plan Codex names on the same `rate_limits` block as them, and the
    /// account `auth.json` names. One box because the three are read together
    /// and a row pairing one turn's plan with another's windows is a reading
    /// that never existed.
    private let published = LockedValue(ProviderSignals())
    /// The event timestamp the published windows came from. A cold scan walks
    /// files in no particular order, so an older rollout must not overwrite a
    /// fresher window.
    private var latestWindowsAt: Date?

    /// Digest of the identity claims `auth.json` last named, persisted so a
    /// relaunch can still tell "the same account" from "a different one". It
    /// is a digest rather than the claims because nothing but the plan token
    /// may leave that file.
    private var accountFingerprint: String?
    /// Whether `auth.json` has ever been read successfully. Separates an
    /// install that never had one — a log-only Codex — from an account that
    /// has just been signed out, which is a reading and clears the row.
    private var hasReadAuth = false
    /// When the signed-in identity last changed. Windows stamped before it
    /// belong to the account that left, and a cold scan re-reading old
    /// rollouts must not publish them under the new one.
    private var identityBoundaryAt: Date?

    /// How long after a session's own start a `token_count` may still be one
    /// of the turns it copied from its parent.
    ///
    /// A fork writes its parent's history in one burst at creation, every
    /// event stamped within a millisecond or two of the session's start; a
    /// turn the session actually ran takes seconds to come back. Measured
    /// across a year of rollouts, anything from 50 ms to 3 s separates the two
    /// exactly, so this sits in the middle of a band rather than on its edge.
    /// It is also the pause ccusage uses to tell the same two apart.
    private static let replayedTurnWindow: TimeInterval = 1

    /// Codex's own running total as of the last `token_count` read from each
    /// rollout. What tells a re-emitted turn from a new one: Codex writes a
    /// final `token_count` repeating the previous turn's `last_token_usage`
    /// verbatim, and only this staying put says the turn was already counted.
    private var fileCumulative: [URL: UsageStateSnapshot.CodexCumulative] = [:]

    /// Where each rollout is in replaying the turns it copied from a parent.
    private var fileReplay: [URL: ReplayHead] = [:]

    /// Whether a rollout is still reading turns it did not spend.
    private enum ReplayHead {
        /// The session named a parent and has not yet reached its own first
        /// turn. Holds the instant of the last copied turn, so the run is
        /// followed from one event to the next rather than from a fixed
        /// deadline — a long history still lands inside the window.
        case copying(through: Date)
        /// The session named no parent, or its copied turns are behind us.
        case counting
    }

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
    /// Rollouts another thread opened, so every turn they spend counts as a
    /// sub-agent's.
    ///
    /// Per file and persisted for the reason the two above are: Codex answers
    /// it once, on the `session_meta` a resumed reader is already past, and a
    /// reader that had forgotten would report a spawned rollout's whole day as
    /// the session's own work.
    private var fileSubagents: Set<URL> = []
    /// The ledger behind it is the process's, not this adapter's: none of the
    /// directories a Codex rollout names is a repository on its own, so every
    /// checkout this resolver can recognise was read by another provider.
    let projects: ProjectResolver

    /// Default model id used when a rollout's `turn_context` never named one
    /// (older Codex versions wrote `model_provider` but no `model`). Matches
    /// what ccusage falls back to for the same reason.
    static let defaultModel = "gpt-5-codex"

    init(
        codexDir: URL,
        id: String = ProviderID.codex,
        pricingOverride: [String: ModelPricing]?,
        usageSources: LockedValue<[CodexUsageSource]> = LockedValue([]),
        usageLinks: LockedValue<[String: CodexAccountLink]> = LockedValue([:]),
        ledger: ProjectLedger
    ) {
        self.projects = ProjectResolver(ledger: ledger)
        self.codexDir = codexDir
        self.pricingOverride = pricingOverride.map(PricingTable.init)
        self.descriptor = SourceDescriptor(
            id: id,
            root: codexDir,
            watcherLabel: "sissy.codex.fswatch",
            signals: CodexSignals(
                rollout: published, sources: usageSources, links: usageLinks)
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
    /// nothing has named one yet.
    ///
    /// Without this a resumed reader shows the Codex row with no plan: the
    /// offsets are at EOF, `plan_type` rides events that were already
    /// consumed, and the badge waits on the user's next turn. The auth file
    /// answers immediately, and the first rollout event that lands overwrites
    /// it — the CLI restamps the claim per turn, this file only on a token
    /// refresh.
    func prepareToStart() -> Bool { readAuthFile(userInitiated: false) }

    /// The same read, on demand. Codex's *limits* cannot be refreshed at all —
    /// they ride the CLI's own `token_count` events and a reader at EOF has
    /// nothing left to re-read — so this is the whole of what a refresh on
    /// this provider can honestly do, and the surface has to say so.
    ///
    /// A user asking also lets the file's plan claim win over the one the last
    /// turn published: that is the gesture someone makes after switching plan,
    /// and the alternative is a badge that stays wrong until the next turn.
    func refreshOutOfBandState() -> Bool { readAuthFile(userInitiated: true) }

    /// Reads `auth.json` and republishes the identity it names.
    ///
    /// Four outcomes, and only two of them are answers. A file that will not
    /// parse leaves everything as it was — a half-written file is not a
    /// logout. A file that is simply absent is a logout only once one has been
    /// read before; on a machine that never had one it is a Codex used through
    /// an API key, which has no account to show. A signed-out or key-mode file
    /// clears the row, and a *demonstrably different* account clears the
    /// windows with it, because a percentage metered against somebody else's
    /// plan is worse than no gauge at all.
    ///
    /// Returns whether the next snapshot has something new to carry.
    private func readAuthFile(userInitiated: Bool) -> Bool {
        let before = published.load()
        let previousFingerprint = accountFingerprint
        let url = CodexAuthSource.defaultURL(sessionsDir: codexDir)
        switch CodexAuthSource.read(at: url) {
        case .unreadable:
            return false
        case .missing where !hasReadAuth && accountFingerprint == nil:
            // A log-only install may never have had a local auth file.
            return false
        case .missing, .signedOut:
            published.store(ProviderSignals())
            latestWindowsAt = nil
            accountFingerprint = nil
            identityBoundaryAt = Date()
        case .found(let identity):
            // A token that named none of the claims says nothing about whose
            // it is, which is not the same as saying it is somebody else's.
            // Only two identities that are both known and different are a
            // change; an unknown one leaves the last known reading standing,
            // for the reason the project ledger keeps a checkout it can no
            // longer walk to — remembering a reading is not inventing one.
            let changedAccount =
                identity.fingerprint != nil && accountFingerprint != nil
                && accountFingerprint != identity.fingerprint
            if changedAccount {
                published.store(ProviderSignals())
                latestWindowsAt = nil
                identityBoundaryAt = Date()
            }
            published.update {
                $0.account = identity.account
                if userInitiated || changedAccount || $0.plan == nil { $0.plan = identity.plan }
            }
            if let fingerprint = identity.fingerprint { accountFingerprint = fingerprint }
        }
        hasReadAuth = true
        let after = published.load()
        return before.plan != after.plan || before.windows != after.windows
            || previousFingerprint != accountFingerprint
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
    /// the per-file model state, `session_meta` names the working directory,
    /// and `event_msg/token_count` lines produce a billable `UsageEvent`. Any
    /// other shape is silently dropped.
    ///
    /// One parse, then a switch: the three shapes used to be tried in turn, so
    /// a `turn_context` line paid for a `token_count` parse before its own.
    func event(
        from line: SourceLine,
        seen: inout [String: SeenEvent],
        activity: inout [AgentActivityEvent]
    ) -> UsageEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: line.data) as? [String: Any]
        else { return nil }
        switch object["type"] as? String {
        case "event_msg": return parseTokenCount(object, line: line, seen: &seen)
        case "turn_context": applyTurnContext(object, url: line.url)
        case "session_meta":
            applySessionMeta(object, url: line.url)
            countRollout(object, line: line, seen: &seen, into: &activity)
        default: break
        }
        return nil
    }

    /// Counts a rollout as either a session somebody started or an agent
    /// something spawned.
    ///
    /// Codex opens a file per thread, so the count is one per rollout and the
    /// only question is which of the two it was. **Three shapes answer it, and
    /// a reader that knows one of them reports zero for most of the history.**
    /// Measured 2026-09-18 over 468 rollouts: `source.subagent.thread_spawn`
    /// names 26, `source.subagent: "review"` names 119, and `thread_source`
    /// names 58 on versions that wrote no `source` at all.
    ///
    /// Deliberately not `namesAParentSession`, which is the other question
    /// about the same field. That one decides whether a rollout opens by
    /// replaying turns it did not spend, and it must stay narrow: measured the
    /// same day, a `review` subagent's first `token_count` lands 0.09 s after
    /// its `session_meta` and is a real turn, so widening that gate to match
    /// this one would take 119 genuine turns off the day. Both readings are
    /// right; they are not the same reading.
    ///
    /// **The rollout is keyed by its file, because its payload names its
    /// parent.** Measured 2026-09-18: a spawned rollout's `session_id` *and*
    /// `id` both carry the thread that spawned it — the file
    /// `…-5b9c-…7ff22e641ba9.jsonl` says `01a0b4b9-5b2f-…b160b379ae16`, which
    /// is the user session sitting beside it — so a ledger keyed on either
    /// field has the parent's key already claimed and drops every agent it
    /// spawned. It cost all 8 of that day's agents, silently, against a unit
    /// test that passed: the fixture had been written with an id of its own,
    /// which is a line Codex does not write. A rollout is one file, so the
    /// file name is the identity, and it is unique by construction — the name
    /// carries the thread's own uuid.
    private func countRollout(
        _ object: [String: Any],
        line: SourceLine,
        seen: inout [String: SeenEvent],
        into activity: inout [AgentActivityEvent]
    ) {
        guard let payload = object["payload"] as? [String: Any],
            let timestamp = (object["timestamp"] as? String).flatMap(
                UsageReaderShared.parseTimestamp),
            timestamp >= line.retainCutoff
        else { return }
        let key = AgentActivityKey.session(line.url.lastPathComponent)
        guard seen[key] == nil else { return }
        seen[key] = SeenEvent(
            day: Calendar.current.startOfDay(for: timestamp), billedOutputTokens: nil)
        activity.append(
            AgentActivityEvent(
                timestamp: timestamp,
                kind: Self.isSubagent(payload) ? .agentSpawned : .sessionStarted))
    }

    /// Whether a rollout was opened by another thread rather than by a person.
    static func isSubagent(_ payload: [String: Any]) -> Bool {
        if let source = payload["source"] as? [String: Any], source["subagent"] != nil {
            return true
        }
        return payload["thread_source"] as? String == "subagent"
    }

    /// Records what a rollout's `session_meta` line says about itself: the
    /// project it runs in, whether git could name that project at all, and
    /// whether the session opens by replaying a parent's turns.
    private func applySessionMeta(_ obj: [String: Any], url: URL) {
        guard let payload = obj["payload"] as? [String: Any] else { return }
        if Self.isSubagent(payload) { fileSubagents.insert(url) }
        if Self.namesAParentSession(payload),
            let start = (obj["timestamp"] as? String).flatMap(UsageReaderShared.parseTimestamp)
        {
            fileReplay[url] = .copying(through: start)
        }
        guard let cwd = payload["cwd"] as? String, !cwd.isEmpty,
            !Self.runsWhereGitNamesNothing(payload),
            let project = projects.project(for: cwd)
        else { return }
        fileProjects[url] = project
    }

    /// Whether the session ran in a directory git answered for and could say
    /// nothing about.
    ///
    /// Codex writes a git block on the rollout's first line, and the walk
    /// behind it is the same one `ProjectResolver` does: no `.git` entry above
    /// the working directory and the block is absent entirely, which is the
    /// case the resolver already answers nothing for. Where there is one, the
    /// block carries the commit, the branch and the origin url git could read,
    /// each left out when git refused it — so an empty block is a directory
    /// that is a repository and about which git could name neither a commit,
    /// nor a branch, nor a remote. That is a `git init` nobody has committed
    /// to: an agent's sandbox root rather than a project. Measured 2026-09-18
    /// across 450 rollouts, exactly one, and it had taken a $1.26 row named
    /// after a scratch directory inside another CLI's own working area.
    ///
    /// The gate sits in front of the resolver rather than after it because
    /// that call is also what writes the directory into `ProjectLedger`: a row
    /// remembered there outlives the sandbox it was read from, which is the
    /// whole point of remembering one and exactly wrong here.
    ///
    /// The spend is counted and only the row is denied, which is what a
    /// working directory in no repository already gets. What it costs is the
    /// first session of a genuinely new project, unattributed until its first
    /// commit — the block is written once at startup and never refreshed,
    /// measured 2026-09-18 on a session that committed and then resumed. An
    /// orphan branch on a repository with no remote reads the same way, and so
    /// does a repository slow enough that every one of Codex's git calls
    /// reaches its own five-second timeout.
    private static func runsWhereGitNamesNothing(_ payload: [String: Any]) -> Bool {
        guard let git = payload["git"] as? [String: Any] else { return false }
        return git.isEmpty
    }

    /// Whether this session was opened from another one, and therefore starts
    /// by writing that one's turns into its own log.
    ///
    /// Two shapes, because Codex has two ways of doing it: a conversation the
    /// user forked names `forked_from_id`, and a subagent Codex spawned names
    /// its `parent_thread_id`. Both sit in the session's own first line, which
    /// is what keeps this a per-file question — the alternative is reading the
    /// parent's rollout to recognise the copy, and a tail that opens a second
    /// file to understand the one in front of it is a different design.
    static func namesAParentSession(_ payload: [String: Any]) -> Bool {
        if payload["forked_from_id"] is String { return true }
        guard let source = payload["source"] as? [String: Any],
            let subagent = source["subagent"] as? [String: Any],
            let spawn = subagent["thread_spawn"] as? [String: Any]
        else { return false }
        return spawn["parent_thread_id"] is String
    }

    /// Updates per-file model from a `turn_context` line. Idempotent; called
    /// from the streaming reader before any subsequent `token_count` event.
    private func applyTurnContext(_ obj: [String: Any], url: URL) {
        guard let payload = obj["payload"] as? [String: Any],
            let model = payload["model"] as? String,
            !model.isEmpty
        else { return }
        fileModels[url] = model
    }

    /// Whether this event is one of the turns the session copied from its
    /// parent, and not one it spent.
    ///
    /// A fork's log opens with its parent's whole history, written in one
    /// burst at creation and stamped accordingly. Billing it charged the user
    /// twice for turns they had already paid for once — measured at 12% of one
    /// month, because a session forked three times replays the same history
    /// three more times.
    private func isCopiedFromAParent(at timestamp: Date, in url: URL) -> Bool {
        guard case .copying(let through) = fileReplay[url] ?? .counting else { return false }
        let sinceLastCopy = timestamp.timeIntervalSince(through)
        guard sinceLastCopy >= 0, sinceLastCopy <= Self.replayedTurnWindow else {
            fileReplay[url] = .counting
            return false
        }
        fileReplay[url] = .copying(through: timestamp)
        return true
    }

    /// Whether Codex's own running total moved, and records where it now is.
    ///
    /// The authority on whether a `token_count` carries anything new. Codex
    /// re-emits the previous turn's `last_token_usage` verbatim — at the end
    /// of a session, and after an interruption — while leaving this untouched,
    /// and a reader that trusts the per-turn block alone bills that turn
    /// twice. An event that reports no total at all is taken at its word;
    /// every rollout measured carries one.
    private func advanceCumulative(_ raw: Any?, in url: URL) -> Bool {
        guard let dict = raw as? [String: Any] else { return true }
        let reported = UsageStateSnapshot.CodexCumulative(
            input: UsageReaderShared.tokenCount(dict["input_tokens"]),
            cached: UsageReaderShared.tokenCount(dict["cached_input_tokens"]),
            output: UsageReaderShared.tokenCount(dict["output_tokens"]),
            total: UsageReaderShared.tokenCount(dict["total_tokens"])
        )
        defer { fileCumulative[url] = reported }
        return fileCumulative[url] != reported
    }

    private func captureWindows(_ raw: Any?, observedAt: Date) {
        guard let dict = raw as? [String: Any] else { return }
        if let boundary = identityBoundaryAt, observedAt < boundary { return }
        if let seen = latestWindowsAt, seen >= observedAt { return }
        // Ahead of the window parse and outside its `isEmpty` bail: a rollout
        // whose buckets did not parse still named the plan, and the plan is
        // what the panel puts next to the provider whether or not there are
        // gauges under it.
        if let plan = UsageReaderShared.sanitizedPlanToken(dict["plan_type"] as? String) {
            published.update { $0.plan = plan }
        }
        if let credits = Self.credits(dict["credits"], observedAt: observedAt) {
            published.update { $0.credits = credits }
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
        published.update {
            $0.windows = windows
            $0.limitsObservedAt = observedAt
        }
        latestWindowsAt = observedAt
    }

    /// The credit balance Codex writes on the same `rate_limits` block as the
    /// windows and the plan.
    ///
    /// Balance only: OpenAI names no spend and, measured across 10 306 blocks
    /// on one machine, sends `individual_limit: null` on every one of them, so
    /// there is no ceiling to draw a bar against and the row is a line.
    ///
    /// The two ways this reading goes missing are two different facts and
    /// neither is zero, which is why each answers nil rather than a figure:
    /// the key is absent on a Codex older than 2026-05-18, and `balance` is
    /// null where the CLI has the key and not the number.
    ///
    /// Neither of the flags beside it is read, and both omissions are
    /// deliberate. `has_credits` reports whether a finite pool exists rather
    /// than whether the facility is switched off, so folding it into
    /// `isEnabled` would hide the confirmed zero that is the ordinary reading
    /// on an account that never bought any. `unlimited` says nothing about a
    /// figure the vendor did send: it only means an *absent* balance is not
    /// worth reporting as missing, which is already what happens, since a
    /// balance that does not parse answers nil on its own. Suppressing a
    /// figure on the strength of it was inventing an absence — the same rule
    /// as "no reading is not a reading of zero", read the other way round.
    static func credits(_ raw: Any?, observedAt: Date) -> ProviderCredits? {
        guard let dict = raw as? [String: Any],
            let balanceMinor = creditsMinor(dict["balance"])
        else { return nil }
        return ProviderCredits(
            isEnabled: true,
            unit: .credits,
            usedMinor: nil,
            capMinor: nil,
            observedAt: observedAt,
            balanceMinor: balanceMinor
        )
    }

    /// A credit balance in the minor units `CreditsUnit.credits` counts in.
    ///
    /// The vendor spells it as a string (`"0"`), so the text is checked for
    /// the shape of a non-negative decimal before it is parsed: `Decimal` reads
    /// as far as it understands and answers with what it got, which turns
    /// `"12 credits"` into `12` rather than into nothing. That check is the
    /// only guard there is — it admits digits and one point and nothing else,
    /// so a sign never reaches the parse and a second test for one would be
    /// dead code posing as a safety net.
    private static func creditsMinor(_ raw: Any?) -> Int? {
        let text: String
        switch raw {
        case let value as String: text = value
        case let value as NSNumber: text = value.stringValue
        default: return nil
        }
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
            text.filter({ $0 == "." }).count <= 1,
            var parsed = Decimal(string: text, locale: vendorLocale)
        else { return nil }
        var scaled = Decimal()
        NSDecimalMultiplyByPowerOf10(&scaled, &parsed, Int16(CreditsUnit.credits.exponent), .plain)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return Int(exactly: NSDecimalNumber(decimal: rounded))
    }

    /// Parses a `token_count` event line. Returns nil for any non-billable
    /// shape, dedup hit, or event outside the retain window.
    private func parseTokenCount(_ obj: [String: Any], line: SourceLine, seen: inout [String: SeenEvent])
        -> UsageEvent?
    {
        guard let payload = obj["payload"] as? [String: Any],
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

        // Both guards below run before the retain cutoff and before the
        // dedup ledger, and the bookkeeping they keep is updated for every
        // event whether or not it is billed: an event dropped for being too
        // old is still the one the next event's total has to be compared
        // against, and still the one that carries a copied run forward.
        let copied = isCopiedFromAParent(at: ts, in: line.url)
        let advanced = advanceCumulative(info["total_token_usage"], in: line.url)
        if copied || !advanced { return nil }

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
        // sub-breakdown of it rather than an additive counter, so nothing
        // reads it. ccusage uses `output_tokens` alone for the same reason.

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
            cost: cost,
            delegated: fileSubagents.contains(line.url)
        )
    }

    /// `fileModels` goes with the offsets and mtimes: it is keyed the same way
    /// and is what prices a resumed file, so an entry outliving its offset
    /// would be a model map for a file nothing reads.
    func trim(retaining files: Set<URL>) {
        fileModels = fileModels.filter { files.contains($0.key) }
        fileProjects = fileProjects.filter { files.contains($0.key) }
        fileCumulative = fileCumulative.filter { files.contains($0.key) }
        fileReplay = fileReplay.filter { files.contains($0.key) }
        fileSubagents = fileSubagents.filter { files.contains($0) }
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
            fileCumulative[fileURL] = entry.cumulative
            if entry.subagent == true { fileSubagents.insert(fileURL) }
            if let through = entry.copyingThrough { fileReplay[fileURL] = .copying(through: through) }
        }
        accountFingerprint = resume.accountFingerprint
        published.update {
            $0.plan = resume.plan
            $0.credits = resume.credits
        }
        guard !resume.rateLimitWindows.isEmpty else { return true }
        published.update {
            $0.windows = resume.rateLimitWindows
            $0.limitsObservedAt = resume.rateLimitWindowsAt
        }
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
            fileModels: Set(fileModels.keys).union(fileProjects.keys)
                .union(fileCumulative.keys).union(fileReplay.keys).union(fileSubagents)
                .map { url in
                    UsageStateSnapshot.FileModel(
                        path: url.path,
                        model: fileModels[url] ?? Self.defaultModel,
                        project: fileProjects[url],
                        cumulative: fileCumulative[url],
                        copyingThrough: {
                            guard case .copying(let through) = fileReplay[url] ?? .counting
                            else { return nil }
                            return through
                        }(),
                        subagent: fileSubagents.contains(url) ? true : nil
                    )
                },
            rateLimitWindows: published.load().windows,
            rateLimitWindowsAt: latestWindowsAt,
            plan: published.load().plan,
            accountFingerprint: accountFingerprint,
            credits: published.load().credits
        )
    }
}

extension LocalUsageProvider {
    /// Codex's tail.
    static func codex(
        codexDir: URL = CodexAdapter.defaultDir(),
        id: String = ProviderID.codex,
        retainDays: Int = LocalUsageProvider.defaultRetainDays,
        pollInterval: Duration = .seconds(60),
        persistenceURL: URL? = nil,
        historyRoot: URL? = nil,
        pricingOverride: [String: ModelPricing]? = nil,
        usageSources: LockedValue<[CodexUsageSource]> = LockedValue([]),
        usageLinks: LockedValue<[String: CodexAccountLink]> = LockedValue([:]),
        ledger: ProjectLedger = ProjectLedger(),
        backfill: Range<Date>? = nil
    ) -> LocalUsageProvider {
        LocalUsageProvider(
            adapter: CodexAdapter(
                codexDir: codexDir, id: id, pricingOverride: pricingOverride,
                usageSources: usageSources, usageLinks: usageLinks, ledger: ledger),
            retainDays: retainDays,
            pollInterval: pollInterval,
            persistenceURL: persistenceURL,
            historyRoot: historyRoot,
            backfill: backfill
        )
    }
}
