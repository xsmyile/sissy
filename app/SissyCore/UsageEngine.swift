import Foundation

/// Meters the CLIs and emits a frame whenever the reading changes.
///
/// Everything Sissy does with usage lives here and nothing about how the
/// reading reaches a screen: the engine is handed a callback and calls it.
/// That is what lets the app run it in-process and the command-line tool run
/// it headless for `--scan`, off one implementation.
actor UsageEngine {
    /// In-memory, mutable mirror of the persisted `ServerConfig`. Runtime
    /// changes update this and call `ServerConfig.save` so the new value
    /// survives a restart.
    private(set) var config: ServerConfig
    let aggregator: UsageAggregator

    private let configURL: URL
    /// Where the archive lives, which is beside the config that named the
    /// trees it was read from — the rule the snapshots already follow.
    private let stateDir: URL
    /// Last archive rollup and when it was taken. The day files are written by
    /// the providers on their own throttle, so the frame re-reads them rather
    /// than being told; the cache is what keeps a burst of frames from turning
    /// into a burst of directory walks.
    private var historyRollup: UsageHistoryRollup?
    private var historyRollupAt: Date = .distantPast
    /// Day the archive was last pruned for. Retention is measured in days, so
    /// the answer changes only when the day does — and a Mac that stays up for
    /// a month has to keep the promise the setting makes without waiting for a
    /// relaunch to enforce it.
    private var lastHistoryPruneDay: Date?
    /// Handle on the aggregator boot Task so `stop()` can cancel an
    /// in-flight cold scan. Without this the engine kept walking
    /// `~/.claude/projects` after everything else had shut down and only
    /// drained when every provider finished its scan organically.
    private var bootTask: Task<Void, Never>?
    /// Watches which Claude Code account is signed in and archives every one
    /// it sees, which is what makes switching back to one possible at all.
    private let claudeAccounts: ClaudeAccountRegistry
    private var claudeAccountsTask: Task<Void, Never>?
    /// Handle on the pricing-catalog refresh loop so `stop()` can cancel an
    /// in-flight fetch instead of leaving it to finish against a torn-down
    /// engine.
    private var priceCatalogTask: Task<Void, Never>?
    /// Whether a provider has produced a reading yet. It is what a config
    /// change re-emits against: before the first one there is nothing to
    /// rebuild, and the change lands on the first real frame instead.
    private var hasReading = false

    /// Polls Claude Code's subscription windows. Constructed unconditionally
    /// so the toggle can start it later without rebuilding the provider list;
    /// it does nothing until `start` is called.
    private let claudeLimitsProbe: ClaudeLimitsProbe
    /// The claude.ai reader. Built whether or not a session is imported —
    /// nothing runs until `startClaudeLimits` finds one — because the adapter
    /// that publishes its reading is assembled once, at launch, and an import
    /// that arrives later must not need a new provider to be seen.
    private let claudeWebSource: ClaudeWebSource
    /// Holds the power assertion. Constructed unconditionally and inert until
    /// asked, like the probe above: an actor nobody has told to hold anything
    /// touches nothing.
    private let keepAwake = KeepAwake()
    /// How long a hold in each mode survives without help.
    private let keepAwakePolicy: KeepAwakePolicy
    /// Whether the Mac is being held awake right now, as opposed to what the
    /// user asked for — which is `config.keepAwake`. They differ when power
    /// management refuses the assertion, and the panel shows both.
    private var keepAwakeActive = false
    /// When the hold in force was taken, and `nil` while nothing is held.
    ///
    /// It belongs to the hold rather than to the call that applied it: a hold
    /// already in force keeps the instant it started from, so what the panel
    /// counts up from is the Mac's, never the last time this ran.
    private var keepAwakeSince: Date?
    /// Whether the screen is being held lit too, as opposed to whether the
    /// user asked for it — which is `config.keepScreenAwake`. Same split as
    /// `keepAwakeActive` draws against the mode, for the same reason.
    private var keepAwakeCoversScreen = false
    /// Which `applyKeepAwake` call currently speaks for the engine. Bumped on
    /// entry so a call that returns to find a newer stamp knows it was
    /// overtaken while suspended.
    private var keepAwakeGeneration = 0
    /// When a turn last landed, which is what `auto` holds the Mac against.
    /// `nil` until one does: an automatic hold begins when the agents do, not
    /// when Sissy launches.
    private var lastAgentActivityAt: Date?
    /// Newest live event any provider has reported, as that provider stamped
    /// it. Held only to tell one turn from the next — the hold itself counts
    /// from when the reading arrived, never from a CLI's own clock.
    private var lastObservedActivityAt: Date?
    /// Wakes when the hold in force is due to end. Owned here so `stop()` has
    /// something to cancel rather than leaving a sleeper against a torn-down
    /// engine.
    private var keepAwakeDeadlineTask: Task<Void, Never>?
    /// Days the panel's archive line covers. A week is what makes "more than
    /// today" legible in a row that has to fit beside the per-provider rows.
    static let historyWindowDays = 7
    /// How long a rollup is reused before the day files are read again. Long
    /// enough that frames do not walk the archive, short enough that the line
    /// is never visibly behind the day it includes.
    private static let historyRollupTTL: TimeInterval = 2

    /// An engine runs once. `stopped` is terminal on purpose: the app builds a
    /// fresh engine when it needs one, so reviving this instance would leave
    /// two of them metering the same trees.
    private enum Lifecycle {
        case idle
        case running
        case stopped
    }

    /// Where this engine is in that sequence.
    ///
    /// `running` is also the answer to "is anyone there to see the reading",
    /// which in one process is the same question: the hold follows it, because
    /// quitting Sissy has to let the Mac sleep again and a hold nobody can see
    /// is a battery complaint with no visible cause. The *mode* is untouched by
    /// this — it is where the user left the switch, and what the hold resumes
    /// from.
    ///
    /// `start()` re-reads this after every suspension. A `stop()` landing in
    /// one of those windows would otherwise be overtaken by the rest of
    /// `start()`, which would boot the aggregator and the refresh loop against
    /// an engine that has already been torn down, with no handle left to
    /// cancel them.
    private var lifecycle: Lifecycle = .idle
    private var onFrame: (@Sendable (FrameData) async -> Void)?

    /// Every provider Sissy knows about, metering or not, with how it was
    /// resolved. Built once in `init` alongside the readers, because the
    /// resolution is what decides which readers exist and there is nothing
    /// left to re-derive it from afterwards.
    private let resolvedProviders: [ResolvedProvider]
    /// The limits reader each additional account owns, keyed by provider id.
    ///
    /// Only the accounts that carry a key are in here: the one that predates
    /// accounts keeps using the shared keychain probe and the imported
    /// claude.ai session, which is where its reading has always come from.
    private let perAccountLimits: [String: ClaudeLimitsProbe]
    /// Whether the account that predates accounts reads a credential of its
    /// own, which is what decides that neither shared source is started.
    /// Nonisolated because Settings words a row from it, and a row that says
    /// Sissy is reading claude.ai while it is reading a file is the kind of
    /// lie this app's settings are not allowed to tell.
    nonisolated let claudeUsesOwnCredential: Bool

    private struct ResolvedProvider {
        let id: String
        let activation: ProviderActivation
        let dataDir: URL
        /// The account this instance reads, so every path it needs comes from
        /// one home and a row can never pair two accounts' readings.
        let account: ResolvedAccount
    }

    init(
        config: ServerConfig,
        configURL: URL = ServerConfig.defaultURL,
        limitsProbe: ClaudeLimitsProbe = ClaudeLimitsProbe(),
        webSource: ClaudeWebSource = ClaudeWebSource(),
        keepAwakePolicy: KeepAwakePolicy = .default
    ) {
        self.config = config
        self.configURL = configURL
        self.keepAwakePolicy = keepAwakePolicy

        // The snapshots live beside the config that named the trees they were
        // read from. `ServerConfig.defaultURL` puts both in the support dir, so
        // the app is unchanged; a config pointed somewhere else — `--config`,
        // a test — takes its reading with it instead of resuming from the
        // install's own and writing a foreign tree back into it.
        let stateDir = configURL.deletingLastPathComponent()
        self.stateDir = stateDir
        // One ledger for every provider, in its own file: what it knows is a
        // reading of the disk rather than token math, so no schema bump that
        // invalidates a tail's snapshot may take it with it.
        let projectLedger = ProjectLedger(url: ProjectLedger.defaultURL(in: stateDir))
        let historyRoot: URL? = config.resolvedHistoryRetentionDays > 0 ? stateDir : nil
        let pollInterval: Duration = .seconds(Int(max(config.pollIntervalSeconds, 1)))
        let claudeHomes = config.resolvedAccounts(vendor: ProviderID.claudeCode)
        let codexAccounts = config.resolvedAccounts(vendor: ProviderID.codex)
        // Claude Code has no detection step: it is the v0.1.0 baseline and an
        // unset toggle leaves it on. Codex is tailed whenever its rollout dir
        // exists — the cold scan is already 48h-bounded, so an idle reader is
        // cheap. The toggle is the vendor's, not an account's: switching a CLI
        // off means Sissy stops reading it, however many accounts of it exist.
        let claudeActivation: ProviderActivation = (config.providers.claudeCode ?? true) ? .on : .off
        self.resolvedProviders =
            claudeHomes.map {
                ResolvedProvider(
                    id: $0.id, activation: claudeActivation, dataDir: $0.dataDir, account: $0)
            }
            + codexAccounts.map { account in
                ResolvedProvider(
                    id: account.id,
                    activation: ProviderActivation.resolve(
                        toggle: config.providers.codex,
                        autoDetected: FileManager.default.fileExists(atPath: account.dataDir.path)
                    ),
                    dataDir: account.dataDir,
                    account: account
                )
            }
        self.claudeLimitsProbe = limitsProbe
        self.claudeWebSource = webSource
        self.claudeAccounts = ClaudeAccountRegistry(
            store: ClaudeAccountStore(indexURL: ClaudeAccountStore.defaultURL(in: stateDir)))
        var limitsSources: [String: ClaudeLimitsProbe] = [:]
        var providers: [any UsageProvider] = []
        for resolved in self.resolvedProviders where resolved.activation.isMetering {
            let account = resolved.account
            switch account.key.vendor {
            case ProviderID.codex:
                providers.append(
                    LocalUsageProvider.codex(
                        codexDir: account.dataDir,
                        id: account.id,
                        pollInterval: pollInterval,
                        persistenceURL: Self.persistenceURL(for: account, in: stateDir),
                        historyRoot: historyRoot,
                        pricingOverride: config.pricingOverride,
                        ledger: projectLedger
                    ))
            default:
                // An account's limits come from its own config home, whichever
                // account it is. The shared keychain item and the imported
                // claude.ai session answer for whoever the CLI and Claude.app
                // are signed into — one account, and not necessarily this one —
                // which is exactly how a row came to pair one account's name
                // with another's windows. They are the fallback for the account
                // that has no home of its own to read, never the first answer.
                let ownProbe: ClaudeLimitsProbe? =
                    if ClaudeFileCredentials.isPresent(at: account.claudeCredentialsURL) {
                        ClaudeLimitsProbe(credentials: { _, _ in
                            ClaudeFileCredentials.load(at: account.claudeCredentialsURL)
                        })
                    } else if account.key.account != nil {
                        // Its credential is somewhere this build cannot
                        // address, and the shared keychain item is the *other*
                        // account's. Saying so is the only honest answer: a
                        // probe reading the shared item here would put the
                        // default account's windows under this account's name,
                        // which is the bug this whole feature removes.
                        ClaudeLimitsProbe(credentials: { _, _ in .unreachable })
                    } else {
                        nil
                    }
                if let ownProbe { limitsSources[account.id] = ownProbe }
                providers.append(
                    LocalUsageProvider.claudeCode(
                        claudeDir: account.dataDir,
                        id: account.id,
                        pollInterval: pollInterval,
                        persistenceURL: Self.persistenceURL(for: account, in: stateDir),
                        historyRoot: historyRoot,
                        pricingOverride: config.pricingOverride,
                        limitsProbe: ownProbe ?? limitsProbe,
                        webSource: ownProbe == nil ? webSource : nil,
                        profile: ClaudeProfileSource(url: account.claudeProfileURL),
                        ledger: projectLedger
                    ))
            }
        }
        self.claudeUsesOwnCredential =
            limitsSources[ProviderKey(vendor: ProviderID.claudeCode).id] != nil
        self.perAccountLimits = limitsSources
        self.aggregator = UsageAggregator(providers: providers)
        let resolution =
            resolvedProviders
            .map { "\($0.id)=\($0.activation.logToken)" }
            .joined(separator: ", ")
        sissyLog("sissy: providers — \(resolution)")
    }

    /// Starts metering. `onFrame` is called for every reading from here on,
    /// including the replays a config change triggers.
    ///
    /// The cold backfill runs in a detached task: on a multi-GB log tree it
    /// takes seconds, and the caller has a surface to put up in the meantime.
    func start(onFrame: @escaping @Sendable (FrameData) async -> Void) async {
        guard lifecycle == .idle else { return }
        lifecycle = .running
        self.onFrame = onFrame
        // Settle on one catalog before the cold scan starts, so the backfill
        // prices historical events against the same rates the live tail will
        // use. A refresh does not reprice what it already counted, so a
        // catalog that lands mid-scan would leave the day split across two
        // rate sets.
        if config.remotePricingEnabled {
            await resolveInitialPriceCatalog()
        } else {
            sissyLog("sissy: remote pricing disabled — using the embedded rate seed")
        }
        guard lifecycle == .running else { return }
        pruneHistoryIfDue(now: Date())
        sissyLog("sissy: claude limits — \(config.claudeLimits ? "on" : "off")")
        // Not for a Claude Code that is switched off: there is no slice for
        // its windows to ride on, so the poll would spend a keychain read — the
        // one thing in Sissy that can raise a system dialog — on a reading
        // nothing could show.
        if config.claudeLimits && meteringClaudeCode {
            await startClaudeLimits(userInitiated: false)
        }
        await applyKeepAwake()
        guard lifecycle == .running else { return }
        let me = self
        startClaudeAccountWatch()
        bootTask = Task.detached { [aggregator] in
            await aggregator.start { today, slices in
                await me.rebuildAndEmit(today: today, slices: slices)
            }
        }
    }

    /// Seeds the account archive from the config homes on this Mac, then keeps
    /// it level with whichever account is signed in.
    ///
    /// The poll is what catches a `/login` or a switch made outside Sissy, and
    /// it is cheap: an unchanged credential costs one `security` call and no
    /// request. Only a token Sissy has not filed buys a round trip to identify
    /// it, which is roughly once per token rotation.
    private func startClaudeAccountWatch() {
        let registry = claudeAccounts
        let homes =
            resolvedProviders
            .filter { $0.account.key.vendor == ProviderID.claudeCode }
            .map(\.account.home)
        claudeAccountsTask = Task.detached {
            await registry.seed(homes: homes)
            while !Task.isCancelled {
                await registry.captureActive()
                do {
                    try await Task.sleep(for: Self.claudeAccountPollInterval)
                } catch {
                    return
                }
            }
        }
    }

    /// How often the active credential is re-read. Long on purpose: a token
    /// rotation is tens of minutes apart, and the only thing a shorter poll
    /// would buy is noticing a switch sooner than the next frame.
    private static let claudeAccountPollInterval: Duration = .seconds(120)

    /// Tears everything down. Idempotent, and safe to land while `start()` is
    /// still suspended — that is what `lifecycle` is re-read for. Terminal: an
    /// engine that has stopped stays stopped.
    func stop() async {
        lifecycle = .stopped
        // Cancel the aggregator boot Task first so the cold scan observes
        // cancellation and bails out of its file enumeration loops before
        // anything else is torn down.
        bootTask?.cancel()
        claudeAccountsTask?.cancel()
        priceCatalogTask?.cancel()
        keepAwakeDeadlineTask?.cancel()
        keepAwakeDeadlineTask = nil
        // Released first, before the awaits below: the kernel drops a dead
        // process's assertions on its own, but `stop()` is also reachable
        // without an exit, and a Mac held awake by something that has shut
        // down is a battery complaint nobody can trace back. Through
        // `applyKeepAwake` rather than by hand, so the release is the one the
        // log records — `lifecycle` is already `stopped`, which is what makes
        // the wanted state false.
        await applyKeepAwake()
        await stopClaudeLimits()
        await aggregator.stop()
        bootTask = nil
        claudeAccountsTask = nil
        priceCatalogTask = nil
    }

    /// Every known provider with how it resolved and, for the ones that are
    /// metering, how far their scan has got. In canonical order.
    func providerReadiness() async -> [ProviderReadiness] {
        let progress = await aggregator.scanProgress()
        return resolvedProviders.map {
            ProviderReadiness(
                id: $0.id,
                label: $0.account.label,
                activation: $0.activation,
                dataDir: $0.dataDir,
                scan: progress[$0.id]
            )
        }
    }

    /// Turn the Claude Code limits on or off and persist the choice. Starting
    /// them is what triggers the one-time keychain prompt, so this is only
    /// ever reached from an explicit user action.
    func setClaudeLimits(enabled: Bool) async {
        guard lifecycle == .running, enabled != config.claudeLimits else { return }
        config.claudeLimits = enabled
        do {
            try ServerConfig.save(config, to: configURL)
        } catch {
            sissyLog(
                "sissy: failed to persist claudeLimits to \(configURL.path): \(error)")
        }
        if enabled {
            await startClaudeLimits(userInitiated: true)
        } else {
            await stopClaudeLimits()
        }
        await reemit()
    }

    /// Imports the claude.ai session Claude.app is holding and switches the
    /// reading over to it.
    ///
    /// The one gesture allowed to raise the Safe Storage dialog, and the only
    /// write on this path. It is deliberately not reachable from a poll or a
    /// launch: a permission is asked for when the user asks for the thing that
    /// needs it.
    func importClaudeWebSession() async -> Result<Void, ClaudeWebCookieImport.Failure> {
        guard lifecycle == .running else { return .success(()) }
        let outcome = await adoptClaudeWebSession(allowingInteraction: true)
        await stopClaudeLimits()
        if config.claudeLimits { await startClaudeLimits(userInitiated: true) }
        await reemit()
        return outcome
    }

    /// Imports and switches over, or says why it could not.
    ///
    /// `allowingInteraction` is the difference between the button and a launch
    /// finding the switch already on. Only the button may raise the Safe
    /// Storage dialog; the launch reads silently and, where the grant is
    /// already given, has the live source running before anyone opens the
    /// panel — which is the whole of "it just works" and costs no prompt.
    private func adoptClaudeWebSession(
        allowingInteraction: Bool
    ) async -> Result<Void, ClaudeWebCookieImport.Failure> {
        switch ClaudeWebCookieImport.session(password: {
            ClaudeWebCookieImport.safeStoragePassword(allowingInteraction: allowingInteraction)
        }) {
        case .failure(let why):
            sissyLog("sissy: importing the claude.ai session found none: \(why)")
            return .failure(why)
        case .success(let session):
            do {
                try ClaudeWebSessionStore.save(session)
            } catch {
                sissyLog("sissy: could not file the claude.ai session: \(error)")
                return .failure(.undecryptable)
            }
            return .success(())
        }
    }

    /// Forgets the imported session and hands the reading back to the OAuth
    /// probe, which is where it was before the import.
    func forgetClaudeWebSession() async {
        guard lifecycle == .running else { return }
        try? ClaudeWebSessionStore.delete()
        await stopClaudeLimits()
        if config.claudeLimits { await startClaudeLimits(userInitiated: false) }
        await reemit()
    }

    /// Makes an account the one Claude Code starts as.
    ///
    /// Safe to write the CLI's slots here precisely because they are not where
    /// the account lives: `ClaudeAccountRegistry` holds Sissy's own copy of
    /// every account it has seen, so whatever this overwrites is still
    /// recoverable in a click. It runs from the panel's own control and from
    /// nothing else.
    func activateClaudeAccount(uuid: String) async -> Result<Void, ClaudeAccountRegistry.Failure> {
        let outcome = await claudeAccounts.activate(uuid: uuid)
        if case .failure(let why) = outcome {
            sissyLog("sissy: could not switch Claude Code to \(uuid): \(why)")
        }
        await reemit()
        return outcome
    }

    /// Every Claude Code account Sissy has archived, and which is signed in.
    ///
    /// Nonisolated because the panel draws the switcher from it while the
    /// registry is busy identifying a credential, and a control that only
    /// appears once a network call has returned is a control nobody finds.
    nonisolated var claudeAccountSnapshot: ClaudeAccountRegistry.Snapshot {
        claudeAccounts.currentSnapshot()
    }

    /// Forgets one archived account, which is the only way a stored secret
    /// leaves this Mac by Sissy's hand.
    func forgetClaudeAccount(uuid: String) async {
        await claudeAccounts.forget(uuid: uuid)
        await reemit()
    }

    /// Whether a claude.ai session is filed. Asked without decrypting one, so
    /// Settings can say so on a build whose grant has lapsed.
    nonisolated var hasClaudeWebSession: Bool { ClaudeWebSessionStore.isPresent() }

    /// What a user pressing refresh on one provider reaches.
    ///
    /// Deliberately one door with two behaviours behind it, because the
    /// action is not the same action: on Claude Code it re-reads the keychain
    /// with the dialog allowed and polls the usage endpoint at once, which is
    /// the second and last gesture permitted to ask for that permission. On
    /// Codex it re-reads `auth.json` — the plan, the account — and nothing
    /// else, because Codex's limits arrive only on the CLI's own events and
    /// no button can make a turn happen.
    ///
    /// The probe is only reached when the setting is on: a refresh must not
    /// be a second way to switch a module on, or the permission would be
    /// asked for by a control that never promised to.
    func refreshProvider(id: String) async {
        guard lifecycle == .running else { return }
        let me = self
        // An account with a credential of its own is refreshed through it,
        // whichever account it is. Nothing here may reach for the shared
        // sources on its behalf: they answer for a different account, and this
        // button is pressed on one row.
        if let own = perAccountLimits[id] {
            await own.refresh { await me.reemit() }
        } else if id == ProviderID.claudeCode, config.claudeLimits {
            if hasClaudeWebSession {
                // A session claude.ai has closed cannot be refreshed into
                // working again, and re-reading the same dead string is the
                // button failing at its only job. The notice beside it says
                // "Import again", so that is what this does.
                if claudeWebSource.currentSignals().limitsState == .sessionExpired {
                    _ = await importClaudeWebSession()
                } else {
                    await claudeWebSource.refresh { await me.reemit() }
                }
            } else {
                await claudeLimitsProbe.refresh { await me.reemit() }
            }
        }
        await aggregator.refreshSignals(for: id)
        await reemit()
    }

    /// Switch the keep-awake mode and persist it, so the choice survives a
    /// restart.
    func setKeepAwake(mode raw: String) async {
        guard let mode = KeepAwakeMode(rawValue: raw), mode != config.keepAwake else { return }
        config.keepAwake = mode
        do {
            try ServerConfig.save(config, to: configURL)
        } catch {
            sissyLog("sissy: failed to persist keepAwake to \(configURL.path): \(error)")
        }
        await applyKeepAwake()
        await reemit()
    }

    /// Switch whether the hold covers the screen and persist it.
    ///
    /// Records the choice. Registering and unregistering the hook itself is
    /// the app's, because it needs the script out of the app bundle — the
    /// engine only owns what `server.json` says.
    func setAgentHooks(enabled: Bool, removalPending: Bool = false) async {
        guard enabled != config.agentHooks || removalPending != config.agentHooksRemovalPending
        else { return }
        config.agentHooks = enabled
        config.agentHooksRemovalPending = removalPending
        do {
            try ServerConfig.save(config, to: configURL)
        } catch {
            sissyLog("sissy: failed to persist agentHooks to \(configURL.path): \(error)")
        }
    }

    /// Applied through the same path as the mode, so flipping it under a
    /// running hold drops or adds the screen half without disturbing the
    /// system assertion underneath.
    func setKeepScreenAwake(enabled: Bool) async {
        guard enabled != config.keepScreenAwake else { return }
        config.keepScreenAwake = enabled
        do {
            try ServerConfig.save(config, to: configURL)
        } catch {
            sissyLog(
                "sissy: failed to persist keepScreenAwake to \(configURL.path): \(error)")
        }
        await applyKeepAwake()
        await reemit()
    }

    /// Whether the Mac should be held right now.
    ///
    /// `on` is the switch and `auto` is the evidence: a hold the agents earn
    /// by working, and lose by going quiet for `idleWindow`. Both die with the
    /// lifecycle, because quitting Sissy has to let the Mac sleep again.
    private var keepAwakeWanted: Bool {
        guard lifecycle == .running else { return false }
        switch config.keepAwake {
        case .off: return false
        case .on: return true
        case .auto: return automaticHoldEarned
        }
    }

    private var automaticHoldEarned: Bool {
        guard let last = lastAgentActivityAt else { return false }
        return Date().timeIntervalSince(last) < keepAwakePolicy.idleWindow
    }

    /// Drives the assertion to whatever the mode, and in `auto` the agents,
    /// ask for.
    ///
    /// Whether this call still speaks for the engine is decided by a
    /// generation stamp rather than by re-reading the decision: a second call
    /// can land while this one is suspended in the `KeepAwake` actor, and the
    /// later one owns both the assertion and the flags — the calls reach the
    /// actor in order, so it is the one that says how the Mac ends up. The
    /// stamp is what makes that test exact under `auto`, where the answer also
    /// changes on its own as the idle window runs out: comparing the decision
    /// instead would let a call that nothing overtook mistake the passing of
    /// time for a newer call, and return leaving an assertion held that no
    /// flag admits to.
    private func applyKeepAwake() async {
        keepAwakeGeneration &+= 1
        let generation = keepAwakeGeneration
        let wanted = keepAwakeWanted
        let hold = await keepAwake.apply(
            holding: wanted, includingScreen: config.keepScreenAwake)
        guard generation == keepAwakeGeneration else { return }
        keepAwakeActive = hold.system && wanted
        keepAwakeCoversScreen = hold.screen && wanted
        keepAwakeSince = keepAwakeActive ? (keepAwakeSince ?? Date()) : nil
        sissyLog(
            "sissy: keep-awake \(config.keepAwake.rawValue) — "
                + (keepAwakeActive ? "holding" : "not holding")
                + (keepAwakeCoversScreen ? ", screen on" : ""))
        rearmKeepAwakeDeadline()
    }

    /// When the hold in force runs out on its own, and `nil` when nothing is
    /// holding or nothing would end it.
    private var keepAwakeDeadline: Date? {
        guard keepAwakeActive, let since = keepAwakeSince else { return nil }
        switch config.keepAwake {
        case .off: return nil
        case .auto: return (lastAgentActivityAt ?? since) + keepAwakePolicy.idleWindow
        case .on: return since + keepAwakePolicy.manualCeiling
        }
    }

    /// Wakes the engine when the hold is due to end.
    ///
    /// A loop rather than a task per emit: `auto` pushes its deadline forward
    /// on every turn that lands, and re-creating this each time would build a
    /// task several times a second while agents work. Waking at the old
    /// deadline and finding it has moved costs one comparison instead.
    private func rearmKeepAwakeDeadline() {
        keepAwakeDeadlineTask?.cancel()
        keepAwakeDeadlineTask = nil
        guard keepAwakeDeadline != nil else { return }
        let me = self
        keepAwakeDeadlineTask = Task {
            while !Task.isCancelled {
                guard let deadline = await me.currentKeepAwakeDeadline() else { return }
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else {
                    await me.keepAwakeDeadlinePassed()
                    return
                }
                try? await Task.sleep(for: .seconds(remaining))
            }
        }
    }

    private func currentKeepAwakeDeadline() -> Date? { keepAwakeDeadline }

    /// What a hold that ran out does about it.
    ///
    /// `auto` simply lets go and says so on the next frame. A manual hold
    /// switches itself off instead of quietly releasing: "on and holding
    /// nothing" already means power management refused the assertion, and a
    /// second cause wearing the same face would leave the panel saying
    /// something that is true of two different Macs. A switch back in the off
    /// position is unambiguous, and clicking it again is one gesture.
    private func keepAwakeDeadlinePassed() async {
        guard lifecycle == .running else { return }
        if config.keepAwake == .on {
            sissyLog("sissy: keep-awake reached its ceiling and switched itself off")
            await setKeepAwake(mode: KeepAwakeMode.off.rawValue)
        } else {
            await applyKeepAwake()
            await reemit()
        }
    }

    /// Records that agents are working, which in `auto` is what earns the
    /// hold.
    ///
    /// A provider stamps an event as live only once its own cold scan has
    /// finished, so what reaches here is a turn that landed while Sissy was
    /// watching rather than a backfill reporting what happened before it was
    /// launched. That distinction cannot be drawn from the day total: the
    /// scan emits its intermediate results, and each of those grew the total
    /// too — which is how a launch on a busy day took a hold with nothing
    /// running. `reemit` and the midnight roll-over reach this path as well,
    /// and neither advances a provider's marker.
    ///
    /// The hold then counts from *now*, not from the stamp: the stamp comes
    /// off a CLI's own log line, whose clock Sissy does not own and whose
    /// precision it does not choose, and an idle window measured against it
    /// would start part-spent on arrival.
    private func noteAgentActivity(_ slices: [ProviderSlice]) {
        guard let latest = slices.compactMap({ $0.signals.lastActivityAt }).max(),
            latest > lastObservedActivityAt ?? .distantPast
        else { return }
        lastObservedActivityAt = latest
        lastAgentActivityAt = Date()
    }

    /// Takes or releases the automatic hold when the agents change the answer.
    ///
    /// Only when the decision actually moves, so the common case — a turn
    /// landing while the hold is already in force — never reaches the
    /// assertion and never suspends the emit that called it.
    private func refreshAutomaticHold() async {
        guard config.keepAwake == .auto, automaticHoldEarned != keepAwakeActive else { return }
        await applyKeepAwake()
    }

    private var meteringClaudeCode: Bool {
        resolvedProviders.contains {
            $0.id == ProviderID.claudeCode && $0.activation.isMetering
        }
    }

    /// `userInitiated` is the difference between someone flipping the switch
    /// and a launch finding it already on. Only the first may raise the
    /// keychain dialog — that is the whole of the rule that a permission is
    /// asked for when the module is switched on and never at boot.
    ///
    /// An imported session decides which reader runs, and exactly one does.
    /// The choice is a stored session rather than a setting because that is
    /// the thing the user actually changed: importing is what says "read it
    /// this way", and forgetting is what takes it back.
    private func startClaudeLimits(userInitiated: Bool) async {
        let me = self
        // An account reading its own credential needs neither of the shared
        // sources, and must not be given one: the imported session is
        // Claude.app's account and the keychain item is the CLI's, so starting
        // either here is how a second account's windows land under the first
        // account's name.
        if !defaultClaudeAccountReadsItsOwnHome {
            // The session is imported rather than asked for. A user who
            // switched limits on has already granted the permission this needs,
            // and making them find a second button in Settings to get the live
            // reading is the switch failing to do what it says.
            if !hasClaudeWebSession {
                _ = await adoptClaudeWebSession(allowingInteraction: userInitiated)
            }
            if hasClaudeWebSession {
                await claudeWebSource.start(userInitiated: userInitiated) { await me.reemit() }
            } else {
                await claudeLimitsProbe.start(userInitiated: userInitiated) { await me.reemit() }
            }
        }
        // Every other account reads a file, so `userInitiated` means nothing
        // to it: there is no dialog to be allowed to raise and no grant to go
        // stale. It polls from the moment the switch is on.
        for probe in perAccountLimits.values {
            await probe.start(userInitiated: false) { await me.reemit() }
        }
    }

    /// Stops both readers. Which one was running is not worth remembering:
    /// stopping one that never started is a no-op, and asking would be a
    /// second place for the answer to be wrong.
    private func stopClaudeLimits() async {
        await claudeLimitsProbe.stop()
        await claudeWebSource.stop()
        for probe in perAccountLimits.values { await probe.stop() }
    }

    /// Whether the account that predates accounts has a credential of its own.
    ///
    /// When it has, nothing on this Mac needs the keychain item or the imported
    /// cookie to read Claude's limits, and neither is started — which also
    /// means no keychain dialog and no session to go stale. When it has not —
    /// a CLI that keeps its token only in the keychain, or one never signed in
    /// — the two shared sources are still the only answer there is.
    private var defaultClaudeAccountReadsItsOwnHome: Bool { claudeUsesOwnCredential }

    /// Where one account's offsets are kept.
    ///
    /// The account that predates accounts keeps the unqualified
    /// `usage-state.json` every install has been writing since 0.1.0: renaming
    /// it would strand those offsets and buy a cold backfill for nothing.
    /// Every other account takes its own file, so a schema change or a
    /// corruption in one cannot cost another its history.
    private static func persistenceURL(for account: ResolvedAccount, in stateDir: URL) -> URL {
        guard account.key.account != nil || account.key.vendor != ProviderID.claudeCode else {
            return UsageStatePersistence.defaultURL(in: stateDir)
        }
        return UsageStatePersistence.forProvider(account.id, in: stateDir)
    }

    /// Rebuild the frame from what the aggregator holds right now, so a
    /// setting the user just changed is visible without waiting for the next
    /// token event. No-op until a provider has produced a reading — the
    /// setting takes effect on the first real frame instead.
    ///
    /// Totals and slices come back from a single hop on purpose. Read
    /// separately they describe two moments: a provider emit landing in the
    /// suspension between them pairs its new scalars with the breakdown from
    /// before it, and that pair is what the frame ships.
    private func reemit() async {
        guard hasReading else { return }
        let reading = await aggregator.currentReading()
        await rebuildAndEmit(today: reading.today, slices: reading.slices)
    }

    private func rebuildAndEmit(
        today: DayTotals,
        slices: [ProviderSlice]
    ) async {
        guard lifecycle == .running else { return }
        hasReading = true
        noteAgentActivity(slices)
        await refreshAutomaticHold()
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let hoursElapsed = max(now.timeIntervalSince(startOfDay) / 3600, 1.0 / 60.0)
        // Slices arrive captured against the same `perProvider` snapshot the
        // aggregator used to compute `today`, whether they came from an emit
        // or from `currentReading()`. Rebuilding them here would race
        // actor reentrancy and could ship a frame whose scalars and breakdown
        // disagree.
        pruneHistoryIfDue(now: now)
        let frame = FrameBuilder.build(
            today: today,
            hoursElapsed: hoursElapsed,
            providers: slices,
            keepAwake: KeepAwakeState(
                mode: config.keepAwake,
                active: keepAwakeActive,
                since: keepAwakeSince,
                coversScreen: keepAwakeCoversScreen),
            history: currentHistory(now: now)
        )
        await onFrame?(frame)
    }

    /// What the archive holds for the last week, cached for a beat.
    ///
    /// Nil when the archive is switched off, and when it is on but empty —
    /// a line saying a week came to nothing is a line about a feature rather
    /// than about usage, so the panel drops it until there is something in it.
    private func currentHistory(now: Date) -> UsageHistoryRollup? {
        guard config.resolvedHistoryRetentionDays > 0 else { return nil }
        let rollup: UsageHistoryRollup
        if let historyRollup, now.timeIntervalSince(historyRollupAt) < Self.historyRollupTTL {
            rollup = historyRollup
        } else {
            rollup = UsageHistoryStore.rollup(days: Self.historyWindowDays, in: stateDir, now: now)
            historyRollup = rollup
            historyRollupAt = now
        }
        return rollup.tokens > 0 ? rollup : nil
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
    private func pruneHistoryIfDue(now: Date) {
        let today = Calendar.current.startOfDay(for: now)
        guard lastHistoryPruneDay != today else { return }
        lastHistoryPruneDay = today
        UsageHistoryStore.prune(
            keeping: config.resolvedHistoryRetentionDays, in: stateDir, now: now)
    }

    /// Deletes the archive, on the one explicit ask there is for it.
    ///
    /// The providers keep counting: what they hold in memory is today, and
    /// today is a day the user has not asked to forget. It reaches disk again
    /// on the next flush, which is why the rollup is invalidated rather than
    /// zeroed — the next frame reads whatever is actually there.
    ///
    /// The providers are told first. Each flushes on its own task, so a flush
    /// landing in the suspension between the two would write a past day back
    /// out after the files were gone, and nothing would remove it again — the
    /// user's deletion would fail with nothing to show for it.
    func deleteHistory() async {
        await aggregator.forgetArchivedDays()
        do {
            try UsageHistoryStore.removeAll(in: stateDir)
            sissyLog("sissy: usage history deleted")
        } catch {
            sissyLog("sissy: failed to delete usage history at \(stateDir.path): \(error)")
        }
        historyRollup = nil
        historyRollupAt = .distantPast
        await reemit()
    }

    /// Picks the rate catalog the cold backfill will run against, then starts
    /// the background refresh loop.
    ///
    /// Order matters: a usable cache is applied synchronously, and when there
    /// is none the first fetch is awaited under a short budget rather than
    /// left to race the backfill. Either way the scan sees one catalog for
    /// its whole run. Falling through to the seed is a deliberate outcome,
    /// not a failure — the refresh loop keeps retrying behind it.
    private func resolveInitialPriceCatalog() async {
        var resolved: PriceCatalog?
        var initialDelay: Duration = .zero
        if let cached = PriceCatalogSource.loadCache() {
            resolved = cached
            let age = Date().timeIntervalSince(cached.fetchedAt)
            initialDelay = PriceCatalogSource.refreshDelay(forCacheAge: age)
            sissyLog("sissy: pricing from cached catalog, \(Int(age / 3600))h old")
        } else if let fetched = await PriceCatalogSource.fetchForColdStart() {
            resolved = fetched
            initialDelay = PriceCatalogSource.refreshInterval
            PriceCatalogSource.saveCache(fetched)
            sissyLog(
                "sissy: pricing catalog fetched before backfill — "
                    + "anthropic=\(fetched.anthropic.count), openai=\(fetched.openai.count)")
        } else {
            sissyLog(
                "sissy: no usable pricing cache and no catalog within "
                    + "\(PriceCatalogSource.coldStartBudget) — backfilling from the embedded "
                    + "seed, refresh continues in the background")
        }
        guard lifecycle == .running else { return }
        if let resolved {
            await aggregator.applyPriceCatalog(resolved)
        }
        let aggregator = self.aggregator
        priceCatalogTask = Task.detached {
            await PriceCatalogSource.refreshLoop(
                initialDelay: initialDelay,
                initialPrevious: resolved
            ) { catalog in
                await aggregator.applyPriceCatalog(catalog)
            }
        }
    }
}
