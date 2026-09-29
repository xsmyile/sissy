import Foundation

/// A reading whose rate the engine logs in the background and publishes only
/// while the page that shows it is on screen.
///
/// **A page asks, the engine publishes.** A rate a second is only worth
/// taking while it is being watched, so the panel says which of these its open
/// page draws and only that page is sent samples. What is kept with nobody
/// looking is the counters' last two minutes at `LiveCadence.background`, so
/// the page opens on a line rather than on an empty axis, decided 2026-09-28.
enum LiveReading: Hashable, Sendable, CaseIterable {
    case network
    case disk
}

/// How often a live monitor reads its counters, and what a gap is at that
/// pace.
///
/// **Two cadences and one series.** While the page that draws a reading is on
/// screen its monitor reads once a second and publishes each sample; with the
/// page gone and the switch on it reads every five seconds and publishes
/// nothing, so the page opens on the last `window` rather than on an empty
/// axis. The two cadences feed one series, which is why every point carries
/// its time and the sparklines place it by that time rather than by its index.
///
/// **What the background costs.** Measured 2026-09-28 on a Mac16,8 running
/// macOS 27.0, with `LiveSampling` and both monitors built with `-O` into a
/// harness reading the real counters for 300 s: 54 wakeups, 5.0 to 6.0 s
/// apart and 5.7 s on average, so macOS does take the tolerance; the two
/// counter reads cost 0.52 ms of CPU a wakeup, cold where a read a second is
/// warm, and the process 0.14 ms a second against 0.001 ms for the same
/// harness idle. That is about a tenth of the 1.2 to 2.0 ms a second that
/// reading once a second costs, which is what the user declined.
enum LiveCadence: Sendable, Equatable {
    /// The page is on screen, and each sample is published to it.
    case watched
    /// The switch is on and no page draws the reading: the counters are read
    /// and the series kept, and nothing leaves the monitor.
    case background

    /// How much of the series is kept, which is what the sparklines draw.
    static let window: TimeInterval = 120

    /// How many steps of the cadence a gap may span before it restarts the
    /// series.
    ///
    /// Three is two missed samples. A sample late by its tolerance, or by a
    /// cooperative pool that held it up, is inside the bound at either pace;
    /// one that missed two is a Mac that slept or a process that was not
    /// scheduled, and the rate averaged over that would be drawn as a line
    /// across seconds nobody measured. Relative to the cadence rather than
    /// fixed, because at five seconds a fixed three-second bound would call
    /// every step a gap, and at one second a fifteen-second bound would draw
    /// a sleep's first seconds as a measurement.
    static let gapSteps: Double = 3

    var interval: Duration {
        switch self {
        case .watched: .seconds(1)
        case .background: .seconds(5)
        }
    }

    /// The leeway the sleep is given so macOS can coalesce the wakeup with
    /// others. None while watched, which is the pace the page's figures
    /// tick at; a fifth of the step in the background, where nobody sees the
    /// sample land.
    var tolerance: Duration? {
        switch self {
        case .watched: nil
        case .background: .seconds(1)
        }
    }

    /// The longest gap after a sample taken at this cadence that still counts
    /// as one step of the series.
    var maximumGap: TimeInterval { Self.gapSteps * (interval / .seconds(1)) }
}

/// One sample of a `LiveReading`, as it travels to the page that asked for it.
enum LiveSample: Sendable, Equatable {
    case network(NetworkReading)
    case disk(DiskActivityReading)
}

/// What `LiveSampling` drives: a monitor that runs watched or in the
/// background, and stops.
protocol LiveMonitor: Actor {
    associatedtype Reading: Sendable
    var cadence: LiveCadence? { get }
    func run(publishing onSample: LivePoll<Reading>.Deliver?)
    func stop()
}

/// The loop every live monitor runs, and the two facts it keeps: whether it
/// is running, and where a watched sample goes.
///
/// One copy because the rule it carries is the one `LiveCadence` names, and a
/// monitor written beside it would be a second place for that rule to drift.
/// The monitor keeps what differs, which is what one step reads.
struct LivePoll<Reading: Sendable> {
    typealias Deliver = @Sendable (Reading) async -> Void
    /// The cadence a step ran at, and the sample with where it goes when the
    /// step is watched. Nil ends the loop, which a monitor answers when
    /// `stop()` ran ahead of the step.
    typealias Step = (LiveCadence, (Reading, Deliver)?)

    private(set) var onSample: Deliver?
    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    /// The pace the loop runs at, nil while it is stopped.
    var cadence: LiveCadence? {
        guard isRunning else { return nil }
        return onSample == nil ? .background : .watched
    }

    /// Runs the loop, watched and publishing to `onSample` or in the
    /// background with nil, and hands one already running the new callback.
    ///
    /// **A page arriving interrupts the background's wait**, so its first
    /// sample is taken at once rather than up to five seconds later. A page
    /// leaving does not: the one-second wait in flight ends, the sample it
    /// ends in is kept and not published, and the next wait is five seconds.
    mutating func run(
        publishing onSample: Deliver?, step: @escaping @Sendable () async -> Step?
    ) {
        let wasWatched = self.onSample != nil
        self.onSample = onSample
        if isRunning, wasWatched || onSample == nil { return }
        task?.cancel()
        task = Task {
            while !Task.isCancelled {
                guard let (cadence, delivery) = await step() else { return }
                if let (reading, deliver) = delivery { await deliver(reading) }
                do {
                    try await Task.sleep(for: cadence.interval, tolerance: cadence.tolerance)
                } catch { return }
            }
        }
    }

    mutating func stop() {
        task?.cancel()
        task = nil
        onSample = nil
    }
}

/// Runs the live readings against each reading's own switch in `server.json`,
/// and sets their cadence against what the panel's page on screen asks for.
///
/// The engine holds one and forwards to it, so the rule is written once, here,
/// whatever the reading. A reading runs while it is in `enabled`, this has been
/// started and not stopped; it runs `LiveCadence.watched` and publishes while
/// it is also in `demand`, and `LiveCadence.background` otherwise. `stop()` is
/// terminal, because it is the engine's own, and a page asking afterwards must
/// not start a monitor behind an engine that is gone.
actor LiveSampling {
    private let network: NetworkMonitor
    private let disk: DiskActivityMonitor
    private var demand: Set<LiveReading> = []
    private var enabled: Set<LiveReading>
    private var onSample: (@Sendable (LiveSample) async -> Void)?
    private var isStarted = false
    private var isStopped = false

    init(network: NetworkMonitor, disk: DiskActivityMonitor, enabled: Set<LiveReading>) {
        self.network = network
        self.disk = disk
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

    /// The engine's start: the switched-on readings begin their background
    /// log. Before it a demand is held and not acted on.
    func start() async {
        isStarted = true
        await apply()
    }

    func stop() async {
        isStopped = true
        await apply()
    }

    /// Which readings are running and at what cadence, for a test to assert
    /// on.
    func running() async -> [LiveReading: LiveCadence] {
        var running: [LiveReading: LiveCadence] = [:]
        for reading in LiveReading.allCases {
            running[reading] = await cadence(of: reading)
        }
        return running
    }

    private func cadence(of reading: LiveReading) async -> LiveCadence? {
        switch reading {
        case .network: await network.cadence
        case .disk: await disk.cadence
        }
    }

    private func apply() async {
        for reading in LiveReading.allCases {
            let on = isStarted && !isStopped && enabled.contains(reading)
            let publish = demand.contains(reading) ? onSample : nil
            switch reading {
            case .network: await drive(network, on: on, publishing: publish) { .network($0) }
            case .disk: await drive(disk, on: on, publishing: publish) { .disk($0) }
            }
        }
    }

    private func drive<Monitor: LiveMonitor>(
        _ monitor: Monitor, on: Bool,
        publishing publish: (@Sendable (LiveSample) async -> Void)?,
        as sample: @escaping @Sendable (Monitor.Reading) -> LiveSample
    ) async {
        guard on else { return await monitor.stop() }
        guard let publish else { return await monitor.run(publishing: nil) }
        await monitor.run(publishing: { await publish(sample($0)) })
    }
}
