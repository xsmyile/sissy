import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

actor SissyServer {
    /// In-memory, mutable mirror of the persisted `ServerConfig`. Runtime
    /// changes (e.g. milestone preset picker) update this and call
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
    private var startedAt: Date = .distantPast
    private var primaryMetric: PrimaryMetric
    /// Client-imposed mascot override. When non-nil, every outgoing frame
    /// has its `state` field replaced before broadcast so menubar + OLED
    /// stay in lock-step. Memory-only — clears on daemon restart.
    private var pinnedState: String?
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
    private var milestones: MilestoneTracker = MilestoneTracker()

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
                    pricingOverride: config.pricingOverride
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
    func setPinnedState(_ raw: String?) async {
        let normalized: String?
        if let raw, raw != "auto", !raw.isEmpty {
            normalized = raw
        } else {
            normalized = nil
        }
        if normalized == pinnedState { return }
        pinnedState = normalized
        await rebroadcastFromCache()
    }

    /// Client asked us to switch the milestone preset. Persists the change
    /// to `server.json` so it survives a restart, applies the new step
    /// values to the live tracker (silent reseed — same semantics as
    /// midnight rollover, no spurious burst of "missed" milestones), and
    /// re-broadcasts the cached frame so any subscribed UI updates its
    /// picker state immediately.
    func setMilestoneFrequency(_ raw: String) async {
        guard MilestoneFrequency.isValid(raw) else { return }
        guard raw != config.milestoneFrequency else { return }
        config.milestoneFrequency = raw
        do {
            try ServerConfig.save(config, to: configURL)
        } catch {
            // Disk full / permission denied / read-only volume — config
            // change still applies in memory but won't survive a restart.
            // Log once so the user can correlate the lost preference next
            // boot; don't fail the call because the runtime change is still
            // useful even without persistence.
            FileHandle.standardError.write(
                Data(
                    "sissy-serverd: failed to persist milestoneFrequency to \(configURL.path): \(error)\n"
                        .utf8))
        }
        let costStep = MilestoneFrequency.costStep(for: raw)
        milestones.applyPreset(presetKey: raw, costStep: costStep)
        milestones.save()
        await rebroadcastFromCache()
    }

    /// Read-only accessor for control handlers that need to echo the current
    /// preset back to a connecting client (so the menubar picker shows the
    /// right item checked when a new app instance connects to a long-running
    /// daemon that was set elsewhere).
    func currentMilestoneFrequency() -> String { config.milestoneFrequency }

    /// Re-emit a frame using the most recently observed totals. No-op if the
    /// reader hasn't produced a frame yet — the pending pin will take effect
    /// on the first real poll.
    private func rebroadcastFromCache() async {
        guard let totals = lastTotals else { return }
        await rebuildAndBroadcast(today: totals.today, prev: totals.prev, slices: totals.slices)
    }

    func currentPinnedState() -> String? { pinnedState }

    func start() async throws {
        startedAt = Date()
        // Restore persisted milestone buckets so a daemon restart doesn't
        // replay every crossing the user has already crossed today. On a
        // fresh install (or after midnight) the file is missing or stale —
        // the tracker seeds itself from the first totals it sees so the
        // user's accumulated spend never burst-fires historical milestones.
        let costStep = MilestoneFrequency.costStep(for: config.milestoneFrequency)
        milestones = MilestoneTracker.loadOrFresh(
            presetKey: config.milestoneFrequency,
            costStep: costStep
        )
        // Bind first so clients can connect immediately. Each provider's
        // initial backfill scan can take several seconds on a multi-MB
        // log tree (`~/.claude/projects`, `~/.codex/sessions`, …); we let
        // them run after the socket is open.
        try await bootstrap()
        let server = self
        bootTask = Task.detached { [aggregator] in
            await aggregator.start { today, prev, slices in
                await server.rebuildAndBroadcast(today: today, prev: prev, slices: slices)
            }
        }
    }

    func stop() async {
        // Cancel the aggregator boot Task first so the cold scan observes
        // cancellation and bails out of its file enumeration loops before
        // the channel close handshake even starts.
        bootTask?.cancel()
        try? await channel?.close().get()
        await aggregator.stop()
        bootTask = nil
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

    func statsSnapshot() async -> StatsResponse {
        let count = await hub.connectedCount()
        let lastAt = await hub.lastFrameTimestamp()
        let files = aggregator.filesWatched()
        let iso = ISO8601DateFormatter()
        return StatsResponse(
            connectedClients: count,
            filesWatched: files,
            lastFrameAt: lastAt.map { iso.string(from: $0) }
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
        let dayKey = MilestoneTracker.dayKey(from: startOfDay)
        // Defer milestone evaluation until the cold backfill scan has settled.
        // During cold scan `today.totalTokens` grows from 0 to its real value
        // over several emits; running `check` against partial totals would
        // either re-announce crossings the user already saw (when persisted
        // bucket is correct) or — combined with the snap-down ratchet —
        // fire one notification per emit threshold crossed during the scan.
        // Once the reader is warm, today reflects the full in-window state
        // and `check` runs normally.
        var milestone: String? = nil
        if await aggregator.isWarm() {
            milestone = milestones.check(today: today, dayKey: dayKey)
            if milestone != nil || milestones.persistenceDirty {
                milestones.save()
            }
        }
        // Slices arrive captured against the same `perProvider` snapshot the
        // aggregator used to compute `today`/`prev` (or replayed from
        // `lastTotals` on a pin/metric-toggle rebuild). A fresh
        // `perProviderTotals()` call here would race actor reentrancy and
        // could ship a frame whose scalars and breakdown disagree.
        var frame = FrameBuilder.build(
            today: today,
            prev: prev,
            hoursElapsed: hoursElapsed,
            primaryMetric: primaryMetric,
            thresholds: config.stateThresholds,
            milestone: milestone,
            providers: slices
        )
        if let pin = pinnedState {
            frame = FrameData(
                tokens: frame.tokens,
                cost: frame.cost,
                burn: frame.burn,
                state: pin,
                primary: frame.primary,
                primaryLabel: frame.primaryLabel,
                milestone: frame.milestone,
                providers: frame.providers
            )
        }
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

/// Cost-step value (whole USD) for each preset key. The pairing with token
/// steps was dropped because token totals aren't comparable across models or
/// agents — cost is the universal denominator that survives multi-model and
/// multi-provider expansion. The default `"normal"` keeps the historical $25.
enum MilestoneFrequency {
    static let defaultKey = "normal"

    /// Source of truth for both the daemon and the app's menubar picker.
    /// Order matters — the app renders the submenu in this order.
    static let presets: [(key: String, costStep: Int)] = [
        ("very_frequent", 5),
        ("frequent", 10),
        ("normal", 25),
        ("sparse", 50),
        ("rare", 100),
    ]

    /// Returns the configured cost step, falling back to `"normal"` for an
    /// unknown key. Unknown keys arrive when a config file pre-dates the
    /// preset machinery or has been hand-edited to a typo.
    static func costStep(for key: String) -> Int {
        if let p = presets.first(where: { $0.key == key }) {
            return p.costStep
        }
        return presets.first(where: { $0.key == defaultKey })!.costStep
    }

    static func isValid(_ key: String) -> Bool {
        presets.contains(where: { $0.key == key })
    }
}

/// Detects whole-dollar cost crossings within a calendar day and produces a
/// milestone string to attach to the next outgoing frame. The step value is
/// configurable per session via `MilestoneFrequency`.
///
/// Init seeding: the first call on a fresh day sets the bucket counter from
/// the current totals so a daemon that boots mid-session with non-zero spend
/// doesn't burst-fire every milestone the user already crossed. The first
/// notification of the day lands on the next genuine crossing.
///
/// Persistence: state is saved next to `usage-state.json` so a daemon
/// restart picks up where it left off. The day key in the file lets us
/// detect midnight rollover even if the daemon was offline across it. The
/// preset key lets us detect a frequency change since last save and silently
/// reseed the bucket (bucket=4 meant "$100" at step=$25 but "$200" at
/// step=$50 — replaying without reseed would either suppress notifications
/// forever or fire stale ones).
struct MilestoneTracker: Codable {
    /// YYYY-MM-DD for the day this bucket belongs to. Nil = uninitialized
    /// or pending reseed (e.g. preset change).
    var dayKey: String?
    /// `totalCostInDollars / costStep` at the last observed totals for
    /// this day. Integer dollars; sub-dollar cost noise can't move it.
    var costBucket: Int = 0
    /// Preset key the persisted bucket was computed against. Compared to
    /// the current config at load time — a mismatch flips `dayKey` to nil so
    /// the next `check` call reseeds against the new step value without
    /// firing.
    var presetKey: String?

    /// Active step value. Not encoded — derived from the current config at
    /// load time. Default matches the `"normal"` preset for round-tripping
    /// tests that don't go through `loadOrFresh`.
    var costStep: Int = 25

    /// Set by `check` when on-disk state needs refreshing — bucket advanced,
    /// day rolled, preset changed, or first-call seed. Caller saves and
    /// clears it via the `save()` method.
    private(set) var persistenceDirty: Bool = false

    enum CodingKeys: String, CodingKey {
        case dayKey, costBucket, presetKey
    }

    init(
        presetKey: String? = nil,
        costStep: Int = 25
    ) {
        self.presetKey = presetKey
        self.costStep = costStep
    }

    /// Custom decoder so a pre-preset-era snapshot (no `presetKey` field) or
    /// a pre-cost-only snapshot (still carrying `tokenBucket`) decodes
    /// cleanly. Stale fields are ignored; missing fields default. A nil
    /// `presetKey` triggers the load-time mismatch branch in `loadOrFresh`
    /// for a silent reseed against current config.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dayKey = try c.decodeIfPresent(String.self, forKey: .dayKey)
        costBucket = try c.decodeIfPresent(Int.self, forKey: .costBucket) ?? 0
        presetKey = try c.decodeIfPresent(String.self, forKey: .presetKey)
    }

    /// Compute the milestone (if any) the next outgoing frame should carry,
    /// given the running totals and the calendar day they belong to.
    /// Returns nil when nothing crosses. The crossing math is integer
    /// division so floating-point drift on `Decimal → Double` can't fire
    /// spurious milestones.
    mutating func check(today: DayTotals, dayKey: String) -> String? {
        if self.dayKey != dayKey {
            // Either first-ever call, the calendar day rolled, or a preset
            // change just nil'd `dayKey`. Seed the bucket from current
            // totals so we don't fire the milestones the user already
            // passed today (or yesterday — daemon may have been offline
            // across midnight on a heavy day).
            self.dayKey = dayKey
            costBucket = Self.dollars(today.totalCost) / costStep
            persistenceDirty = true
            return nil
        }

        let newCostBucket = Self.dollars(today.totalCost) / costStep

        // Defensive snap-down: if the persisted bucket exceeds what today's
        // totals would imply, lower it silently. Triggers only after a
        // persistence-data shrink across daemon restarts (e.g. retention
        // window change invalidates the usage snapshot, dedup keys reset
        // and cold scan recomputes today smaller than the previously
        // saved milestone bucket implied). Today's totals only grow
        // within a session, so this branch never fires in steady state.
        // Without it, every milestone in the gap between
        // `newBucket+1 ... persistedBucket` gets permanently swallowed.
        if newCostBucket < costBucket {
            costBucket = newCostBucket
            persistenceDirty = true
        }

        if newCostBucket > costBucket {
            let value = newCostBucket * costStep
            costBucket = newCostBucket
            persistenceDirty = true
            return "cost:\(value)"
        }
        return nil
    }

    /// Folds a `Decimal` cost to its whole-dollar integer part via truncation
    /// (NSDecimalNumber.intValue rounds toward zero). $24.99 stays in the
    /// $24 bucket and only $25.00 flips to $25. `FrameBuilder.fmtCost` must
    /// truncate the same way in its ≥100 branch or the milestone headline
    /// and the subline cost desync by a dollar at every crossing.
    static func dollars(_ d: Decimal) -> Int {
        NSDecimalNumber(decimal: d).intValue
    }

    static func dayKey(from startOfDay: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f.string(from: startOfDay)
    }

    static var persistenceURL: URL {
        SissyPaths.appSupportDir.appendingPathComponent("milestones.json")
    }

    /// Loads persisted state, or returns a fresh tracker. Soft-fail on any
    /// read or decode error — the worst case is one missed milestone on the
    /// next crossing, which the seed path eats anyway. If the loaded preset
    /// key differs from the current config (frequency change since last
    /// save, or a pre-preset-era snapshot with nil presetKey), `dayKey` is
    /// nil'd to force the seed path on the next `check` call. That reseeds
    /// the buckets against the new step values without firing — same
    /// semantics as midnight rollover.
    static func loadOrFresh(
        presetKey: String,
        costStep: Int
    ) -> MilestoneTracker {
        guard let data = try? Data(contentsOf: persistenceURL),
            var decoded = try? JSONDecoder().decode(MilestoneTracker.self, from: data)
        else {
            return MilestoneTracker(presetKey: presetKey, costStep: costStep)
        }
        decoded.costStep = costStep
        if decoded.presetKey != presetKey {
            decoded.dayKey = nil
            decoded.presetKey = presetKey
            decoded.persistenceDirty = true
        }
        return decoded
    }

    /// Apply a runtime preset change. Same effect as the load-time mismatch
    /// branch: swap in the new step value and nil `dayKey` so the next
    /// `check` reseeds against today's totals. No fire on this transition.
    mutating func applyPreset(presetKey: String, costStep: Int) {
        guard self.presetKey != presetKey else { return }
        self.costStep = costStep
        self.presetKey = presetKey
        self.dayKey = nil
        self.persistenceDirty = true
    }

    mutating func save() {
        defer { persistenceDirty = false }
        let url = Self.persistenceURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}
