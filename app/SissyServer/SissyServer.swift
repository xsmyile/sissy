import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

actor SissyServer {
    /// In-memory, mutable mirror of the persisted `ServerConfig`. Runtime
    /// changes update this and call
    /// `ServerConfig.save` so the new value survives a restart.
    private(set) var config: ServerConfig
    let hub: Hub
    let aggregator: UsageAggregator

    private let group: EventLoopGroup
    private let configURL: URL
    private var channel: (any Channel)?
    /// Handle on the aggregator boot Task so `stop()` can cancel an
    /// in-flight cold scan. Without this the daemon kept walking
    /// `~/.claude/projects` after the NIO channel had closed and only
    /// drained when every provider finished its scan organically.
    private var bootTask: Task<Void, Never>?
    /// Handle on the pricing-catalog refresh loop so `stop()` can cancel an
    /// in-flight fetch instead of leaving it to finish against a torn-down
    /// daemon.
    private var priceCatalogTask: Task<Void, Never>?
    private var startedAt: Date = .distantPast
    private var primaryMetric: PrimaryMetric
    /// Client-imposed mascot override. When non-nil, every outgoing frame
    /// has its `state` field replaced before broadcast so menubar + OLED
    /// stay in lock-step. Memory-only — clears on daemon restart.
    /// Cached input to the last `rebuildAndBroadcast`. Lets pure config
    /// changes (pin, primary metric) re-broadcast immediately without
    /// hopping into the aggregator actor — which can queue behind a
    /// running poll/cold scan and add 50–200 ms of perceived lag. Slices
    /// are cached alongside totals so a pin/metric replay can't desync
    /// the aggregate scalars from the per-provider breakdown — a fresh
    /// `aggregator.perProviderTotals()` call could race a concurrent
    /// provider emit through actor reentrancy.
    private var lastTotals: (today: DayTotals, prev: DayTotals?, slices: [ProviderSlice])?
    /// Tracks whole-dollar cost crossings so the menubar pop-up can celebrate
    /// them. Owned here so it sees the same `today` totals
    /// `rebuildAndBroadcast` does and lives independent of the JSONL state
    /// the readers persist. Snapshot on disk lives next to
    /// `usage-state.json`.
    /// Polls Claude Code's subscription windows. Constructed unconditionally
    /// so the toggle can start it later without rebuilding the provider list;
    /// it does nothing until `start` is called.
    private let claudeLimitsProbe: ClaudeLimitsProbe

    init(
        config: ServerConfig,
        group: EventLoopGroup,
        configURL: URL = ServerConfig.defaultURL
    ) {
        self.config = config
        self.group = group
        self.configURL = configURL
        self.hub = Hub()
        self.primaryMetric = config.resolvedPrimaryMetric

        // Resolve provider toggles. Unset (nil) means "let the daemon
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
            // a daemon upgrade skip the cold backfill instead of stranding
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
        daemonLog(
            "sissy-serverd: providers — "
                + "claude-code=\(claudeOn ? "on" : "off"), "
                + "codex=\(codexOn ? "on" : "off")\(codexResolution)"
        )
    }

    /// Client asked us to switch the primary metric (tokens / burn_rate).
    /// Rebuild and re-broadcast the last frame so the menubar + OLED update
    /// immediately instead of waiting for the next JSONL change.
    func setPrimaryMetric(_ raw: String) async {
        let metric = PrimaryMetric(rawValue: raw) ?? .tokens
        if metric == primaryMetric { return }
        primaryMetric = metric
        await rebroadcastFromCache()
    }

    /// Pin/unpin the mascot state. Pass nil (or "auto") to clear and let the
    /// computed state through. Immediately re-broadcasts the cached totals
    /// so the UI flips without hopping into the aggregator actor — that
    /// hop can queue behind a running poll and add 50–200 ms of lag.
    /// Turn the Claude Code limit probe on or off and persist the choice.
    /// Starting it is what triggers the one-time keychain prompt, so this is
    /// only ever reached from an explicit user action.
    func setClaudeLimits(enabled: Bool) async {
        if enabled == config.claudeLimits { return }
        config.claudeLimits = enabled
        do {
            try ServerConfig.save(config, to: configURL)
        } catch {
            daemonLog(
                "sissy-serverd: failed to persist claudeLimits to \(configURL.path): \(error)")
        }
        if enabled {
            await startClaudeLimitsProbe()
        } else {
            await claudeLimitsProbe.stop()
        }
        await rebroadcastFromCache()
    }

    private func startClaudeLimitsProbe() async {
        let me = self
        await claudeLimitsProbe.start {
            await me.rebroadcastFromCache()
        }
    }

    /// Re-emit a frame using the most recently observed totals. No-op if the
    /// reader hasn't produced a frame yet — the pending pin will take effect
    /// on the first real poll.
    ///
    /// The totals are read *after* the slice fetch on purpose. That `await` is
    /// a suspension point a provider emit can land in, and totals read before
    /// it would be the ones that emit has already superseded — rebroadcasting
    /// them puts the token count backwards and re-caches the stale pair for
    /// every client that connects next.
    func rebroadcastFromCache() async {
        let slices = await aggregator.currentSlices()
        guard let totals = lastTotals else { return }
        await rebuildAndBroadcast(today: totals.today, prev: totals.prev, slices: slices)
    }

    func start() async throws {
        startedAt = Date()
        // Bind first so clients can connect immediately. Each provider's
        // initial backfill scan can take several seconds on a multi-MB
        // log tree (`~/.claude/projects`, `~/.codex/sessions`, …); we let
        // them run after the socket is open.
        try await bootstrap()
        // Settle on one catalog before the cold scan starts, so the backfill
        // prices historical events against the same rates the live tail will
        // use. A refresh does not reprice what it already counted, so a catalog
        // that lands mid-scan would leave the day split across two rate sets.
        if config.remotePricingEnabled {
            await resolveInitialPriceCatalog()
        } else {
            daemonLog("sissy-serverd: remote pricing disabled — using the embedded rate seed")
        }
        daemonLog(
            "sissy-serverd: claude limits — \(config.claudeLimits ? "on" : "off")")
        if config.claudeLimits {
            await startClaudeLimitsProbe()
        }
        let server = self
        bootTask = Task.detached { [aggregator] in
            await aggregator.start { today, prev, slices in
                await server.rebuildAndBroadcast(today: today, prev: prev, slices: slices)
            }
        }
    }

    /// Picks the rate catalog the cold backfill will run against, then starts
    /// the background refresh loop.
    ///
    /// Order matters: a usable cache is applied synchronously, and when there
    /// is none the first fetch is awaited under a short budget rather than left
    /// to race the backfill. Either way the scan sees one catalog for its whole
    /// run. Falling through to the seed is a deliberate outcome, not a failure
    /// — the refresh loop keeps retrying behind it.
    private func resolveInitialPriceCatalog() async {
        var resolved: PriceCatalog?
        var initialDelay: Duration = .zero
        if let cached = PriceCatalogSource.loadCache() {
            resolved = cached
            let age = Date().timeIntervalSince(cached.fetchedAt)
            initialDelay = PriceCatalogSource.refreshDelay(forCacheAge: age)
            daemonLog("sissy-serverd: pricing from cached catalog, \(Int(age / 3600))h old")
        } else if let fetched = await PriceCatalogSource.fetchForColdStart() {
            resolved = fetched
            initialDelay = PriceCatalogSource.refreshInterval
            PriceCatalogSource.saveCache(fetched)
            daemonLog(
                "sissy-serverd: pricing catalog fetched before backfill — "
                    + "anthropic=\(fetched.anthropic.count), openai=\(fetched.openai.count)")
        } else {
            daemonLog(
                "sissy-serverd: no usable pricing cache and no catalog within "
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

    func stop() async {
        // Cancel the aggregator boot Task first so the cold scan observes
        // cancellation and bails out of its file enumeration loops before
        // the channel close handshake even starts.
        bootTask?.cancel()
        priceCatalogTask?.cancel()
        try? await channel?.close().get()
        await claudeLimitsProbe.stop()
        await aggregator.stop()
        bootTask = nil
        priceCatalogTask = nil
    }

    func healthSnapshot() async -> HealthResponse {
        let files = aggregator.filesWatched()
        // Suppress "no-jsonl-found" until the initial cold scan has completed.
        // `bootstrap()` brings the HTTP server up before `aggregator.start()`
        // runs its first enumeration, so without this gate the frontend
        // briefly observes `files == 0` and flashes the yellow "No JSONL"
        // warning every time the daemon is (re)started, even on a tree
        // with hundreds of session files.
        let coldDone = await aggregator.isWarm()
        let usageStatus = (coldDone && files == 0) ? "no-jsonl-found" : "ok"
        return HealthResponse(
            status: "ok",
            usageReader: usageStatus,
            uptimeSeconds: Int(Date().timeIntervalSince(startedAt))
        )
    }

    private let isoFormatter = ISO8601DateFormatter()

    func statsSnapshot() async -> StatsResponse {
        let count = await hub.connectedCount()
        let lastAt = await hub.lastFrameTimestamp()
        let files = aggregator.filesWatched()
        return StatsResponse(
            connectedClients: count,
            filesWatched: files,
            lastFrameAt: lastAt.map { isoFormatter.string(from: $0) }
        )
    }

    private func rebuildAndBroadcast(
        today: DayTotals,
        prev: DayTotals?,
        slices: [ProviderSlice]
    ) async {
        lastTotals = (today, prev, slices)
        let now = Date()
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: now)
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
            primaryMetric: primaryMetric,
            providers: slices
        )
        await hub.broadcast(frame)
    }

    private func bootstrap() async throws {
        let server = self
        let hub = self.hub
        let expectedToken = config.authToken

        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: 1 << 14,
            shouldUpgrade: { (channel: any Channel, head: HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?> in
                let auth = head.headers["authorization"].first
                if !Auth.authorized(headerValue: auth, expected: expectedToken) {
                    return channel.eventLoop.makeSucceededFuture(nil)
                }
                if head.uri != "/ws" {
                    return channel.eventLoop.makeSucceededFuture(nil)
                }
                return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { (channel: any Channel, _: HTTPRequestHead) -> EventLoopFuture<Void> in
                let handler = WebSocketSinkHandler(hub: hub, server: server)
                return channel.pipeline.addHandler(handler).flatMap {
                    channel.eventLoop.makeSucceededFuture(())
                }
            }
        )

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let httpHandler = HTTPRequestHandler(
                    expectedToken: expectedToken,
                    healthSnapshot: { await server.healthSnapshot() },
                    statsSnapshot: { await server.statsSnapshot() }
                )
                let upgradeConfig: NIOHTTPServerUpgradeConfiguration = (
                    upgraders: [upgrader],
                    completionHandler: { _ in
                        channel.pipeline.removeHandler(httpHandler, promise: nil)
                    }
                )
                return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: upgradeConfig)
                    .flatMap { channel.pipeline.addHandler(httpHandler) }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            // Belt-and-suspenders to the application-level WS heartbeat in
            // `WebSocketSinkHandler`. macOS keepidle defaults to ~2 hours so
            // this alone wouldn't catch a dead firmware sink in time, but
            // pairing it with the WS ping covers the case where the socket
            // is alive at the kernel level yet stuck before reaching the
            // handler. Cheap to enable.
            .childChannelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)

        channel = try await bootstrap.bind(host: config.host, port: config.port).get()
    }
}
