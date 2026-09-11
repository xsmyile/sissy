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
    /// Handle on the aggregator boot Task so `stop()` can cancel an
    /// in-flight cold scan. Without this the engine kept walking
    /// `~/.claude/projects` after everything else had shut down and only
    /// drained when every provider finished its scan organically.
    private var bootTask: Task<Void, Never>?
    /// Handle on the pricing-catalog refresh loop so `stop()` can cancel an
    /// in-flight fetch instead of leaving it to finish against a torn-down
    /// engine.
    private var priceCatalogTask: Task<Void, Never>?
    /// Cached input to the last `rebuildAndEmit`. Lets a pure config change —
    /// the primary metric — re-emit immediately without hopping into the
    /// aggregator actor, which can queue behind a running poll/cold scan and
    /// add 50–200 ms of perceived lag. Slices are cached alongside totals so
    /// a metric replay can't desync the aggregate scalars from the
    /// per-provider breakdown — a fresh `perProviderTotals()` call could race
    /// a concurrent provider emit through actor reentrancy.
    private var lastTotals: Reading?

    /// The three inputs a frame is built from, kept together because they
    /// have to be replayed together.
    private struct Reading {
        let today: DayTotals
        let prev: DayTotals?
        let slices: [ProviderSlice]
    }

    /// Polls Claude Code's subscription windows. Constructed unconditionally
    /// so the toggle can start it later without rebuilding the provider list;
    /// it does nothing until `start` is called.
    private let claudeLimitsProbe: ClaudeLimitsProbe
    /// Holds the power assertion. Constructed unconditionally and inert until
    /// asked, like the probe above: an actor nobody has told to hold anything
    /// touches nothing.
    private let keepAwake = KeepAwake()
    /// Whether the Mac is being held awake right now, as opposed to what the
    /// user asked for — which is `config.keepAwake`. They differ when power
    /// management refuses the assertion, and the panel shows both.
    private var keepAwakeActive = false
    /// Whether anyone is there to see the reading. The hold follows it:
    /// quitting Sissy has to let the Mac sleep again, and a hold nobody can
    /// see is a battery complaint with no visible cause. The *mode* is
    /// untouched by this — it is where the user left the switch, and it is
    /// what the hold resumes from.
    private var observerPresent = false
    private var onFrame: (@Sendable (FrameData) async -> Void)?

    /// What the surface needs to tell "still reading the tree" apart from
    /// "there is nothing to read", which are the same zero until the cold
    /// scan finishes.
    struct Readiness: Sendable, Equatable {
        let filesWatched: Int
        let isWarm: Bool
    }

    init(config: ServerConfig, configURL: URL = ServerConfig.defaultURL) {
        self.config = config
        self.configURL = configURL

        // Resolve provider toggles. Unset (nil) means "let the engine
        // decide": ClaudeCodeUsageReader is the v0.1.0 baseline (always on);
        // Codex is tailed whenever its rollout dir exists (the cold scan is
        // already 48h-bounded, so an idle reader is cheap). Explicit `false`
        // forces off even when data exists; explicit `true` forces on.
        let pollInterval: Duration = .seconds(Int(max(config.pollIntervalSeconds, 1)))
        let claudeOn = config.providers.claudeCode ?? true
        let codexOn =
            config.providers.codex
            ?? FileManager.default.fileExists(atPath: config.resolvedCodexDataDir.path)
        let limitsProbe = ClaudeLimitsProbe()
        self.claudeLimitsProbe = limitsProbe
        var providers: [any UsageProvider] = []
        if claudeOn {
            // Legacy persistence URL on purpose: existing installs already
            // wrote `usage-state.json` (no provider suffix). Keeping it lets
            // an upgrade skip the cold backfill instead of stranding
            // historical offsets behind a renamed file.
            providers.append(
                ClaudeCodeUsageReader(
                    claudeDir: config.resolvedClaudeDataDir,
                    pollInterval: pollInterval,
                    persistenceURL: UsageStatePersistence.defaultURL,
                    pricingOverride: config.pricingOverride,
                    limitsProbe: limitsProbe
                ))
        }
        if codexOn {
            providers.append(
                CodexUsageReader(
                    codexDir: config.resolvedCodexDataDir,
                    pollInterval: pollInterval,
                    persistenceURL: UsageStatePersistence.forProvider("codex"),
                    pricingOverride: config.pricingOverride
                ))
        }
        self.aggregator = UsageAggregator(providers: providers)
        let codexResolution = config.providers.codex == nil ? " (auto)" : ""
        sissyLog(
            "sissy: providers — "
                + "claude-code=\(claudeOn ? "on" : "off"), "
                + "codex=\(codexOn ? "on" : "off")\(codexResolution)"
        )
    }

    /// Starts metering. `onFrame` is called for every reading from here on,
    /// including the replays a config change triggers.
    ///
    /// The cold backfill runs in a detached task: on a multi-GB log tree it
    /// takes seconds, and the caller has a surface to put up in the meantime.
    func start(onFrame: @escaping @Sendable (FrameData) async -> Void) async {
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
        sissyLog("sissy: claude limits — \(config.claudeLimits ? "on" : "off")")
        if config.claudeLimits {
            await startClaudeLimitsProbe()
        }
        await applyKeepAwake()
        let me = self
        bootTask = Task.detached { [aggregator] in
            await aggregator.start { today, prev, slices in
                await me.rebuildAndEmit(today: today, prev: prev, slices: slices)
            }
        }
    }

    func stop() async {
        // Cancel the aggregator boot Task first so the cold scan observes
        // cancellation and bails out of its file enumeration loops before
        // anything else is torn down.
        bootTask?.cancel()
        priceCatalogTask?.cancel()
        // Released first, before the awaits below: the kernel drops a dead
        // process's assertions on its own, but `stop()` is also reachable
        // without an exit, and a Mac held awake by something that has shut
        // down is a battery complaint nobody can trace back.
        _ = await keepAwake.apply(holding: false)
        keepAwakeActive = false
        await claudeLimitsProbe.stop()
        await aggregator.stop()
        bootTask = nil
        priceCatalogTask = nil
    }

    func readiness() async -> Readiness {
        Readiness(filesWatched: aggregator.filesWatched(), isWarm: await aggregator.isWarm())
    }

    /// Turn the Claude Code limit probe on or off and persist the choice.
    /// Starting it is what triggers the one-time keychain prompt, so this is
    /// only ever reached from an explicit user action.
    func setClaudeLimits(enabled: Bool) async {
        if enabled == config.claudeLimits { return }
        config.claudeLimits = enabled
        do {
            try ServerConfig.save(config, to: configURL)
        } catch {
            sissyLog(
                "sissy: failed to persist claudeLimits to \(configURL.path): \(error)")
        }
        if enabled {
            await startClaudeLimitsProbe()
        } else {
            await claudeLimitsProbe.stop()
        }
        await reemitFromCache()
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
        await reemitFromCache()
    }

    /// Takes or drops the hold as the surface comes and goes. In one process
    /// that is the app's own lifetime, so it switches once each way.
    func setObserverPresent(_ present: Bool) async {
        guard present != observerPresent else { return }
        observerPresent = present
        await applyKeepAwake()
        await reemitFromCache()
    }

    /// Drives the assertion to whatever the stored mode asks for.
    ///
    /// The desired state is re-read from `config` after the hop into the
    /// actor, never captured before it: this is an actor, so a second mode
    /// change can land while this one is suspended, and the flag the frame
    /// reports has to describe where the user left the switch rather than
    /// where this call found it.
    private func applyKeepAwake() async {
        let wanted = config.keepAwake == .on && observerPresent
        let held = await keepAwake.apply(holding: wanted)
        keepAwakeActive = held && wanted
        sissyLog(
            "sissy: keep-awake \(config.keepAwake.rawValue) — "
                + (keepAwakeActive ? "holding" : "not holding"))
    }

    private func startClaudeLimitsProbe() async {
        let me = self
        await claudeLimitsProbe.start {
            await me.reemitFromCache()
        }
    }

    /// Re-emit a frame using the most recently observed totals. No-op if the
    /// reader hasn't produced a frame yet — the new setting will take effect
    /// on the first real poll.
    ///
    /// The totals are read *after* the slice fetch on purpose. That `await`
    /// is a suspension point a provider emit can land in, and totals read
    /// before it would be the ones that emit has already superseded —
    /// re-emitting them puts the token count backwards and re-caches the
    /// stale pair.
    func reemitFromCache() async {
        let slices = await aggregator.currentSlices()
        guard let totals = lastTotals else { return }
        await rebuildAndEmit(today: totals.today, prev: totals.prev, slices: slices)
    }

    private func rebuildAndEmit(
        today: DayTotals,
        prev: DayTotals?,
        slices: [ProviderSlice]
    ) async {
        lastTotals = Reading(today: today, prev: prev, slices: slices)
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let hoursElapsed = max(now.timeIntervalSince(startOfDay) / 3600, 1.0 / 60.0)
        // Slices arrive captured against the same `perProvider` snapshot the
        // aggregator used to compute `today`/`prev` (or replayed from
        // `lastTotals` on a metric-toggle rebuild). A fresh
        // `perProviderTotals()` call here would race actor reentrancy and
        // could ship a frame whose scalars and breakdown disagree.
        let frame = FrameBuilder.build(
            today: today,
            prev: prev,
            hoursElapsed: hoursElapsed,
            providers: slices,
            keepAwake: KeepAwakeState(mode: config.keepAwake, active: keepAwakeActive)
        )
        await onFrame?(frame)
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
