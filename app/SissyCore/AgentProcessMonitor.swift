import Foundation

/// What the agents are holding now, and what they have been holding since
/// Sissy started watching.
struct AgentMemoryReading: Sendable, Equatable {
    let current: AgentProcessReading
    /// One footprint per sample, oldest first, of the processes themselves.
    ///
    /// **In memory and nowhere else, which is the rule rather than an
    /// omission.** Nothing Sissy does to the machine outlives Sissy, and a
    /// memory graph is the clearest case of it: a reading from a Mac that was
    /// asleep is not a low reading, it is no reading, and a line drawn through
    /// the gap would claim an hour that never happened. So the series starts
    /// when Sissy does, and `since` is what says so on the panel.
    let samples: [UInt64]
    /// Seconds between samples, so a caller can label the width of the series
    /// without knowing the monitor's cadence.
    let interval: TimeInterval
    /// When the first retained sample was taken.
    let since: Date

    /// The highest the processes have been seen at since watching began, which
    /// is the one figure on the block that a single quiet moment cannot undo.
    var peak: UInt64 { samples.max() ?? current.footprint }
    /// CPU the agents themselves used since `countedSince`, in seconds,
    /// including agents that have since exited.
    ///
    /// **Since Sissy started watching, never since each process started.**
    /// The kernel's counters run from a process's birth, so a session left
    /// open for three days would carry three days into a figure read beside
    /// an hour's chart. The monitor sums what each sweep adds instead,
    /// which is the rule the series already keeps: it starts when Sissy does
    /// and says so.
    var cpuTime: TimeInterval = 0
    /// Energy billed to the agents themselves over the same stretch, in
    /// nanojoules.
    var energy: UInt64 = 0
    /// When the counting began: the first sweep, which unlike `since` does not
    /// move once the series has rolled, because nothing was dropped from the
    /// sums. Nil for a reading built by hand with no counters.
    var countedSince: Date?
    /// Each sweep's agents, one entry per element of `samples` and in the same
    /// order, so the total at an index is the sum of the entry at it.
    ///
    /// Per agent rather than per total because the total answers "how much"
    /// and never "whose": a step in a single line is anonymous. Kept for the
    /// same hour as the series and in memory for the same reason; measured
    /// against eight agents it is about 15 KB.
    var perAgent: [[AgentProcess.Key: AgentSample]] = []
}

/// Samples what the CLIs on this Mac are holding, on its own clock.
///
/// It is not a `UsageProvider` and does not ride one, for the reasons
/// `GitIdentityMonitor` is not either: a running process belongs to the Mac
/// rather than to a log tail, it costs no provider anything, and it exists on a
/// Mac where neither CLI has taken a turn today. So it publishes its own value
/// and the engine hangs it on the frame beside the slices.
///
/// **It samples whether or not the panel is open, and that is deliberate.** The
/// rule it looks like it breaks — a surface that is not on screen costs nothing
/// — is about retained view graphs, and this is not one: a sweep costs 1.2 ms
/// measured across 665 processes, which at this cadence is about a hundredth of
/// a percent of one core. The alternative is a series that begins when the
/// popover opens, which is a chart that is always empty exactly when
/// somebody wants to look at it.
actor AgentProcessMonitor {
    /// How often the processes are counted.
    ///
    /// Fine enough that a build starting is visible before it finishes, coarse
    /// enough that the series covers a working stretch rather than a few
    /// minutes.
    static let sampleInterval: Duration = .seconds(15)
    /// How many samples are kept, which at the interval above is one hour.
    /// A chart 300 pt wide cannot draw more, and an hour is the longest
    /// window the question "why is this Mac struggling" is asked over.
    static let retainedSamples = 240
    /// How long a Mac with nothing running goes without a frame at the most,
    /// so a page dating the count is never more than a minute behind it.
    static let quietFrameInterval: TimeInterval = 60

    nonisolated private let published = LockedValue<AgentMemoryReading?>(nil)
    private var samples: [UInt64] = []
    private var perAgent: [[AgentProcess.Key: AgentSample]] = []
    private var firstSampleAt: Date?
    private var lastFrameAt: Date?
    /// Each agent's counters at the sweep before, so the next one can take
    /// what it added. Keyed by pid and checked against the start time, so a
    /// pid the kernel hands to a new process does not inherit the old one's.
    private var counters: [pid_t: Counters] = [:]
    private var lastSweepAt: Date?
    private var cpuTotal: TimeInterval = 0
    private var energyTotal: UInt64 = 0
    private var pollTask: Task<Void, Never>?
    /// Injected by a test, so a round can be asserted without the kernel's own
    /// process table under it.
    private let read: @Sendable (Date) -> AgentProcessReading
    /// Turns each agent's working directory into the repository it belongs to.
    ///
    /// The monitor's rather than the reader's, because it is the same question
    /// a project row answers and has to be answered the same way: a worktree
    /// counts against the checkout it was cut from, and a directory no `.git`
    /// was ever read from is named by nothing at all.
    ///
    /// A resolver for the monitor's life rather than one per sweep. It pins an
    /// answer for its own lifetime, which is exactly right here: the sweep runs
    /// every 15 s and re-walking the same handful of directories each time
    /// would spend the budget this reading was chosen for.
    ///
    /// Actor-isolated rather than a `@Sendable` closure: a resolver holds a
    /// cache and is not `Sendable`, and the only caller is the sweep, which
    /// already runs on this actor.
    private let projects: ProjectResolver

    init(
        read: @escaping @Sendable (Date) -> AgentProcessReading = AgentProcessReader.read,
        ledger: ProjectLedger = ProjectLedger()
    ) {
        self.read = read
        self.projects = ProjectResolver(ledger: ledger)
    }

    /// The reading the frame carries, or nil before the first sweep.
    ///
    /// Nil is "not measured yet" and an empty `agents` is "measured, nothing
    /// running" — the panel words them differently, because a dash and a zero
    /// are different claims.
    nonisolated func currentMemory() -> AgentMemoryReading? { published.load() }

    /// Starts sampling. `onRefresh` fires when the reading is worth a frame,
    /// which a Mac with no agents on it mostly is not: two empty readings in a
    /// row say the same thing, so the second earns one only once
    /// `quietFrameInterval` has passed, which is what keeps the age the
    /// agents page prints true.
    func start(onRefresh: @Sendable @escaping () async -> Void) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sampleOnce(onRefresh: onRefresh)
                do { try await Task.sleep(for: Self.sampleInterval) } catch { return }
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        samples = []
        perAgent = []
        firstSampleAt = nil
        lastFrameAt = nil
        counters = [:]
        lastSweepAt = nil
        cpuTotal = 0
        energyTotal = 0
        published.store(nil)
    }

    /// One sweep. Internal rather than private so a test can run exactly one
    /// and assert on what it published, instead of waiting on the scheduler.
    func sampleOnce(onRefresh: @Sendable @escaping () async -> Void) async {
        let now = Date()
        var reading = read(now)
        reading.attributeProjects(by: projects.project(for:))
        accrue(&reading, at: now)
        let previous = published.load()
        samples.append(reading.footprint)
        perAgent.append(
            Dictionary(
                reading.agents.map {
                    ($0.key, AgentSample(footprint: $0.footprint, cpuLoad: $0.cpuLoad))
                },
                uniquingKeysWith: { first, _ in first }))
        if samples.count > Self.retainedSamples {
            samples.removeFirst(samples.count - Self.retainedSamples)
            perAgent.removeFirst(perAgent.count - Self.retainedSamples)
        }
        // The first retained sample, not the first ever taken: once the ring
        // has rolled, the older ones are gone and a `since` naming them would
        // date the series to a stretch it no longer holds.
        let since =
            firstSampleAt.map {
                samples.count < Self.retainedSamples
                    ? $0
                    : now.addingTimeInterval(
                        -Double(samples.count - 1)
                            * Self.sampleInterval.asTimeInterval)
            } ?? now
        firstSampleAt = firstSampleAt ?? now
        published.store(
            AgentMemoryReading(
                current: reading,
                samples: samples,
                interval: Self.sampleInterval.asTimeInterval,
                since: since,
                cpuTime: cpuTotal,
                energy: energyTotal,
                countedSince: firstSampleAt,
                perAgent: perAgent))
        // The *first* sweep always earns a frame, empty or not: it is the
        // transition from having no reading to having one, which is the
        // difference between the panel drawing a dash and drawing "nothing
        // running". Only a quiet Mac that was already known to be quiet is
        // skipped.
        if let previous, previous.current.agents.isEmpty, reading.agents.isEmpty,
            let lastFrameAt, now.timeIntervalSince(lastFrameAt) < Self.quietFrameInterval
        {
            return
        }
        lastFrameAt = now
        await onRefresh()
    }

    private struct Counters {
        let startedAt: Date
        let cpuTime: TimeInterval
        let energy: UInt64
    }

    /// Adds what each agent used since the sweep before to the running sums,
    /// and sets its load.
    ///
    /// An agent seen for the first time adds nothing unless it started after
    /// that sweep: one that was already running when Sissy first looked would
    /// otherwise bring its whole life into a stretch that began just now. A
    /// counter that went backwards adds nothing rather than wrapping.
    private func accrue(_ reading: inout AgentProcessReading, at now: Date) {
        let elapsed = lastSweepAt.map { now.timeIntervalSince($0) } ?? 0
        for index in reading.agents.indices {
            let agent = reading.agents[index]
            if let prior = counters[agent.pid], prior.startedAt == agent.startedAt {
                let cpu = max(agent.cpuTime - prior.cpuTime, 0)
                cpuTotal += cpu
                energyTotal += agent.energy >= prior.energy ? agent.energy - prior.energy : 0
                if elapsed > 0 { reading.agents[index].cpuLoad = cpu / elapsed }
            } else if let lastSweepAt, agent.startedAt >= lastSweepAt {
                cpuTotal += agent.cpuTime
                energyTotal += agent.energy
            }
        }
        counters = Dictionary(
            reading.agents.map {
                ($0.pid, Counters(startedAt: $0.startedAt, cpuTime: $0.cpuTime, energy: $0.energy))
            },
            uniquingKeysWith: { first, _ in first })
        lastSweepAt = now
    }
}

extension Duration {
    /// Seconds as a `TimeInterval`, for the one place a `Duration` has to be
    /// published to a surface that measures ages in seconds.
    var asTimeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
