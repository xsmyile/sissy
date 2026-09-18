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
/// popover opens, which is a sparkline that is always empty exactly when
/// somebody wants to look at it.
actor AgentProcessMonitor {
    /// How often the processes are counted.
    ///
    /// Fine enough that a build starting is visible before it finishes, coarse
    /// enough that the series covers a working stretch rather than a few
    /// minutes.
    static let sampleInterval: Duration = .seconds(15)
    /// How many samples are kept, which at the interval above is one hour.
    /// A sparkline 300 pt wide cannot draw more, and an hour is the longest
    /// window the question "why is this Mac struggling" is asked over.
    static let retainedSamples = 240

    nonisolated private let published = LockedValue<AgentMemoryReading?>(nil)
    private var samples: [UInt64] = []
    private var firstSampleAt: Date?
    private var pollTask: Task<Void, Never>?
    /// Injected by a test, so a round can be asserted without the kernel's own
    /// process table under it.
    private let read: @Sendable (Date) -> AgentProcessReading

    init(read: @escaping @Sendable (Date) -> AgentProcessReading = AgentProcessReader.read) {
        self.read = read
    }

    /// The reading the frame carries, or nil before the first sweep.
    ///
    /// Nil is "not measured yet" and an empty `agents` is "measured, nothing
    /// running" — the panel words them differently, because a dash and a zero
    /// are different claims.
    nonisolated func currentMemory() -> AgentMemoryReading? { published.load() }

    /// Starts sampling. `onRefresh` fires when the reading is worth a frame,
    /// which a Mac with no agents on it is not: two empty readings in a row
    /// say the same thing and rebuilding the frame for the second is work
    /// nobody asked for.
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
        firstSampleAt = nil
        published.store(nil)
    }

    /// One sweep. Internal rather than private so a test can run exactly one
    /// and assert on what it published, instead of waiting on the scheduler.
    func sampleOnce(onRefresh: @Sendable @escaping () async -> Void) async {
        let now = Date()
        let reading = read(now)
        let previous = published.load()
        samples.append(reading.footprint)
        if samples.count > Self.retainedSamples {
            samples.removeFirst(samples.count - Self.retainedSamples)
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
                since: since))
        // The *first* sweep always earns a frame, empty or not: it is the
        // transition from having no reading to having one, which is the
        // difference between the panel drawing a dash and drawing "nothing
        // running". Only a quiet Mac that was already known to be quiet is
        // skipped.
        if let previous, previous.current.agents.isEmpty, reading.agents.isEmpty { return }
        await onRefresh()
    }
}

extension Duration {
    /// Seconds as a `TimeInterval`, for the one place a `Duration` has to be
    /// published to a surface that measures ages in seconds.
    var asTimeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
