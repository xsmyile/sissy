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
    /// False when `server.json` was there at launch and would not parse, so
    /// this run's changes stay in memory rather than replacing the user's
    /// file with the defaults they were made on top of.
    private let configIsWritable: Bool
    /// Where the archive lives, which is beside the config that named the
    /// trees it was read from — the rule the snapshots already follow.
    private let stateDir: URL
    /// Last archive rollups and when they were taken. The day files are written
    /// by the providers on their own throttle, so the frame re-reads them rather
    /// than being told; the cache is what keeps a burst of frames from turning
    /// into a burst of directory walks.
    private var historyRollups: [UsagePeriod: UsageHistoryRollup] = [:]
    private var historyRollupAt: Date = .distantPast
    /// The one checkout memory every provider shares, kept because the export
    /// re-reads the archive's project paths through a resolver built on it.
    /// A second ledger over the same file would be a second writer to it.
    private let projectLedger: ProjectLedger
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
    private var claudeWebAdoptionTask: Task<Void, Never>?
    /// Handle on the pricing-catalog refresh loop so `stop()` can cancel an
    /// in-flight fetch instead of leaving it to finish against a torn-down
    /// engine.
    private var priceCatalogTask: Task<Void, Never>?
    /// Handle on the one-time archive backfill, for the same reason: it is a
    /// read of the whole log tree and a quit has to interrupt it rather than
    /// wait for it.
    private var backfillTask: Task<Void, Never>?
    /// The catalog the cold scan settled on, kept so the archive backfill
    /// prices historical events against exactly the rates the tail used. Nil
    /// is the embedded seed, which is a rate source rather than a failure.
    private var initialPriceCatalog: PriceCatalog?
    /// The rates a reading taken after the events is priced at — the cache
    /// saving, today's and the archive's — kept in step with every catalog
    /// the readers are handed.
    private var pricing: ProviderPricing
    /// Whether a provider has produced a reading yet. It is what a config
    /// change re-emits against: before the first one there is nothing to
    /// rebuild, and the change lands on the first real frame instead.
    private var hasReading = false

    /// The config home Claude Code is metered from, kept because the account
    /// registry and the credential both address that home rather than the
    /// default one.
    private let claudeHome: ProviderHome
    /// The claude.ai reader. Built whether or not a session is imported —
    /// nothing runs until `startClaudeLimits` finds one — because the adapter
    /// that publishes its reading is assembled once, at launch, and an import
    /// that arrives later must not need a new provider to be seen.
    /// One reader per linked claude.ai session, shared with the adapter's
    /// signals so both see the same set the moment it changes.
    private let claudeWebSources = LockedValue<[ClaudeWebSource]>([])
    /// What each linked session is, read once at launch and republished
    /// whenever a link changes. A `LockedValue` for the reason the sources
    /// are: the adapter's signals read it while the emitting provider still
    /// holds its actor.
    private let claudeWebLinks = LockedValue<[String: ClaudeWebLink]>([:])
    private let claudeWebIndex: ClaudeWebSessionIndex
    /// One usage reader per Codex credential, shared with the adapter's
    /// signals so both see the same set the moment it changes.
    ///
    /// The first entry is the CLI's own credential, built whenever Codex is
    /// metered: that file is there on every Mac that has signed into `codex`,
    /// it needs no permission Sissy has to ask for, and without it the row's
    /// gauges are only ever as fresh as the last turn.
    private let codexSources = LockedValue<[CodexUsageSource]>([])
    /// What each linked Codex credential turned out to be, read once at launch
    /// and republished whenever a link changes.
    private let codexLinks = LockedValue<[String: CodexAccountLink]>([:])
    private let codexIndex: CodexAccountIndex
    /// A credential waiting on the one question only the user can answer:
    /// which of its login's workspaces it should be read for.
    ///
    /// Held rather than written, because a credential filed without that
    /// answer is one every poll would guess at. Dropped if the question goes
    /// unanswered, which costs the user the sign-in again and costs the Mac
    /// nothing.
    private var pendingCodexLink: (credential: CodexCredential, choice: CodexLinkChoice)?
    /// A session waiting on the one question only the user can answer: which
    /// of its account's organisations it should be read for.
    ///
    /// Held here rather than written, because a session filed without that
    /// answer is one every poll would guess at. It is dropped if the question
    /// goes unanswered, which costs the user the login again and costs the
    /// Mac nothing.
    private var pendingClaudeWebLink: (session: String, choice: ClaudeWebLinkChoice)?
    /// Reads each metering vendor's public status page. Constructed for the
    /// providers that are metering and inert until `start` — a vendor Sissy
    /// was told to leave alone makes no request, which is the same rule its
    /// reader is built under.
    private let statusMonitor: ProviderStatusMonitor
    /// The forges the user has connected, and the poll over them.
    ///
    /// The list is the index's and the monitor's copy of it is immutable, so a
    /// connection added or removed is a new monitor rather than a mutated one —
    /// the same trade the provider list takes, and cheaper here because nothing
    /// a forge reader holds resumes from an offset. What it costs is one poll.
    private let forgeIndex: ForgeConnectionIndex
    private var forgeMonitor: ForgeActivityMonitor
    private let identityMonitor: GitIdentityMonitor
    /// What the CLIs on this Mac are holding right now. Beside the monitors
    /// above rather than on a provider: a running process belongs to the Mac,
    /// and it is there on a day neither CLI has spent anything.
    private let agentMonitor: AgentProcessMonitor
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
    /// How long the rollups are reused before the day files are read again.
    /// Long enough that frames do not walk the archive, short enough that a
    /// window is never visibly behind the day it includes.
    ///
    /// It survives the archive growing from days to months: measured on real
    /// files, a day is about 819 bytes over four rows, so a full 90-day
    /// two-provider archive is ~150 KB and decodes in under 2 ms. What a
    /// backfill needs is not a longer interval but a frame —
    /// `invalidateHistoryRollups` — since an idle Mac emits nothing and the
    /// panel would otherwise hold yesterday's windows until the next turn.
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
    /// The limits reader built on Claude Code's own credential.
    private let claudeOwnLimits: ClaudeLimitsProbe?
    /// Where every limits reader records the vendor refusing it, so a reader
    /// rebuilt inside a block waits it out instead of spending a request on
    /// it. One store for all of them: the readers are actors and an account
    /// adds another, and a file each would be a file per credential.
    private let limitsBackoff: LimitsBackoffStore
    /// Whether the CLI keeps a credential Sissy can read.
    ///
    /// Answered off the construction path — finding out costs a `security`
    /// call when there is no credential file — and published rather than
    /// returned, because Settings words a row from it and a row that says
    /// Sissy is reading claude.ai while it is reading the CLI's token is the
    /// kind of lie this app's settings are not allowed to tell.
    nonisolated private let claudeOwnCredential = LockedValue(false)
    nonisolated var claudeUsesOwnCredential: Bool { claudeOwnCredential.load() }

    private struct ResolvedProvider {
        let id: String
        let activation: ProviderActivation
        /// Where this provider's files are, so every path it needs comes from
        /// one config home.
        let home: ProviderHome

        var dataDir: URL { home.dataDir }
    }

    init(
        config: ServerConfig,
        configURL: URL = ServerConfig.defaultURL,
        configIsWritable: Bool = true,
        limitsProbe: ClaudeLimitsProbe? = nil,
        claudeAccounts: ClaudeAccountRegistry? = nil,
        statusMonitor: ProviderStatusMonitor? = nil,
        keepAwakePolicy: KeepAwakePolicy = .default
    ) {
        self.config = config
        self.pricing = ProviderPricing(override: config.pricingOverride ?? [:], catalog: nil)
        self.configURL = configURL
        self.configIsWritable = configIsWritable
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
        self.projectLedger = projectLedger
        self.identityMonitor = GitIdentityMonitor(ledger: projectLedger)
        self.agentMonitor = AgentProcessMonitor(ledger: projectLedger)
        let limitsBackoff = LimitsBackoffStore(
            url: LimitsBackoffLedger.defaultURL(in: stateDir))
        self.limitsBackoff = limitsBackoff
        let forgeIndex = ForgeConnectionIndex(url: ForgeConnectionIndex.defaultURL(in: stateDir))
        self.forgeIndex = forgeIndex
        self.forgeMonitor = ForgeActivityMonitor(
            connections: (try? forgeIndex.loadSettingAside()) ?? [],
            counters: (config.forgeCounters ?? .defaults).enabled)
        let historyRoot: URL? = config.resolvedHistoryRetentionDays > 0 ? stateDir : nil
        let pollInterval: Duration = .seconds(Int(max(config.pollIntervalSeconds, 1)))
        let claudeHome = config.providerHome(vendor: ProviderID.claudeCode)
        let codexHome = config.providerHome(vendor: ProviderID.codex)
        // Claude Code has no detection step: it is the v0.1.0 baseline and an
        // unset toggle leaves it on. Codex is tailed whenever its rollout dir
        // exists — the cold scan is already 48h-bounded, so an idle reader is
        // cheap. The toggle is the vendor's, not an account's: switching a CLI
        // off means Sissy stops reading it, however many accounts of it exist.
        let claudeActivation: ProviderActivation = (config.providers.claudeCode ?? true) ? .on : .off
        self.resolvedProviders = [
            ResolvedProvider(
                id: claudeHome.id, activation: claudeActivation, home: claudeHome),
            ResolvedProvider(
                id: codexHome.id,
                activation: ProviderActivation.resolve(
                    toggle: config.providers.codex,
                    autoDetected: FileManager.default.fileExists(atPath: codexHome.dataDir.path)
                ),
                home: codexHome
            ),
        ]
        self.claudeHome = claudeHome
        self.statusMonitor =
            statusMonitor
            ?? ProviderStatusMonitor(
                providers: self.resolvedProviders.filter { $0.activation.isMetering }.map(\.id))
        // Built before the providers rather than after: the Claude adapter's
        // signals hold it, because who the CLI is signed in as is what says
        // which of the per-account readings is the one the row already shows.
        // The slot is the one the limits probe reads below, so the name on the
        // row and the limits under it are resolved from the same credential.
        let claudeSlot = ClaudeCLISlot.live(home: claudeHome)
        let accountRegistry =
            claudeAccounts
            ?? ClaudeAccountRegistry(
                store: ClaudeAccountStore(indexURL: ClaudeAccountStore.defaultURL(in: stateDir)),
                slot: claudeSlot)
        self.claudeAccounts = accountRegistry
        let webIndex = ClaudeWebSessionIndex(
            url: ClaudeWebSessionIndex.defaultURL(in: stateDir))
        self.claudeWebIndex = webIndex
        self.claudeWebLinks.store(webIndex.load())
        let codexIndex = CodexAccountIndex(url: CodexAccountIndex.defaultURL(in: stateDir))
        self.codexIndex = codexIndex
        self.codexLinks.store(codexIndex.load())
        var ownLimits: ClaudeLimitsProbe?
        var providers: [any UsageProvider] = []
        for resolved in self.resolvedProviders where resolved.activation.isMetering {
            let home = resolved.home
            switch home.id {
            case ProviderID.codex:
                // Built with no account of its own: which account `codex` is
                // signed in as is that file's to say, and it can change under
                // Sissy between two polls.
                let authURL = home.codexAuthURL
                self.codexSources.store(
                    [
                        CodexUsageSource(
                            credentialSource: { _ in
                                CodexAuthSource.credential(at: authURL)
                            },
                            backoff: limitsBackoff.slot(
                                for: LimitsBackoffLedger.codexKey(account: nil)))
                    ]
                        + Self.linkedCodexSources(
                            links: self.codexLinks.load(), backoff: limitsBackoff))
                providers.append(
                    LocalUsageProvider.codex(
                        codexDir: home.dataDir,
                        id: home.id,
                        pollInterval: pollInterval,
                        persistenceURL: Self.persistenceURL(for: home, in: stateDir),
                        historyRoot: historyRoot,
                        pricingOverride: config.pricingOverride,
                        usageSources: self.codexSources,
                        usageLinks: self.codexLinks,
                        ledger: projectLedger
                    ))
            default:
                // The CLI's own credential answers the usage endpoint with no
                // dialog and no grant to lapse, from the login keychain where
                // the CLI keeps it and from the file where it does not. Built
                // unconditionally: asking which of the two holds it would
                // spawn `security` on whatever thread is constructing the
                // engine, and the probe's own first read answers the same
                // question off it. The imported claude.ai session stays beside
                // it as the fallback for a Mac that has neither, which is a
                // CLI nobody has signed into.
                // The read goes through `loadOffPool` because it is blocking:
                // it forks `/usr/bin/security`, and called straight from the
                // probe that runs on the actor's own executor, parking a
                // cooperative thread once every five minutes per home.
                // Off-pool is also what gives the timeout the probe already
                // passes something to bound.
                let probe =
                    limitsProbe
                    ?? ClaudeLimitsProbe(
                        credentials: { timeout in
                            await ClaudeCredentialsStore.loadOffPool(timeout: timeout) {
                                ClaudeCodeCredentials.load(slot: claudeSlot)
                            }
                        },
                        backoff: limitsBackoff.slot(for: LimitsBackoffLedger.claudeCLIKey))
                ownLimits = probe
                providers.append(
                    LocalUsageProvider.claudeCode(
                        claudeDir: home.dataDir,
                        id: home.id,
                        pollInterval: pollInterval,
                        persistenceURL: Self.persistenceURL(for: home, in: stateDir),
                        historyRoot: historyRoot,
                        pricingOverride: config.pricingOverride,
                        limitsProbe: probe,
                        webSources: self.claudeWebSources,
                        webLinks: self.claudeWebLinks,
                        profile: ClaudeProfileSource(url: home.claudeProfileURL),
                        accounts: accountRegistry,
                        ledger: projectLedger
                    ))
            }
        }
        self.claudeOwnLimits = ownLimits
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
        // use. A refresh does not reprice what it already priced, so a
        // catalog that lands mid-scan would leave the day split across two
        // rate sets.
        if config.remotePricingEnabled {
            await resolveInitialPriceCatalog()
        } else {
            sissyLog("sissy: remote pricing disabled — using the embedded rate seed")
        }
        guard lifecycle == .running else { return }
        pruneHistoryIfDue(now: Date())
        // Not for a Claude Code that is switched off: there is no slice for
        // its windows to ride on, so the poll would spend a read on a reading
        // nothing could show.
        if meteringClaudeCode {
            await startClaudeLimits(userInitiated: false)
        }
        await startCodexLimits(userInitiated: false)
        if config.statusChecks {
            await startStatusChecks()
        }
        await startForgeActivity()
        await startIdentityChecks()
        await startAgentProcessChecks()
        await applyKeepAwake()
        guard lifecycle == .running else { return }
        let me = self
        // Not for a Claude Code that is switched off, for the reason the
        // limits poll above is not: a module that is off must not exist as far
        // as the system is concerned, and this one spends a `security` call
        // every two minutes reading the credential of a CLI the user has told
        // Sissy to leave alone.
        if meteringClaudeCode {
            startClaudeAccountWatch()
            startClaudeWebAdoption()
        }
        bootTask = Task.detached { [aggregator] in
            await aggregator.start { today, slices in
                await me.rebuildAndEmit(today: today, slices: slices)
            }
        }
        // After the tail, never before it: the backfill reads the project
        // ledger and the tail is what feeds it — the inbox, and the worktree
        // lists git keeps. A pass that got there first would resolve fewer
        // paths, which costs attribution the tail could have given it.
        startArchiveBackfill()
    }

    /// Fills the archive in from the CLIs' own logs, once per provider, for
    /// every day older than the window the live tail owns.
    ///
    /// Detached and at `utility`, because it reads the whole log tree — about
    /// 870 MB and 35 s on one real machine — and the app is usable throughout.
    /// Each provider gets its own pass and its own record, so a CLI switched
    /// on months from now fills its own history in without touching the one
    /// beside it.
    ///
    /// The record is written only where a pass ran to completion. A cancelled
    /// one leaves nothing behind but the days it had already proved whole, and
    /// the next launch asks again.
    private func startArchiveBackfill() {
        guard lifecycle == .running,
            config.resolvedHistoryRetentionDays > 0,
            let window = ArchiveBackfill.window(
                retentionDays: config.resolvedHistoryRetentionDays)
        else { return }
        let ledgerURL = ArchiveBackfillLedger.defaultURL(in: stateDir)
        let ledger = ArchiveBackfillLedger.load(from: ledgerURL)
        var due: [(home: ProviderHome, span: Range<Date>)] = []
        for provider in resolvedProviders where provider.activation.isMetering {
            let snapshot: URL = Self.persistenceURL(for: provider.home, in: stateDir)
            guard
                let span = ArchiveBackfill.uncovered(
                    window,
                    coverage: ledger.coverage[provider.id],
                    meteredThrough: ArchiveBackfill.lastMetered(snapshotAt: snapshot))
            else { continue }
            due.append((home: provider.home, span: span))
        }
        guard !due.isEmpty else { return }
        let me = self
        let stateDir = self.stateDir
        let pricingOverride = config.pricingOverride
        let projectLedger = self.projectLedger
        let catalog = initialPriceCatalog
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
                _ = await provider.backfillArchive { await me.invalidateHistoryRollups() }
                if Task.isCancelled { return }
                await me.recordArchiveBackfill(provider: home.id, covered: span, at: ledgerURL)
            }
        }
    }

    /// One provider's backfill reader: the same adapter the tail uses, over
    /// the same tree, with a window of its own and nothing persisted but day
    /// files.
    private static func backfillProvider(
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

    /// Records that one provider's history has been indexed as far back as
    /// the window asked for. Read-modify-write on the actor, so two providers
    /// finishing close together cannot drop each other's entry.
    private func recordArchiveBackfill(provider: String, covered span: Range<Date>, at url: URL) {
        let updated = ArchiveBackfillLedger.load(from: url)
            .recording(provider: provider, covered: span)
        do {
            try ArchiveBackfillLedger.save(updated, to: url)
        } catch {
            // The pass itself succeeded and its days are on disk. Losing the
            // record costs one repeat of a pass that rewrites the same
            // numbers, which is why this is logged rather than propagated.
            sissyLog(
                "sissy: could not record the \(provider) archive backfill at \(url.path): \(error)")
        }
    }

    /// Drops the cached archive rollups so the next frame reads the day files
    /// again. What makes the panel's windows fill in while a backfill runs.
    private func invalidateHistoryRollups() async {
        historyRollupAt = .distantPast
        await reemit()
    }

    /// Keeps the account archive level with whichever account is signed in.
    ///
    /// The poll is what catches a `/login` or a switch made outside Sissy, and
    /// it is cheap: an unchanged credential costs one `security` call and no
    /// request. Only a token Sissy has not filed buys a round trip to identify
    /// it, which is roughly once per token rotation.
    ///
    /// An account it has not seen before re-emits, because nothing else will:
    /// a `/login` produces no token event of its own, and the switcher would
    /// otherwise wait for an unrelated frame to carry the new list to the app.
    private func startClaudeAccountWatch() {
        let registry = claudeAccounts
        let me = self
        claudeAccountsTask = Task.detached {
            while !Task.isCancelled {
                if await registry.captureActive() { await me.reemit() }
                do {
                    try await Task.sleep(for: Self.claudeAccountPollInterval)
                } catch {
                    return
                }
            }
        }
    }

    /// Keys whatever session is waiting under the holding key.
    ///
    /// Owned rather than detached. It costs a request to claude.ai, so a
    /// launch must not wait on it — but a task nothing holds outlives `stop()`
    /// and, since an engine is rebuilt on every provider toggle, toggling
    /// would leave overlapping passes writing the same items. The handle is
    /// what `stop()` cancels and what `forgetClaudeWebSession(account:)` joins
    /// before it deletes, which is the only thing that stops a pass in flight
    /// from putting back a session the user just asked to be rid of.
    private func startClaudeWebAdoption() {
        claudeWebAdoptionTask?.cancel()
        let me = self
        let index = claudeWebIndex
        let links = claudeWebLinks
        claudeWebAdoptionTask = Task {
            let outcome = await ClaudeWebSessionAdoption.run(
                remember: { link in
                    do {
                        try index.remember(link)
                        links.store(index.load())
                    } catch {
                        sissyLog("sissy: adopted the session but could not name it: \(error)")
                    }
                })
            guard case .adopted = outcome else { return }
            // The key the session sat under is gone, so the reader built for
            // it is now pointed at nothing. Following the store is what turns
            // that reader into one for the account the session turned out to
            // belong to, rather than one reporting a signed-out account.
            await me.followStoredClaudeWebSessions()
        }
    }

    /// Brings the readers level with what is actually stored, and starts the
    /// ones that are new. Idempotent: a reader already polling is left alone.
    private func followStoredClaudeWebSessions() async {
        guard lifecycle == .running else { return }
        await rebuildClaudeWebSources()
        let me = self
        for source in claudeWebSources.load() {
            await source.start(userInitiated: false) { await me.reemit() }
        }
        await reemit()
    }

    /// How often the active credential is re-read. Long on purpose: a token
    /// rotation is tens of minutes apart, and the only thing a shorter poll
    /// would buy is noticing a switch sooner than the next frame.
    private static let claudeAccountPollInterval: Duration = .seconds(120)

    /// Tears everything down. Idempotent, and safe to land while `start()` is
    /// still suspended — that is what `lifecycle` is re-read for. Terminal: an
    /// engine that has stopped stays stopped.
    ///
    /// The account watcher is waited for, not only cancelled. An engine is
    /// rebuilt on every provider toggle, and a watcher still identifying a
    /// token when its engine stopped went on to write the archive and the
    /// index after the replacement's own watcher had started.
    func stop() async {
        lifecycle = .stopped
        // Cancel the aggregator boot Task first so the cold scan observes
        // cancellation and bails out of its file enumeration loops before
        // anything else is torn down.
        bootTask?.cancel()
        backfillTask?.cancel()
        claudeAccountsTask?.cancel()
        claudeWebAdoptionTask?.cancel()
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
        await claudeAccountsTask?.value
        await stopClaudeLimits()
        await stopCodexLimits()
        await statusMonitor.stop()
        await forgeMonitor.stop()
        await identityMonitor.stop()
        await agentMonitor.stop()
        await aggregator.stop()
        bootTask = nil
        backfillTask = nil
        claudeAccountsTask = nil
        claudeWebAdoptionTask = nil
        priceCatalogTask = nil
    }

    /// Every known provider with how it resolved and, for the ones that are
    /// metering, how far their scan has got. In canonical order.
    func providerReadiness() async -> [ProviderReadiness] {
        let progress = await aggregator.scanProgress()
        return resolvedProviders.map {
            ProviderReadiness(
                id: $0.id,
                activation: $0.activation,
                dataDir: $0.dataDir,
                scan: progress[$0.id]
            )
        }
    }

    /// Files a session the login window came back with, and says whether one
    /// question is left.
    ///
    /// Two round trips to claude.ai before anything is written: who the
    /// session belongs to, and what it could be read for. An account with one
    /// organisation that answers the usage question — every account measured
    /// so far — is linked outright and the user is asked nothing. An account
    /// with several holds the session here until they say which, because
    /// membership order is the server's and a reader that picked for itself
    /// would be free to pick differently on the next poll.
    func linkClaudeWebSession(
        _ session: String
    ) async -> Result<ClaudeWebLinkChoice?, ClaudeWebAccountLink.Failure> {
        guard lifecycle == .running else { return .success(nil) }
        let outcome: ClaudeWebAccountLink.Outcome
        do {
            outcome = try await ClaudeWebAccountLink.resolve(session: session)
        } catch let failure as ClaudeWebAccountLink.Failure {
            sissyLog("sissy: claude.ai would not say what the new session is for: \(failure)")
            return .failure(failure)
        } catch {
            sissyLog("sissy: claude.ai would not say what the new session is for: \(error)")
            return .failure(.unidentified)
        }

        switch outcome {
        case .linked(let link):
            return await store(session: session, as: link).map { nil }
        case .choice(let identity, let organizations):
            let choice = ClaudeWebLinkChoice(identity: identity, organizations: organizations)
            pendingClaudeWebLink = (session: session, choice: choice)
            return .success(choice)
        }
    }

    /// Answers it, which is what finally files the session.
    ///
    /// The organisation has to be one the question offered: the panel is the
    /// only caller, but a link recorded against an organisation this account
    /// does not hold would poll a path claude.ai answers 403 to, forever.
    func chooseClaudeWebOrganization(
        _ organization: String
    ) async -> Result<Void, ClaudeWebAccountLink.Failure> {
        guard lifecycle == .running, let pending = pendingClaudeWebLink else {
            return .failure(.interrupted)
        }
        guard pending.choice.organizations.contains(where: { $0.id == organization }) else {
            return .failure(.noSubscription)
        }
        pendingClaudeWebLink = nil
        return await store(
            session: pending.session,
            as: ClaudeWebLink(identity: pending.choice.identity, organization: organization))
    }

    /// Drops a link the user walked away from.
    ///
    /// There is nothing to delete: the session was never written, and this is
    /// the only place it was held. Holding one nobody asked to keep would be
    /// holding a claude.ai session for a reading that will never be made.
    func cancelClaudeWebLink() {
        pendingClaudeWebLink = nil
    }

    /// The session, its link, and the reader for both.
    ///
    /// The index is written after the session and never before: an entry
    /// naming a session that is not filed would have the panel offer an
    /// account with nothing behind it, where a session with no entry is just
    /// one whose organisation is derived, which is what every reader did
    /// before links existed.
    ///
    /// An account linked again already has a reader, which the rebuild keeps
    /// because its account is unchanged, so that reader is pointed at the new
    /// session and organisation here and read at once.
    private func store(
        session: String,
        as link: ClaudeWebLink
    ) async -> Result<Void, ClaudeWebAccountLink.Failure> {
        do {
            try ClaudeWebSessionStore.save(session, account: link.identity.uuid)
        } catch {
            sissyLog("sissy: could not file the linked claude.ai session: \(error)")
            return .failure(.unidentified)
        }
        do {
            try claudeWebIndex.remember(link)
            claudeWebLinks.store(claudeWebIndex.load())
        } catch {
            sissyLog("sissy: filed the claude.ai session but not what it is for: \(error)")
        }
        if lifecycle == .running,
            let running = claudeWebSources.load().first(where: { $0.account == link.identity.uuid })
        {
            let me = self
            await running.relink(organization: link.organization) { await me.reemit() }
        }
        await followStoredClaudeWebSessions()
        return .success(())
    }

    /// Unlinks one account's claude.ai session, leaving every other one where
    /// it is.
    ///
    /// The session is the only half of an account the user added, and the only
    /// half Sissy can put back: another sign-in is a window away. The archived
    /// CLI credential is untouched here on purpose — Sissy took that one
    /// itself the first time the account was active, cannot mint a second, and
    /// deleting it while the CLI is on that account leaves one copy in a slot
    /// the next switch overwrites. Two lifetimes, which is what
    /// `ClaudeWebSessionIndex` is a separate list for.
    ///
    /// The keying pass is cancelled *and joined* first. Cancellation alone is
    /// observed between steps, so a pass suspended on its identifying request
    /// could otherwise name its held session as this very account and write it
    /// back after the delete. What that costs is a session still under the
    /// holding key, which the next launch keys.
    ///
    /// What the keychain or the index refused comes back to the caller, so
    /// an Unlink that did nothing says so rather than closing on silence.
    func forgetClaudeWebSession(account: String) async -> Result<Void, AccountUnlink.Failure> {
        guard lifecycle == .running else { return .success(()) }
        claudeWebAdoptionTask?.cancel()
        await claudeWebAdoptionTask?.value
        claudeWebAdoptionTask = nil
        if pendingClaudeWebLink?.choice.identity.uuid == account { pendingClaudeWebLink = nil }
        let index = claudeWebIndex
        let outcome = await AccountUnlink.run(
            "claude.ai session",
            removeCredential: { try ClaudeWebSessionStore.delete(account: account) },
            forgetName: { try index.forget(uuid: account) })
        claudeWebLinks.store(claudeWebIndex.load())
        await followStoredClaudeWebSessions()
        return outcome
    }

    /// Makes an account the one Claude Code starts as.
    ///
    /// Safe to write the CLI's slots here precisely because they are not where
    /// the account lives: `ClaudeAccountRegistry` holds Sissy's own copy of
    /// every account it has seen, so whatever this overwrites is still
    /// recoverable in a click. It runs from the panel's own control and from
    /// nothing else.
    /// Guarded on the lifecycle for the reason every other control here is:
    /// the host captures the engine strongly in an unstructured `Task`, so a
    /// switch that lands after `stop()` would build the probe a fresh poll
    /// loop and hold the dead engine alive through its callback.
    ///
    /// The row is emitted between the switch and the re-read rather than after
    /// both, because the re-read is a credential and an HTTP round trip and a
    /// control that sits in its old position for the length of one reads as a
    /// click that did nothing. Same rule the provider toggle already follows.
    ///
    /// The identity on the row and the windows under it come from two places
    /// that both answer for the account this just changed — the CLI's config
    /// file and the CLI's credential — and neither is watched, so left to
    /// their own cadences the switch half-happens: the address moves on the
    /// next tail read while the gauges keep the percentages of the account the
    /// user left.
    ///
    /// The imported claude.ai session is deliberately not refreshed. It is
    /// Claude.app's account rather than the CLI's, and this control did not
    /// touch it.
    func activateClaudeAccount(uuid: String) async -> Result<Void, ClaudeAccountRegistry.Failure> {
        guard lifecycle == .running else { return .failure(.notArchived) }
        let outcome = await claudeAccounts.activate(uuid: uuid)
        if case .failure(let why) = outcome {
            sissyLog("sissy: could not switch Claude Code to \(uuid): \(why)")
            await reemit()
            return outcome
        }
        await reemit()
        let me = self
        // The block a refusal left belongs to the credential that earned it,
        // and that credential has just been replaced. Keeping it would leave
        // the account the user switched *to* with no limits until a deadline
        // its own token never met — and, now the record outlives the process,
        // past a relaunch as well.
        await claudeOwnLimits?.clearBackoff()
        await claudeOwnLimits?.refresh { await me.reemit() }
        await aggregator.refreshSignals(for: ProviderID.claudeCode)
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

    /// Whether a claude.ai session is filed. Asked without decrypting one, so
    /// Settings can say so on a build whose grant has lapsed.
    nonisolated var hasClaudeWebSession: Bool {
        !ClaudeWebSessionStore.storedAccounts().isEmpty
    }

    /// The accounts a claude.ai session is filed for, named by whatever can
    /// name them.
    ///
    /// Read off the sessions, which is the record of what exists, rather than
    /// off the links, which are a naming this build writes best-effort — the
    /// same source `hasClaudeWebSession` and `rebuildClaudeWebSources` already
    /// answer from, so the three cannot disagree about which accounts Sissy is
    /// reading. The holding key is not an account and gets no row, for the
    /// reason no reader is built for it.
    ///
    /// Nothing is decrypted, on the rule above: the list is answerable on a
    /// build whose keychain grant has lapsed, which is the only reason
    /// Settings can draw it at all.
    ///
    /// Unordered, because ordering it means wording each one and the words are
    /// the app's.
    nonisolated var linkedClaudeAccounts: [ClaudeWebAccount] {
        ClaudeWebAccount.list(
            stored: ClaudeWebSessionStore.storedAccounts(),
            links: claudeWebLinks.load(),
            archived: claudeAccounts.currentSnapshot().accounts)
    }

    /// Claude Code credentials filed for config homes this engine does not
    /// read, by keychain service name. Nonisolated and blocking, because it
    /// is one keychain query and the caller runs it off the main actor.
    nonisolated func unsupportedClaudeHomes() -> [String] {
        ClaudeUnsupportedHomes.scan(reading: claudeHome.home)
    }

    /// The Claude Code config home this engine reads, for the notice that
    /// names it.
    nonisolated var claudeConfigHome: URL { claudeHome.home }

    /// What a user pressing refresh on one provider reaches.
    ///
    /// Deliberately one door with two behaviours behind it, because the
    /// action is not the same action: on Claude Code it re-reads the keychain
    /// with the dialog allowed and polls the usage endpoint at once, which is
    /// the second and last gesture permitted to ask for that permission. On
    /// Codex it re-reads `auth.json` and asks OpenAI for this account's
    /// windows — which is a refresh that moves the numbers, where until the
    /// usage endpoint was read it could only re-read the plan and wait for the
    /// CLI's next turn.
    ///
    /// The probe is only reached when the setting is on: a refresh must not
    /// be a second way to switch a module on, or the permission would be
    /// asked for by a control that never promised to.
    func refreshProvider(id: String) async {
        guard lifecycle == .running else { return }
        let me = self
        if id == ProviderID.claudeCode {
            // Both sources, because both may be reading and the row shows
            // whichever answered: refreshing only one leaves the button doing
            // nothing on the Mac where the other is the live one.
            if let own = claudeOwnLimits {
                await own.refresh { await me.reemit() }
            }
            // A session claude.ai has closed is left alone: re-reading a dead
            // string is the button failing at its only job, and the only thing
            // that can replace one is a fresh sign-in, which the notice beside
            // it offers.
            for source in claudeWebSources.load()
            where await source.currentSignals().limitsState != .sessionExpired {
                await source.refresh { await me.reemit() }
            }
        }
        if id == ProviderID.codex {
            for source in codexSources.load() {
                await source.refresh { await me.reemit() }
            }
        }
        if config.statusChecks {
            await statusMonitor.refresh(provider: id) { await me.reemit() }
        }
        await aggregator.refreshSignals(for: id)
        await reemit()
    }

    /// Switch the keep-awake mode and persist it, so the choice survives a
    /// restart.
    func setKeepAwake(mode raw: String) async {
        guard let mode = KeepAwakeMode(rawValue: raw), mode != config.keepAwake else { return }
        config.keepAwake = mode
        persistConfig("keepAwake")
        await applyKeepAwake()
        await reemit()
    }

    /// Switch whether the hold covers the screen and persist it.
    ///
    /// Records the choice. Registering and unregistering the hook itself is
    /// the app's, because it needs the script out of the app bundle — the
    /// engine only owns what `server.json` says.
    ///
    /// `.stopped`, not `.running`, which is the whole of the guard: the app
    /// registers the hook from its own `start()`, ahead of the boot Task that
    /// reaches `start()` here, so a guard on `.running` would silently drop
    /// the launch's own write and leave a pending removal un-retried. What it
    /// refuses is the other end — a provider switch stops this engine without
    /// joining the hooks pass, and the pass still holds the reference it was
    /// built with, so its write would land from an object that is gone.
    func setAgentHooks(enabled: Bool, removalPending: Bool = false) async {
        guard lifecycle != .stopped else { return }
        guard enabled != config.agentHooks || removalPending != config.agentHooksRemovalPending
        else { return }
        config.agentHooks = enabled
        config.agentHooksRemovalPending = removalPending
        persistConfig("agentHooks")
    }

    /// Applied through the same path as the mode, so flipping it under a
    /// running hold drops or adds the screen half without disturbing the
    /// system assertion underneath.
    func setKeepScreenAwake(enabled: Bool) async {
        guard enabled != config.keepScreenAwake else { return }
        config.keepScreenAwake = enabled
        persistConfig("keepScreenAwake")
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
        statusMonitor.noteActivity()
        forgeMonitor.noteActivity()
        identityMonitor.noteActivity()
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

    private var meteringCodex: Bool {
        resolvedProviders.contains {
            $0.id == ProviderID.codex && $0.activation.isMetering
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
        // The CLI's own credential raises no dialog and has no grant to go
        // stale, which is why its probe takes no `userInitiated` at all: it
        // polls from the moment there is something to read. Whether it found
        // one is its own first reading rather than a second lookup — asking
        // separately would spawn `security` for an answer the probe is about
        // to publish.
        if let own = claudeOwnLimits {
            await own.start {
                await me.noteOwnCredential(own.currentSignals().limitsState)
                await me.reemit()
            }
        }
        // The linked claude.ai sessions run beside it rather than instead of
        // it: `ClaudeCodeSignals.merge` prefers the CLI's own reading and falls
        // back to these, which are the only answer left on a Mac nobody has
        // signed the CLI into.
        await rebuildClaudeWebSources()
        for source in claudeWebSources.load() {
            await source.start(userInitiated: userInitiated) { await me.reemit() }
        }
    }

    /// Builds one reader per stored session, and drops the readers whose
    /// sessions have gone.
    ///
    /// The set is what the adapter's signals read, so replacing it is how a
    /// session linked or forgotten reaches the frame without the adapter being
    /// rebuilt. A reader that survives is kept rather than replaced: it is an
    /// actor with a poll loop and a reading already published, and building a
    /// fresh one would blank that account's gauges until its next request.
    ///
    /// The holding key gets no reader. A session waiting there is one Sissy
    /// cannot yet name, and a reader for it would publish an account whose id
    /// is the literal holding key — a second row on the Overview for the
    /// session already on the first, labelled with a string no user has seen.
    /// It is a reader the moment the keying pass says whose it is.
    ///
    /// A dropped reader is retired rather than stopped, because this suspends:
    /// a `start` loop that read the set before this call can reach a reader
    /// this call has just discarded, and a poll loop on an object nothing
    /// holds outlives `stop()` and keeps the engine alive through its own
    /// callback.
    private func rebuildClaudeWebSources() async {
        let stored = Set(ClaudeWebSessionStore.storedAccounts())
            .subtracting([ClaudeWebSessionStore.unkeyedAccount])
        let existing = claudeWebSources.load()
        for source in existing where !stored.contains(source.account) {
            await source.retire()
        }
        let kept = existing.filter { stored.contains($0.account) }
        let links = claudeWebLinks.load()
        let added = stored.subtracting(kept.map(\.account))
            .sorted()
            .map {
                ClaudeWebSource(
                    account: $0,
                    organization: links[$0]?.organization,
                    backoff: limitsBackoff.slot(
                        for: LimitsBackoffLedger.claudeWebKey(account: $0)))
            }
        claudeWebSources.store(kept + added)
    }

    /// Records whether the CLI turned out to keep a credential Sissy can read,
    /// which is what Settings words its limits-source row from.
    private func noteOwnCredential(_ state: ProviderLimitsState) {
        claudeOwnCredential.update { $0 = state != .signedOut }
    }

    /// Stops both readers. Which one was running is not worth remembering:
    /// stopping one that never started is a no-op, and asking would be a
    /// second place for the answer to be wrong.
    private func stopClaudeLimits() async {
        for source in claudeWebSources.load() {
            await source.stop()
        }
        await claudeOwnLimits?.stop()
    }

    /// Files the account a sign-in produced, and says whether one question is
    /// left.
    ///
    /// `.linked` is a link that is complete, and `.linkedToDefault` one that
    /// is complete on a workspace nobody was asked about. `.choice` is a
    /// login holding more than one workspace, whose credential is held here,
    /// unwritten, until the user says which.
    func linkCodexAccount(
        code: String, flow: CodexOAuth.Flow
    ) async -> Result<CodexLinkStep, CodexOAuth.Failure> {
        guard lifecycle == .running else { return .failure(.interrupted) }
        let credential: CodexCredential
        do {
            credential = try await CodexOAuth.redeem(code: code, flow: flow)
        } catch let failure as CodexOAuth.Failure {
            return .failure(failure)
        } catch {
            return .failure(.refused)
        }
        let outcome: CodexAccountLinking.Outcome
        do {
            outcome = try await CodexAccountLinking.resolve(credential: credential)
        } catch {
            return .failure(.unidentified)
        }
        switch outcome {
        case .linked(let link):
            return await store(credential, as: link).map { .linked }
        case .linkedToDefault(let link, let workspaceId):
            return await store(credential, as: link).map {
                .linkedToDefault(email: link.identity.email, workspaceId: workspaceId)
            }
        case .choice(let choice):
            pendingCodexLink = (credential: credential, choice: choice)
            return .success(.choice(choice))
        }
    }

    /// Answers the workspace question and files what was held for it.
    func chooseCodexWorkspace(_ id: String) async -> Result<Void, CodexOAuth.Failure> {
        guard lifecycle == .running, let pending = pendingCodexLink else {
            return .failure(.interrupted)
        }
        guard let workspace = pending.choice.workspaces.first(where: { $0.id == id }) else {
            return .failure(.interrupted)
        }
        pendingCodexLink = nil
        return await store(
            pending.credential,
            as: CodexAccountLink(identity: pending.choice.identity, workspace: workspace))
    }

    /// Drops a credential nobody answered the question for. It was never
    /// written, so there is nothing to undo.
    func cancelCodexLink() {
        pendingCodexLink = nil
    }

    /// Files the credential and then names it.
    ///
    /// The workspace the user chose is written onto the credential rather than
    /// carried beside it: it is the `ChatGPT-Account-Id` every request is made
    /// with, and a reader that had to look it up could be handed one the
    /// credential does not agree with.
    ///
    /// A failed `remember` keeps the credential, for the reason the claude.ai
    /// link does: losing a sign-in to a disk error is worse than a row that
    /// reads its account by id until the next link. A failed save is
    /// `notFiled` rather than a vendor refusal, because OpenAI completed the
    /// sign-in and the keychain is what would not keep it.
    ///
    /// The save goes through `CodexRenewal`, which drops what it still holds
    /// for this login in the same step: a renewal of the previous link
    /// landing after this save would file the old workspace over the new one.
    private func store(
        _ credential: CodexCredential, as link: CodexAccountLink
    ) async -> Result<Void, CodexOAuth.Failure> {
        let configured = CodexCredential(
            accessToken: credential.accessToken,
            refreshToken: credential.refreshToken,
            idToken: credential.idToken,
            accountId: link.workspace?.id ?? credential.accountId,
            userId: credential.userId,
            email: credential.email,
            plan: credential.plan,
            expiresAt: credential.expiresAt)
        do {
            try await CodexRenewal.shared.replace(account: link.identity.id, with: configured)
        } catch {
            sissyLog("sissy: the Codex credential could not be filed (\(error))")
            return .failure(.notFiled)
        }
        do {
            try codexIndex.remember(link)
            codexLinks.store(codexIndex.load())
        } catch {
            sissyLog("sissy: the Codex account was signed in but could not be named")
        }
        await rebuildCodexSources()
        await startCodexLimits(userInitiated: true)
        return .success(())
    }

    /// Unlinks one Codex account: the credential Sissy holds and the name
    /// beside it, and nothing else.
    ///
    /// The CLI's own `auth.json` is untouched, which is the whole separation
    /// this feature rests on — linking an account never changed which account
    /// the terminal is on, and unlinking one must not either.
    ///
    /// A credential the keychain would not delete keeps its name, and what
    /// either half refused comes back to the caller to show.
    func forgetCodexAccount(id: String) async -> Result<Void, AccountUnlink.Failure> {
        guard lifecycle == .running else { return .success(()) }
        if pendingCodexLink?.choice.identity.id == id { pendingCodexLink = nil }
        let index = codexIndex
        let outcome = await AccountUnlink.run(
            "Codex credential",
            removeCredential: { try await CodexRenewal.shared.remove(account: id) },
            forgetName: { try index.forget(id: id) })
        codexLinks.store(codexIndex.load())
        await rebuildCodexSources()
        await reemit()
        return outcome
    }

    /// Every Codex account Sissy holds a credential for, as Settings lists
    /// them. Driven by the stored credentials rather than by the links, so a
    /// credential whose naming failed still gets a row — and a way to remove
    /// it.
    nonisolated var linkedCodexAccounts: [CodexLinkedAccount] {
        CodexLinkedAccount.list(
            stored: CodexAccountStore.storedAccounts(), links: codexLinks.load())
    }

    /// One reader per stored credential, renewing its own item as it goes.
    static func linkedCodexSources(
        links: [String: CodexAccountLink], backoff: LimitsBackoffStore? = nil
    ) -> [CodexUsageSource] {
        CodexAccountStore.storedAccounts().map {
            linkedCodexSource(id: $0, links: links, backoff: backoff)
        }
    }

    /// One reader for one linked account. The renewal rides on
    /// `CodexRenewal`, which is the one place the item's refresh token is
    /// spent: it is redeemed once, so every reader of an account has to share
    /// the renewal rather than each start its own.
    static func linkedCodexSource(
        id: String, links: [String: CodexAccountLink], backoff: LimitsBackoffStore? = nil
    ) -> CodexUsageSource {
        CodexUsageSource(
            account: id,
            workspace: links[id]?.workspace?.name,
            credentialSource: { allowingInteraction in
                await CodexRenewal.shared.supply(
                    account: id, allowingInteraction: allowingInteraction)
            },
            renewRefused: { refused in
                await CodexRenewal.shared.renewRefused(account: id, refused: refused)
            },
            backoff: backoff?.slot(for: LimitsBackoffLedger.codexKey(account: id)))
    }

    /// Builds a reader per stored credential and drops the ones whose
    /// credentials have gone, keeping the CLI's own reader at the head.
    ///
    /// A reader that survives is kept rather than replaced: it is an actor
    /// with a poll loop and a reading already published, and a fresh one would
    /// blank that account's gauges until its next request. A dropped one is
    /// retired rather than stopped, because this suspends — a `start` that
    /// read the set before this call can reach a reader this call discarded,
    /// and a poll loop on an object nothing holds outlives `stop()`.
    private func rebuildCodexSources() async {
        // A provider that is switched off has no reader, whatever the keychain
        // holds: the rule is that a module which is off does not exist as far
        // as the system is concerned, and a linked account polling OpenAI for
        // a row that is not on the panel is exactly that.
        let stored = meteringCodex ? Set(CodexAccountStore.storedAccounts()) : []
        let links = codexLinks.load()
        let split = Self.partitionCodexSources(codexSources.load(), stored: stored, links: links)
        for source in split.retired {
            await source.retire()
        }
        let kept = split.kept
        let added = stored.subtracting(kept.compactMap(\.account))
            .sorted()
            .map { Self.linkedCodexSource(id: $0, links: links, backoff: limitsBackoff) }
        codexSources.store(kept + added)
    }

    /// Which readers a rebuild keeps and which it retires.
    ///
    /// The CLI's own reader is always kept. A linked one is kept while its
    /// credential is stored and it still names the workspace its link does:
    /// the same login linked again for another workspace keeps its key, and a
    /// reader kept on the key alone named the old workspace beside readings
    /// asked for the new one.
    static func partitionCodexSources(
        _ existing: [CodexUsageSource], stored: Set<String>,
        links: [String: CodexAccountLink]
    ) -> (kept: [CodexUsageSource], retired: [CodexUsageSource]) {
        var kept: [CodexUsageSource] = []
        var retired: [CodexUsageSource] = []
        for source in existing {
            guard let account = source.account else {
                kept.append(source)
                continue
            }
            let current =
                stored.contains(account) && source.workspace == links[account]?.workspace?.name
            if current { kept.append(source) } else { retired.append(source) }
        }
        return (kept, retired)
    }

    /// Starts every Codex usage reader.
    ///
    /// Unconditional where the Claude side is gated on a toggle, because there
    /// is nothing to gate: the credential is a file the adapter already reads
    /// for the plan, no dialog can be raised by reading it, and a provider
    /// that is switched off has no reader in the set to start. The reply is
    /// the same block the tail parses, so nothing new reaches the frame — only
    /// sooner.
    private func startCodexLimits(userInitiated: Bool) async {
        let me = self
        for source in codexSources.load() {
            await source.start(userInitiated: userInitiated) { await me.reemit() }
        }
    }

    private func stopCodexLimits() async {
        for source in codexSources.load() {
            await source.stop()
        }
    }

    /// Starts the status poll. Every change it publishes rebuilds the frame,
    /// for the reason a lapsed authorization does: a vendor going down is news
    /// that arrives on a day where no token event follows it.
    ///
    /// The lifecycle is checked on both sides of the hop, and this is the one
    /// place that can be, because it is the one place that creates the poll
    /// loop: the two callers reach it across suspensions a `stop()` can land
    /// in — `start()` from behind the keychain read, and `setStatusChecks`
    /// from a toggle flipped while the app is quitting — and the monitor
    /// itself only knows whether *it* is running. Without the second check a
    /// `start` that queued behind that `stop()` on the monitor's executor
    /// leaves a poll loop nothing holds a handle to.
    private func startStatusChecks() async {
        guard lifecycle == .running else { return }
        let me = self
        await statusMonitor.start { await me.reemit() }
        guard lifecycle == .running else {
            await statusMonitor.stop()
            return
        }
    }

    /// Starts the forge poll. A build with nothing connected starts nothing,
    /// which is the whole of how this module stays off until it is asked for:
    /// there is no switch to read because a connection *is* the switch.
    ///
    /// The lifecycle is checked on both sides of the hop for the reason
    /// `startStatusChecks` is: this is reachable across a suspension a `stop()`
    /// can land in — from `start`, and from a connection made while the app is
    /// quitting — and the monitor itself only knows whether *it* is running.
    private func startForgeActivity() async {
        guard lifecycle == .running else { return }
        let me = self
        await forgeMonitor.start { await me.reemit() }
        guard lifecycle == .running else {
            await forgeMonitor.stop()
            return
        }
    }

    /// Starts the identity sweep, under the same guard `startStatusChecks`
    /// carries and for the same reason: `start()` reaches here across
    /// suspensions a `stop()` can land in, and the monitor only knows whether
    /// it is running rather than whether the engine still is.
    private func startIdentityChecks() async {
        guard lifecycle == .running else { return }
        let me = self
        await identityMonitor.start { await me.reemit() }
        guard lifecycle == .running else {
            await identityMonitor.stop()
            return
        }
    }

    /// Starts the process sweep, under the same guard the identity checks
    /// carry: `start()` reaches here across suspensions a `stop()` can land
    /// in, and the monitor only knows whether it is running rather than
    /// whether the engine still is.
    private func startAgentProcessChecks() async {
        guard lifecycle == .running else { return }
        let me = self
        await agentMonitor.start { await me.reemit() }
        guard lifecycle == .running else {
            await agentMonitor.stop()
            return
        }
    }

    /// Every forge the user has connected, for the Settings list.
    ///
    /// Read from the index rather than from the monitor, so a build whose
    /// keychain grant has lapsed still lists what is connected and offers the
    /// way to remove it — the rule `linkedCodexAccounts` next door is under.
    /// Nonisolated because Settings reads it while the engine is mid-poll, and
    /// the index is an immutable value holding no secret. An index that will
    /// not read is set aside here rather than read as empty and overwritten.
    nonisolated var forgeConnections: [ForgeConnection] {
        (try? forgeIndex.loadSettingAside()) ?? []
    }

    /// Whether an unreadable connection index has been set aside, which
    /// Settings says so the connections that vanished with it are explained.
    nonisolated var forgeIndexSetAside: Bool { forgeIndex.hasSetAside() }

    /// The tokens Sissy holds for a forge the index does not name.
    ///
    /// Attributes only, so it raises no dialog. These are what an interrupted
    /// connect or disconnect, or an index set aside, leaves in the keychain;
    /// listing them is what gives the user a way to remove a token nothing
    /// reads any more.
    nonisolated var orphanedForgeTokens: [String] {
        guard let connected = try? forgeIndex.loadSettingAside() else { return [] }
        return ForgeConnectionIndex.orphans(
            stored: ForgeTokenStore.storedConnections(), connected: connected)
    }

    /// Deletes a token no connection names. One the index has come to name
    /// since the list was drawn is left alone: removing it is `Disconnect…`.
    /// A delete that fails leaves the row in the list, which is what says so.
    func removeOrphanedForgeToken(id: String) async {
        guard orphanedForgeTokens.contains(id) else { return }
        do {
            try ForgeTokenStore.delete(connection: id)
        } catch {
            sissyLog("sissy: could not remove the orphaned forge token \(id) (\(error))")
        }
    }

    /// The tokens `gh` and `glab` already hold on this Mac.
    ///
    /// Read on demand from the control that offers them and never at launch or
    /// from a poll — the rule the vendor login window is under. It is also why
    /// this answers candidates rather than connecting them: the user is shown
    /// which CLI and which host the token comes from before anything is filed.
    nonisolated func forgeTokenCandidates() -> [ForgeTokenCandidate] {
        ForgeTokenImport.candidates()
    }

    /// Files a token for a forge and starts reading it.
    ///
    /// The token is written before the connection is recorded, so a failure
    /// leaves no row promising a reading there is no credential for. Answers
    /// whether it is now connected, and the caller has to say so: a write that
    /// failed with the sheet already dismissed would take the pasted token with
    /// it and leave nothing on screen to explain the missing row.
    ///
    /// **Connecting the same host again is how a refused or missing token is
    /// replaced.** The index keys on the host, the monitor is rebuilt from it,
    /// and a fresh monitor has nothing parked — so this is the way back from
    /// both states the poll stops asking about.
    func connectForge(_ connection: ForgeConnection, token: String) async -> Bool {
        do {
            try ForgeTokenStore.save(token, connection: connection.id)
            try forgeIndex.remember(connection)
        } catch {
            sissyLog("sissy: could not connect \(connection.id) (\(error))")
            return false
        }
        await rebuildForgeMonitor()
        await reemit()
        return true
    }

    /// Forgets a forge: the connection, its token, and the reading on the row.
    ///
    /// The record goes first and the token second, so an interrupted removal
    /// leaves a token nothing reads rather than a row nothing can answer for,
    /// and that token is listed in Settings as one without a connection.
    func disconnectForge(id: String) async {
        do {
            try forgeIndex.forget(id: id)
        } catch {
            sissyLog("sissy: could not forget the forge connection \(id) (\(error))")
            return
        }
        do {
            try ForgeTokenStore.delete(connection: id)
        } catch {
            sissyLog("sissy: the forge token for \(id) outlived its connection (\(error))")
        }
        await rebuildForgeMonitor()
        await reemit()
    }

    private func rebuildForgeMonitor() async {
        await forgeMonitor.stop()
        forgeMonitor = ForgeActivityMonitor(
            connections: (try? forgeIndex.loadSettingAside()) ?? [],
            counters: (config.forgeCounters ?? .defaults).enabled)
        await startForgeActivity()
    }

    /// Switches one of a forge row's counters on or off, and persists it.
    ///
    /// The poll is rebuilt rather than told, because the counters are what the
    /// reader is built with — the same trade `rebuildForgeMonitor` already
    /// makes for a connection, and it costs one round rather than a wait: a
    /// fresh monitor asks immediately, so a counter switched back on is a
    /// request away rather than a poll interval away.
    ///
    /// **Switching one off stops it being read**, which is why this is the
    /// engine's and not a view's: on GitLab each counter is four requests a
    /// poll, and a figure nobody has asked to see must not cost them.
    func setForgeCounter(_ counter: ForgeCounter, enabled: Bool) async {
        var counters = config.forgeCounters ?? .defaults
        guard counters[counter] ?? true != enabled else { return }
        counters[counter] = enabled
        config.forgeCounters = counters
        persistConfig("forgeCounters")
        await rebuildForgeMonitor()
        await reemit()
    }

    /// Re-reads every repository's commit identity now, for the panel's own
    /// refresh: a user who has just corrected a repository is looking at the
    /// row that said so, and waiting out the sweep interval to see it clear
    /// reads as the correction not having worked.
    func refreshIdentities() async {
        let me = self
        await identityMonitor.sweepOnce { await me.reemit() }
    }

    /// Counts the running agents again now, for the agents page's own button.
    ///
    /// Worth a control where the counts beside it are not: those come off the
    /// tail as turns land, and nothing a press could do would make a turn
    /// arrive sooner. This is a sweep on a 15 s clock, so a user who has just
    /// closed three sessions is looking at a figure that is right and reads as
    /// wrong.
    ///
    /// Always a frame, including on a quiet Mac: the press is what asked for
    /// one, and the page dates the count by it.
    func refreshAgentProcesses() async {
        await agentMonitor.sampleOnce {}
        await reemit()
    }

    /// Re-reads every forge connection now, for the menu's Refresh All.
    ///
    /// The poll's own round rather than each row's gesture: it leaves a parked
    /// connection parked and never raises the keychain dialog, because one
    /// menu item answering for every host is not the user asking about any
    /// one of them.
    func refreshForgeConnections() async {
        guard lifecycle == .running else { return }
        let me = self
        _ = await forgeMonitor.refreshOnce { await me.reemit() }
    }

    /// The providers this engine meters, for a refresh that reaches each one.
    func meteringProviderIDs() -> [String] {
        resolvedProviders.filter { $0.activation.isMetering }.map(\.id)
    }

    /// Re-reads one forge connection now, for the gesture on its own row.
    ///
    /// The counters move when the user pushes, and the poll is on a five- to
    /// thirty-minute cadence it cannot be told about: a merge landed a minute
    /// ago is a row that is right and looks wrong. It is also the only way
    /// back from a parked connection without disconnecting the host and
    /// connecting it again.
    func refreshForge(id: String) async {
        guard lifecycle == .running else { return }
        let me = self
        await forgeMonitor.refreshOnce(id: id) { await me.reemit() }
    }

    /// Switches the status readings on or off at runtime, and persists it.
    ///
    /// Stopping drops the readings with the loop, so the rows go when the
    /// switch does rather than sitting there dated to the last poll — which is
    /// the same reason the limits probe clears its windows.
    func setStatusChecks(enabled: Bool) async {
        guard config.statusChecks != enabled else { return }
        config.statusChecks = enabled
        persistConfig("statusChecks")
        if enabled {
            await startStatusChecks()
        } else {
            await statusMonitor.stop()
        }
        await reemit()
    }

    /// Saves `config` over `server.json`, and answers whether it did.
    ///
    /// The one place the file is written from, so the refusal below cannot be
    /// missed by a setting added later: a run that found the file unreadable
    /// is running on the defaults, and every save it made would put them over
    /// the user's own values.
    @discardableResult
    private func persistConfig(_ field: String) -> Bool {
        guard configIsWritable else {
            sissyLog(
                "sissy: not saving \(field): \(configURL.path) could not be read at launch and "
                    + "is left as it was")
            return false
        }
        do {
            try ServerConfig.save(config, to: configURL)
            return true
        } catch {
            sissyLog("sissy: failed to persist \(field) to \(configURL.path): \(error)")
            return false
        }
    }

    /// Records that a provider is to be metered, or not, and persists it.
    ///
    /// Only the record. Applying it is the caller's, because the provider list
    /// is built in `init` and this lifecycle is terminal — an engine that has
    /// stopped stays stopped — so a list that has changed is a new engine
    /// rather than a mutated one. That is the cheaper half of the trade: a
    /// locked, mutable list would have to answer for a provider stopped
    /// mid-emit, where a rebuild costs only what a relaunch costs, which is
    /// nothing the persisted offsets do not already cover.
    ///
    /// Answers whether the file now says so. An id this build does not meter
    /// is refused rather than written: `ProviderToggles` would drop it, and a
    /// switch that writes nothing and reports success is the kind of lie the
    /// Providers tab exists to prevent.
    func setProvider(id: String, enabled: Bool) -> Bool {
        guard resolvedProviders.contains(where: { $0.id == id }) else {
            sissyLog("sissy: refused a toggle for an unknown provider — \(id)")
            return false
        }
        guard config.providers[id] != enabled else { return true }
        config.providers[id] = enabled
        // Read back rather than trusted: `ProviderToggles` carries a field per
        // provider and drops an id it has none for, so a provider added to the
        // list above and not to the toggles would be persisted nowhere while
        // this reported success. The invariant lives in another file and no
        // compiler tie holds it, so it is checked where it can still be
        // refused.
        guard config.providers[id] == enabled else {
            sissyLog("sissy: the \(id) toggle has no field in server.json to land in")
            return false
        }
        return persistConfig("the \(id) toggle")
    }

    /// Where one provider's offsets are kept.
    ///
    /// Claude Code keeps the unqualified `usage-state.json` every install has
    /// been writing since 0.1.0: renaming it would strand those offsets and
    /// buy a cold backfill for nothing. Every other provider takes its own
    /// file, so a schema change or a corruption in one cannot cost another its
    /// history.
    private static func persistenceURL(for home: ProviderHome, in stateDir: URL) -> URL {
        guard home.id != ProviderID.claudeCode else {
            return UsageStatePersistence.defaultURL(in: stateDir)
        }
        return UsageStatePersistence.forProvider(home.id, in: stateDir)
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
            history: currentHistory(now: now),
            providerStatus: statusMonitor.currentStatus(),
            forge: forgeMonitor.currentReadings(),
            identities: identityMonitor.currentIdentities(),
            identitiesCheckedAt: identityMonitor.currentCheckedAt(),
            agentMemory: agentMonitor.currentMemory(),
            pricing: pricing
        )
        await onFrame?(frame)
    }

    /// What the archive holds for every period the panel offers, cached for a
    /// beat.
    ///
    /// Empty when the archive is switched off, and when it is on but empty — a
    /// control offering four windows that all come to nothing offers a feature
    /// rather than a reading, so the panel keeps the headline on today until
    /// there is something behind it. The widest window decides that for all of
    /// them: it contains the others, so nothing in it is nothing anywhere.
    ///
    /// The cache is kept even when the answer is withheld, so an empty archive
    /// costs one directory walk every `historyRollupTTL` rather than one per
    /// frame. Switching the archive off drops it instead: the setting can come
    /// back inside the TTL, and serving what was read before it went off would
    /// answer for days the user asked to stop recording.
    private func currentHistory(now: Date) -> [UsagePeriod: UsageHistoryRollup] {
        guard config.resolvedHistoryRetentionDays > 0 else {
            historyRollups = [:]
            return [:]
        }
        let stale = now.timeIntervalSince(historyRollupAt) >= Self.historyRollupTTL
        if historyRollups.isEmpty || stale {
            historyRollups = UsageHistoryStore.rollups(
                for: Set(UsagePeriod.archived), in: stateDir, now: now, pricing: pricing)
            historyRollupAt = now
        }
        return (historyRollups[.all]?.tokens ?? 0) > 0 ? historyRollups : [:]
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

    /// The whole archive, every path re-read through the resolver, for the one
    /// gesture that carries it off this Mac.
    ///
    /// Reattributed rather than handed over as written, which is the archive's
    /// own rule: a day file keeps the directory it saw, and what that path
    /// *means* is today's answer. Without this, a row an older build wrote for
    /// a CLI's scratch directory would go on claiming a project in somebody's
    /// spreadsheet, and a deleted worktree would leave its money on a path
    /// that no longer exists instead of on the repository it was cut from.
    ///
    /// A resolver per export rather than a long-lived one: it pins an answer
    /// for its own lifetime, and an export is exactly the moment to ask the
    /// disk again. The ledger behind it is the shared one, so what any
    /// provider has seen alive is what answers here.
    ///
    /// Nonisolated, and that is the point rather than an optimisation. This
    /// walks every day file in the archive and stats git for every distinct
    /// path in it, unwindowed and uncached — the opposite of `currentHistory`,
    /// which is windowed and TTL-cached because it runs on the frame path. On
    /// the actor, one click would queue every frame behind it and stop the
    /// metering for as long as the walk took. It touches only `let`s: the
    /// directory, and a ledger that carries its own lock.
    nonisolated func exportableHistory() -> [UsageHistoryDay] {
        let resolver = ProjectResolver(ledger: projectLedger)
        return UsageHistoryStore.allDays(in: stateDir).map { day in
            day.reattributed { resolver.project(for: $0) }
        }
    }

    /// One provider's archived days, for the surface that draws them.
    ///
    /// The decision is the actor's and the file walk is not: the retention a
    /// switched-off archive is gated on lives in `config`, while decoding a
    /// file per day belongs anywhere but here. Awaiting a detached task is
    /// what separates them — the actor suspends rather than blocks, so frames
    /// keep being emitted while a slow volume answers.
    ///
    /// This runs when a page opens, never on the frame path. `currentHistory`
    /// is windowed and TTL-cached precisely because it is on that path, and
    /// widening it to feed a chart would put a decode per archived day behind
    /// every emit.
    ///
    /// Retention at `0` is the archive switched off. Pruning leaves whatever
    /// was already written where it is, so the gate is what stops a panel
    /// drawing days from an archive the user has turned off.
    func historySeries(provider: String, days: Int) async -> [UsageHistoryDaySummary] {
        guard config.resolvedHistoryRetentionDays > 0 else { return [] }
        let directory = stateDir
        return await Task.detached {
            UsageHistoryStore.series(provider: provider, days: days, in: directory)
        }.value
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
        await stopArchiveBackfill()
        await aggregator.forgetArchivedDays()
        do {
            try UsageHistoryStore.removeAll(in: stateDir)
            sissyLog("sissy: usage history deleted")
        } catch {
            sissyLog("sissy: failed to delete usage history at \(stateDir.path): \(error)")
        }
        historyRollups = [:]
        historyRollupAt = .distantPast
        await reemit()
    }

    /// Ends the backfill and records every metering provider as covered, which
    /// is what a deletion needs from it.
    ///
    /// The pass is a second writer to the archive and it is not the
    /// aggregator's, so `forgetArchivedDays` does not reach it: a flush landing
    /// after the files were removed would put days back that the user had just
    /// asked Sissy to forget, and nothing would take them out again. Awaiting
    /// the task rather than only cancelling it is what makes that impossible —
    /// cancellation is observed between files, so a write can still be in
    /// flight when `cancel()` returns.
    ///
    /// Recording the window as covered is the other half. A pass cut short
    /// writes no record, so the next launch would go back for the days that
    /// were just deleted — which is the same promise the record's own location
    /// outside `history/` exists to keep.
    private func stopArchiveBackfill() async {
        guard let task = backfillTask else { return }
        backfillTask = nil
        task.cancel()
        await task.value
        guard let window = ArchiveBackfill.window(retentionDays: config.resolvedHistoryRetentionDays)
        else { return }
        for provider in resolvedProviders where provider.activation.isMetering {
            recordArchiveBackfill(
                provider: provider.id,
                covered: window,
                at: ArchiveBackfillLedger.defaultURL(in: stateDir))
        }
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
        } else if let cold = await PriceCatalogSource.fetchForColdStart() {
            let fetched = PriceCatalogSource.retaining(cold)
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
        initialPriceCatalog = resolved
        if let resolved {
            await aggregator.applyPriceCatalog(resolved)
            await applyPricing(resolved)
        }
        let aggregator = self.aggregator
        priceCatalogTask = Task.detached { [weak self] in
            await PriceCatalogSource.refreshLoop(
                initialDelay: initialDelay,
                initialPrevious: resolved
            ) { [weak self] catalog in
                await aggregator.applyPriceCatalog(catalog)
                await self?.applyPricing(catalog)
            }
        }
    }

    /// Reprices the readings taken after the events. The archive's are
    /// dropped rather than left to their TTL, so a window is never priced at
    /// two catalogs on one page, and a frame is built from them at once: the
    /// providers emit while the catalog is still being handed out, against
    /// rollups taken before it, and an idle Mac would otherwise keep a
    /// repriced archived day out of the windows until the next turn.
    private func applyPricing(_ catalog: PriceCatalog) async {
        pricing = ProviderPricing(override: config.pricingOverride ?? [:], catalog: catalog)
        historyRollups = [:]
        await reemit()
    }
}
