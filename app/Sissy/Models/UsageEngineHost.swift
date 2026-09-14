import Foundation
import Observation

/// Runs the metering engine inside the app and publishes what the surfaces
/// need from it.
///
/// The engine is an actor and the UI is `@MainActor`, so this is the one hop
/// between them: frames arrive here and land on `SissyModel` already on the
/// main actor, and every control the panel offers is forwarded the other way.
@MainActor
@Observable
final class UsageEngineHost {
    /// Whether the readers have finished their first pass over the log trees.
    ///
    /// Until they have, "no files" and "not looked yet" are the same zero,
    /// and the panel has to say the second rather than the first. A daemon
    /// warmed at login and the app connected to something already hot; in one
    /// process the first launch after an install pays that scan with the
    /// panel open.
    private(set) var isWarm: Bool = false
    private(set) var filesWatched: Int = 0
    /// Every provider Sissy knows about, metering or not. The Providers tab
    /// renders these; the two scalars above are the panel header's summary of
    /// the same list, so they cannot disagree with it.
    private(set) var providers: [ProviderReadiness] = []
    /// Whether the Claude Code limit probe is on. Read from `server.json`,
    /// which the engine owns: the app keeps no second copy, because the one
    /// it used to keep could disagree with the file the probe actually booted
    /// from.
    private(set) var claudeLimits: Bool = false
    /// Days the archive is kept for, as `server.json` resolves it. Read from
    /// the same place and for the same reason as `claudeLimits`: Settings
    /// says what the engine is actually doing, not what the app assumed.
    private(set) var historyRetentionDays: Int = UsageHistoryStore.defaultRetentionDays
    /// Whether the keep-awake hold is set to cover the screen. Read from
    /// `server.json` for the same reason as `claudeLimits`: the engine owns
    /// that file, and a second copy in the app could disagree with the one the
    /// assertions are actually taken from.
    private(set) var keepScreenAwake: Bool = true
    private(set) var agentHooks: Bool = false
    /// Set when the switch is on but a configuration file could not be
    /// rewritten — the name of the CLI whose file was left alone, so Settings
    /// can say which one rather than claiming the switch took effect.
    private(set) var agentHooksRefused: [String] = []
    /// Which registration attempt is current. Two quick toggles start two
    /// independent pieces of work, and installing is the slower of the two — it
    /// copies the script, spawns `sh -n` and takes a backup — so without this
    /// an enable that started first can land after the disable that replaced it
    /// and leave the caption describing a state that is no longer on disk.
    private var agentHooksGeneration = 0
    private var agentHooksTask: Task<Void, Never>?
    /// The keep-awake mode `server.json` holds, for the window before the
    /// first frame carries one.
    ///
    /// The engine takes the hold in `start()`, ahead of the readers' first
    /// pass, so there is a stretch — a price-catalog fetch and a cold scan —
    /// where the Mac is already being held and no frame has said so yet.
    /// Answering `off` across it is not a cosmetic lie: the panel and Settings
    /// render the mode as a radio group, which asserts a mode nobody chose,
    /// and `SissyModel.setKeepAwake` drops a request that matches what the app
    /// wrongly believes it is already in — so the click that would release the
    /// Mac reaches nothing. The frame is the record once one exists; this
    /// stands in until then, which is why it is kept in step at both ends.
    private(set) var keepAwakeMode: KeepAwakeMode = .off
    /// Which providers have a refresh in flight, so a surface can say it is
    /// refreshing rather than repeating an age that is about to change.
    private(set) var refreshing: Set<String> = []

    /// How long a refresh stays visible at the least.
    ///
    /// Not a delay on the work — the engine is already running by the time
    /// this is waited on — but a floor under the *word*. A Codex refresh
    /// re-reads one JSON file and returns inside a frame, so without a floor
    /// the label would never paint and the click would read as a button that
    /// does nothing, which is the complaint it exists to answer. A Claude
    /// refresh with the limits probe on makes a network call and never
    /// reaches the floor at all.
    private static let refreshFloor: Duration = .milliseconds(450)

    @ObservationIgnored private weak var model: SissyModel?
    @ObservationIgnored private var engine: UsageEngine?
    @ObservationIgnored private var readinessTask: Task<Void, Never>?
    /// Handle on the engine's own boot, so `stop()` has something to cancel
    /// rather than leaving a `start()` in flight against an engine it has
    /// already let go of.
    @ObservationIgnored private var bootTask: Task<Void, Never>?
    /// One handle per provider with a refresh in flight, which is what makes
    /// the work cancellable at shutdown and the button non-re-entrant: a
    /// second click while the first is still running has nothing to start.
    @ObservationIgnored private var refreshTasks: [String: Task<Void, Never>] = [:]

    /// How often the warming state is re-read while the cold scan runs. The
    /// readers emit nothing until they finish, so there is no frame to hang
    /// this off — and once warm the poll stops rather than running forever.
    private static let readinessPollInterval: Duration = .milliseconds(500)

    init() {}

    func attach(model: SissyModel) {
        self.model = model
    }

    func start() {
        guard engine == nil else { return }
        // A `server.json` that will not parse is not a reason to meter
        // nothing: `load` overlays what it can read onto the defaults, and
        // an unreadable file leaves the defaults, which are what a fresh
        // install runs on anyway.
        let config = (try? ServerConfig.load()) ?? .defaults
        let engine = UsageEngine(config: config)
        self.engine = engine
        claudeLimits = config.claudeLimits
        historyRetentionDays = config.resolvedHistoryRetentionDays
        keepScreenAwake = config.keepScreenAwake
        keepAwakeMode = config.keepAwake
        agentHooks = config.agentHooks
        // Re-affirmed at every launch rather than written once: the CLIs
        // rewrite these files themselves, and a line that has gone has to come
        // back without the user noticing it was missing.
        if config.agentHooks { applyAgentHooks(true) }
        let host = self
        bootTask = Task {
            await engine.start { frame in
                await host.deliver(frame)
            }
        }
        pollReadiness()
    }

    /// Stops metering and waits for it, so the readers get their final offset
    /// flush before the process goes. Cancelling `bootTask` is not what stops
    /// a boot still in flight — `engine.stop()` is, by clearing the flag
    /// `start()` re-reads after each of its suspensions.
    func stop() async {
        await agentHooksTask?.value
        agentHooksTask = nil
        readinessTask?.cancel()
        readinessTask = nil
        bootTask?.cancel()
        bootTask = nil
        refreshTasks.values.forEach { $0.cancel() }
        refreshTasks.removeAll()
        refreshing.removeAll()
        guard let engine else { return }
        self.engine = nil
        await engine.stop()
    }

    /// Re-reads what each provider is doing. The readiness poll below stops
    /// once the scan is warm, so a surface that opens later asks for itself
    /// rather than keeping a timer alive for the whole session.
    func refreshProviders() {
        guard let engine else { return }
        let host = self
        Task { host.apply(await engine.providerReadiness()) }
    }

    func setClaudeLimits(_ enabled: Bool) {
        guard let engine, enabled != claudeLimits else { return }
        claudeLimits = enabled
        Task { await engine.setClaudeLimits(enabled: enabled) }
    }

    /// Re-reads one provider's out-of-band state. On Claude Code this is the
    /// gesture that may raise the keychain dialog, which is why it is only
    /// ever reached from a click.
    ///
    /// The engine re-emits when it is done, so the reading's age resets on its
    /// own and nothing here has to tell the panel the numbers moved.
    func refreshProvider(_ id: String) {
        guard let engine, refreshTasks[id] == nil else { return }
        refreshing.insert(id)
        refreshTasks[id] = Task {
            let startedAt = ContinuousClock.now
            await engine.refreshProvider(id: id)
            if let rest = Self.remainingFloor(elapsed: ContinuousClock.now - startedAt) {
                try? await Task.sleep(for: rest)
            }
            refreshing.remove(id)
            refreshTasks[id] = nil
        }
    }

    /// What is left of the floor once the work has taken its time, and nil
    /// once there is nothing left to wait for.
    static func remainingFloor(elapsed: Duration) -> Duration? {
        elapsed < refreshFloor ? refreshFloor - elapsed : nil
    }

    func setKeepAwake(mode: KeepAwakeMode) {
        guard let engine else { return }
        keepAwakeMode = mode
        Task { await engine.setKeepAwake(mode: mode.rawValue) }
    }

    /// Deletes the archive. The engine re-emits once it is gone, which is
    /// what takes the panel's archive line away with it.
    func deleteUsageHistory() {
        guard let engine else { return }
        Task { await engine.deleteHistory() }
    }

    func setAgentHooks(_ enabled: Bool) {
        guard let engine, enabled != agentHooks else { return }
        agentHooks = enabled
        applyAgentHooks(enabled)
        Task { await engine.setAgentHooks(enabled: enabled) }
    }

    /// Registers or unregisters the hook with both CLIs.
    ///
    /// Off the main actor: it reads and rewrites two files and spawns `sh -n`
    /// to check what it is about to write, and it runs at every launch. This
    /// app already measures its own main-thread cost in single percent points.
    ///
    /// Nothing here is fatal to metering: a file Sissy could not rewrite is
    /// named back to the user and left exactly as it was found.
    private func applyAgentHooks(_ enabled: Bool) {
        // A test host is not a user launching Sissy. `xcodebuild test` runs the
        // app against this machine's real `Sissy-Dev` tree, so without this the
        // suite rewrites the developer's own `~/.claude/settings.json` and
        // `~/.codex/hooks.json` every time it runs.
        guard NSClassFromString("XCTestCase") == nil else { return }
        guard let home = AgentHookInstaller.userHome else {
            agentHooksRefused = [AgentHookCopy.unknownHome]
            return
        }
        let script = Bundle.main.url(forResource: "session-start", withExtension: "sh")
        guard let script else {
            if enabled { agentHooksRefused = [AgentHookCopy.missingScript] }
            return
        }
        let stateDirectory = ServerConfig.defaultURL.deletingLastPathComponent()
        let targets = AgentHookInstaller.targets(home: home)
        agentHooksGeneration += 1
        let generation = agentHooksGeneration
        let host = self
        let previous = agentHooksTask
        agentHooksTask = Task.detached(priority: .utility) {
            await previous?.value
            let installer = AgentHookInstaller(stateDirectory: stateDirectory, targets: targets)
            let report =
                enabled ? installer.install(bundledScript: script) : installer.remove()
            let refused =
                report
                .filter { _, outcome in outcome != .written && outcome != .unchanged }
                .keys.map(\.name)
                .sorted()
            await MainActor.run {
                guard host.agentHooksGeneration == generation else { return }
                host.agentHooksRefused = enabled ? refused : []
            }
        }
    }

    func setKeepScreenAwake(_ enabled: Bool) {
        guard let engine, enabled != keepScreenAwake else { return }
        keepScreenAwake = enabled
        Task { await engine.setKeepScreenAwake(enabled: enabled) }
    }

    private func deliver(_ frame: FrameData) {
        if frame.keepAwake.mode != keepAwakeMode { keepAwakeMode = frame.keepAwake.mode }
        model?.applyFrame(frame)
    }

    /// Folds the per-provider list into the two scalars the panel header
    /// reads. Only a metering provider has a scan, and an empty list is warm:
    /// a run with every provider switched off has nothing left to wait for,
    /// and must not pin the header in its cold-start placeholder.
    private func apply(_ readiness: [ProviderReadiness]) {
        providers = readiness
        let scans = readiness.compactMap(\.scan)
        filesWatched = scans.reduce(0) { $0 + $1.filesWatched }
        isWarm = scans.allSatisfy(\.isWarm)
    }

    private func pollReadiness() {
        readinessTask?.cancel()
        let host = self
        readinessTask = Task {
            while !Task.isCancelled {
                guard let engine = host.engine else { return }
                host.apply(await engine.providerReadiness())
                if host.isWarm { return }
                try? await Task.sleep(for: Self.readinessPollInterval)
            }
        }
    }
}
