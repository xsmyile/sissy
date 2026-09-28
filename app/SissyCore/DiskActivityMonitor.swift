import Foundation

/// Reads the disks' byte counters while the `disk` switch is on, and
/// publishes each sample once a second while `LiveSampling` asks for it,
/// which is only while the Disk tab is on screen.
///
/// The same shape as `NetworkMonitor`, and for its reasons: every five seconds
/// in the background with nothing published, once a second for the page, one
/// series across both, see `LiveCadence`. A sample never rides the frame, and
/// `stop()` drops the series and the counters it was measured from, so a
/// switch turned on again starts a new line rather than joining one across
/// minutes nobody sampled. The cadences, the window and the gap are
/// `LiveCadence`'s, so the two tabs' sparklines mean the same thing by two
/// minutes.
///
/// A sample costs 0.046 ms of CPU for the read, measured 2026-09-28 on a
/// Mac16,8 running macOS 27.0.
actor DiskActivityMonitor {
    private let readCounters: @Sendable () -> [DiskDriverCounters]

    private var log = RateLog<[UInt64: DiskByteCounts], DiskRate>()
    private var pollTask: Task<Void, Never>?
    private var onSample: (@Sendable (DiskActivityReading) async -> Void)?

    init(readCounters: @escaping @Sendable () -> [DiskDriverCounters] = DiskActivityReader.counters) {
        self.readCounters = readCounters
    }

    var isRunning: Bool { pollTask != nil }

    /// The pace the monitor runs at, nil while it is stopped.
    var cadence: LiveCadence? {
        guard isRunning else { return nil }
        return onSample == nil ? .background : .watched
    }

    /// Runs the monitor, watched and publishing to `onSample` or in the
    /// background with nil, on `NetworkMonitor`'s terms: a page arriving
    /// interrupts the background's wait, and a page leaving lets the wait in
    /// flight end.
    func run(publishing onSample: (@Sendable (DiskActivityReading) async -> Void)?) {
        let wasWatched = self.onSample != nil
        self.onSample = onSample
        if isRunning, wasWatched || onSample == nil { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let (cadence, delivery) = await self.step() else { return }
                if let (reading, deliver) = delivery { await deliver(reading) }
                do {
                    try await Task.sleep(for: cadence.interval, tolerance: cadence.tolerance)
                } catch { return }
            }
        }
    }

    private func step() -> (
        LiveCadence, (DiskActivityReading, @Sendable (DiskActivityReading) async -> Void)?
    )? {
        let cadence: LiveCadence = onSample == nil ? .background : .watched
        guard let reading = sampleOnce(next: cadence) else { return nil }
        guard let onSample else { return (cadence, nil) }
        return (cadence, (reading, onSample))
    }

    /// Stops sampling and forgets everything the samples built.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        onSample = nil
        log = RateLog()
    }

    /// One sample, which in the background is logged and goes nowhere.
    /// Internal so a test can drive the clock and assert on what it answered;
    /// nil when the loop was cancelled while it waited for this actor, since
    /// `stop()` ran ahead of it.
    ///
    /// A step with nothing to measure restarts the series as a gap does, see
    /// `DiskRates.rate` and `RateLog`.
    func sampleOnce(now: SampleTime = .now, next: LiveCadence = .watched) -> DiskActivityReading? {
        guard !Task.isCancelled else { return nil }
        log.record(DiskRates.byID(readCounters()), at: now, next: next, rate: DiskRates.rate)
        return DiskActivityReading(observedAt: now.wall, rates: log.points)
    }
}
