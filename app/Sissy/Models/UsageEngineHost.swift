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
    /// Whether Claude's limits come from the CLI's own credential file rather
    /// than from the keychain item or an imported claude.ai session. When they
    /// do, neither of those is read at all, and Settings has to say so instead
    /// of offering a control over a source nothing is using.
    private(set) var claudeUsesOwnCredential: Bool = false
    /// Days the archive is kept for, as `server.json` resolves it. Read from
    /// the same place and for the same reason as the rest: Settings
    /// says what the engine is actually doing, not what the app assumed.
    private(set) var historyRetentionDays: Int = UsageHistoryStore.defaultRetentionDays
    /// Whether the keep-awake hold is set to cover the screen. Read from
    /// `server.json` for the same reason as the rest: the engine owns
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
        claudeUsesOwnCredential = engine.claudeUsesOwnCredential
        historyRetentionDays = config.resolvedHistoryRetentionDays
        keepScreenAwake = config.keepScreenAwake
        keepAwakeMode = config.keepAwake
        agentHooks = config.agentHooks
        // Re-affirmed at every launch rather than written once: the CLIs
        // rewrite these files themselves, and a line that has gone has to come
        // back without the user noticing it was missing.
        if config.agentHooks || config.agentHooksRemovalPending {
            applyAgentHooks(config.agentHooks)
        }
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

    /// Why the last account switch did not happen, or nil when none has
    /// failed. Published because a switch that silently does nothing leaves
    /// the user typing `claude` and meeting the account they just left.
    private(set) var accountSwitchFailure: String?
    /// Every Claude Code account Sissy has archived, and which one is signed
    /// in. Refreshed from the engine rather than held here, so the app keeps
    /// no second copy of something the keychain decides.
    private(set) var claudeAccounts = ClaudeAccountRegistry.Snapshot()

    /// Makes an archived account the one Claude Code starts as.
    ///
    /// Sissy holds its own copy of every account it has seen signed in, so
    /// this overwrites the CLI's slots without putting any credential beyond
    /// recovery — which is the whole difference from the version that lost
    /// one.
    func activateClaudeAccount(uuid: String) {
        guard let engine else { return }
        accountSwitchFailure = nil
        Task { [weak self] in
            let outcome = await engine.activateClaudeAccount(uuid: uuid)
            if case .failure(let why) = outcome {
                self?.accountSwitchFailure = ClaudeAccountSwitchCopy.failure(why)
            }
            self?.claudeAccounts = engine.claudeAccountSnapshot
        }
    }

    /// Forgets one archived account, for the user who wants a stored secret
    /// gone. A keychain that refused is said out loud rather than reported as
    /// a deletion that did not happen.
    func forgetClaudeAccount(uuid: String) {
        guard let engine else { return }
        accountSwitchFailure = nil
        Task { [weak self] in
            do {
                try await engine.forgetClaudeAccount(uuid: uuid)
            } catch {
                self?.accountSwitchFailure = ClaudeAccountSwitchCopy.forgetFailure
            }
            self?.claudeAccounts = engine.claudeAccountSnapshot
        }
    }

    /// Whether a claude.ai session is filed, so Settings can offer the right
    /// button. Asked without decrypting one, so it is answerable on a build
    /// whose keychain grant has lapsed.
    private(set) var claudeWebSession: Bool = ClaudeWebSessionStore.isPresent()
    /// Why the last import found nothing, kept so Settings says which of the
    /// several ways it can come up empty happened. Cleared by the next
    /// attempt, and by a successful one.
    private(set) var claudeWebImportFailure: ClaudeWebCookieImport.Failure?
    private(set) var importingClaudeWebSession = false

    /// Imports the session Claude.app is holding. The click that is allowed
    /// to raise the Safe Storage dialog, and the only one.
    func importClaudeWebSession() {
        guard let engine, !importingClaudeWebSession else { return }
        importingClaudeWebSession = true
        claudeWebImportFailure = nil
        Task { [weak self] in
            let outcome = await engine.importClaudeWebSession()
            guard let self else { return }
            importingClaudeWebSession = false
            claudeWebSession = engine.hasClaudeWebSession
            if case .failure(let why) = outcome { claudeWebImportFailure = why }
        }
    }

    /// Forgets it, handing the reading back to the OAuth probe.
    func forgetClaudeWebSession() {
        guard let engine, claudeWebSession else { return }
        claudeWebImportFailure = nil
        Task { [weak self] in
            await engine.forgetClaudeWebSession()
            self?.claudeWebSession = engine.hasClaudeWebSession
        }
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

    /// Writes the archive out as CSV under `directory`, and answers with how
    /// many day files went into it — zero when there is nothing recorded,
    /// which the caller says rather than leaving three header-only files
    /// somebody has to open to find out.
    ///
    /// The read is the engine's because the project paths are re-resolved
    /// against the ledger it owns; the write is neither's, and runs detached
    /// so a user's slow volume stalls the export rather than the metering or
    /// the main thread.
    func exportUsageHistory(to directory: URL) async throws -> Int {
        guard let engine else { return 0 }
        let days = await engine.exportableHistory()
        guard !days.isEmpty else { return 0 }
        try await Task.detached { try UsageHistoryExport.write(days, to: directory) }.value
        return days.count
    }

    /// Deletes the archive. The engine re-emits once it is gone, which is
    /// what takes the panel's archive line away with it.
    func deleteUsageHistory() {
        guard let engine else { return }
        Task { await engine.deleteHistory() }
    }

    func setAgentHooks(_ enabled: Bool) {
        guard enabled != agentHooks else { return }
        agentHooks = enabled
        applyAgentHooks(enabled)
    }

    /// The same pass again, on the one gesture there is for a configuration
    /// Sissy could not write. A failed *removal* is what needs it: the switch
    /// is already off, so nothing else on this path would ever try again until
    /// the next launch.
    func retryAgentHooks() { applyAgentHooks(agentHooks) }

    /// Registers or unregisters the hook with both CLIs.
    ///
    /// Off the main actor: it reads and rewrites two files and spawns `sh -n`
    /// to check what it is about to write, and it runs at every launch. This
    /// app already measures its own main-thread cost in single percent points.
    ///
    /// Nothing here is fatal to metering: a file Sissy could not rewrite is
    /// named back to the user and left exactly as it was found — and the
    /// intent is written to `server.json` *before* either file is touched, so
    /// a removal interrupted half-way is retried at the next launch instead of
    /// leaving a line in someone else's configuration under a switch that is
    /// already off.
    private func applyAgentHooks(_ enabled: Bool) {
        guard let engine else { return }
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
        if enabled && script == nil {
            agentHooksRefused = [AgentHookCopy.missingScript]
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
            // Persist the retry before touching either foreign configuration.
            await engine.setAgentHooks(enabled: enabled, removalPending: !enabled)
            let installer = AgentHookInstaller(stateDirectory: stateDirectory, targets: targets)
            let report: [AgentHookTarget: AgentHookOutcome]
            if enabled, let script {
                report = installer.install(bundledScript: script)
            } else {
                report = installer.remove()
            }
            let refused =
                report
                .filter { _, outcome in outcome == .failed || outcome == .unreadable }
                .keys.map(\.name)
                .sorted()
            await engine.setAgentHooks(enabled: enabled, removalPending: !enabled && !refused.isEmpty)
            await MainActor.run {
                guard host.agentHooksGeneration == generation else { return }
                host.agentHooksRefused = refused
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
