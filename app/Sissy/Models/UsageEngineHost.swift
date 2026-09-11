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
    /// Whether the Claude Code limit probe is on. Read from `server.json`,
    /// which the engine owns: the app keeps no second copy, because the one
    /// it used to keep could disagree with the file the probe actually booted
    /// from.
    private(set) var claudeLimits: Bool = false

    @ObservationIgnored private weak var model: SissyModel?
    @ObservationIgnored private var engine: UsageEngine?
    @ObservationIgnored private var readinessTask: Task<Void, Never>?

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
        let host = self
        Task {
            await engine.setObserverPresent(true)
            await engine.start { frame in
                await host.deliver(frame)
            }
        }
        pollReadiness()
    }

    func stop() {
        readinessTask?.cancel()
        readinessTask = nil
        guard let engine else { return }
        self.engine = nil
        Task { await engine.stop() }
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

    private func deliver(_ frame: FrameData) {
        model?.applyFrame(frame)
    }

    private func pollReadiness() {
        readinessTask?.cancel()
        let host = self
        readinessTask = Task {
            while !Task.isCancelled {
                guard let engine = host.engine else { return }
                let readiness = await engine.readiness()
                host.filesWatched = readiness.filesWatched
                host.isWarm = readiness.isWarm
                if readiness.isWarm { return }
                try? await Task.sleep(for: Self.readinessPollInterval)
            }
        }
    }
}
