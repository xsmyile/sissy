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

    @ObservationIgnored private weak var model: SissyModel?
    @ObservationIgnored private var engine: UsageEngine?
    @ObservationIgnored private var readinessTask: Task<Void, Never>?
    /// Handle on the engine's own boot, so `stop()` has something to cancel
    /// rather than leaving a `start()` in flight against an engine it has
    /// already let go of.
    @ObservationIgnored private var bootTask: Task<Void, Never>?

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
        readinessTask?.cancel()
        readinessTask = nil
        bootTask?.cancel()
        bootTask = nil
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

    func setKeepAwake(mode: KeepAwakeMode) {
        guard let engine else { return }
        Task { await engine.setKeepAwake(mode: mode.rawValue) }
    }

    /// Deletes the archive. The engine re-emits once it is gone, which is
    /// what takes the panel's archive line away with it.
    func deleteUsageHistory() {
        guard let engine else { return }
        Task { await engine.deleteHistory() }
    }

    private func deliver(_ frame: FrameData) {
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
