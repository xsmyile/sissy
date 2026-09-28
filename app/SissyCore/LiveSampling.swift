import Foundation

/// A reading the engine takes only while the page that shows it is on screen.
///
/// **A page asks, the engine samples.** The rest of the engine's modules are
/// read whether anybody is looking or not, because each is cheap at the pace
/// it runs and what it answers is still true when the panel opens. A rate a
/// second is neither: it is only worth taking while it is being watched, and
/// what it answered a minute ago is not a reading of now. So the panel says
/// which of these its open page draws, and nothing else starts them.
enum LiveReading: Hashable, Sendable, CaseIterable {
    case network
}

/// One sample of a `LiveReading`, as it travels to the page that asked for it.
enum LiveSample: Sendable, Equatable {
    case network(NetworkReading)
}

/// Starts and stops the live readings against what the panel's page on screen
/// asks for, and against each reading's own switch in `server.json`.
///
/// The engine holds one and forwards to it, so the rule "sampled only while
/// wanted and switched on" is written once, here, whatever the reading. A
/// reading runs exactly while it is in `demand`, in `enabled`, and this has
/// not been stopped: `stop()` is terminal, because it is the engine's own, and
/// a page asking afterwards must not start a monitor behind an engine that is
/// gone.
actor LiveSampling {
    private let network: NetworkMonitor
    private var demand: Set<LiveReading> = []
    private var enabled: Set<LiveReading>
    private var onSample: (@Sendable (LiveSample) async -> Void)?
    private var isStopped = false

    init(network: NetworkMonitor, enabled: Set<LiveReading>) {
        self.network = network
        self.enabled = enabled
    }

    /// What the panel's page on screen draws, and where its samples go. The
    /// empty set is how a page that closes, or a tab that switches away, says
    /// it is done.
    func setDemand(
        _ demand: Set<LiveReading>, onSample: @Sendable @escaping (LiveSample) async -> Void
    ) async {
        self.demand = demand
        self.onSample = onSample
        await apply()
    }

    func setEnabled(_ reading: LiveReading, _ on: Bool) async {
        if on { enabled.insert(reading) } else { enabled.remove(reading) }
        await apply()
    }

    func stop() async {
        isStopped = true
        await apply()
    }

    /// Which readings are running, for a test to assert on.
    func running() async -> Set<LiveReading> {
        var running: Set<LiveReading> = []
        for reading in LiveReading.allCases where await isRunning(reading) {
            running.insert(reading)
        }
        return running
    }

    private func isRunning(_ reading: LiveReading) async -> Bool {
        switch reading {
        case .network: await network.isRunning
        }
    }

    private func apply() async {
        for reading in LiveReading.allCases {
            let wanted = !isStopped && demand.contains(reading) && enabled.contains(reading)
            switch reading {
            case .network:
                if wanted, let onSample {
                    await network.start { await onSample(.network($0)) }
                } else {
                    await network.stop()
                }
            }
        }
    }
}
