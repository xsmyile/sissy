import Foundation

/// Samples the disks' byte counters once a second, and only while
/// `LiveSampling` asks it to, which is only while the Disk tab is on screen.
///
/// The same shape as `NetworkMonitor`, and for its reasons: each sample goes
/// to the one callback `start` was handed and never rides the frame, and
/// `stop()` drops the series and the counters it was measured from, so a tab
/// opened again starts a new line rather than joining one across minutes
/// nobody sampled. The pace, the length of the series and the gap that
/// restarts it are `NetworkMonitor`'s own, so the two tabs' sparklines mean
/// the same thing by two minutes.
///
/// A sample costs 0.046 ms of CPU for the read, measured 2026-09-28 on a
/// Mac16,8 running macOS 27.0.
actor DiskActivityMonitor {
    static let sampleInterval = NetworkMonitor.sampleInterval
    static let historyLength = NetworkMonitor.historyLength
    static let maximumGap = NetworkMonitor.maximumGap

    private let readCounters: @Sendable () -> [DiskDriverCounters]

    private var previous: (counters: [UInt64: DiskByteCounts], at: Date)?
    private var rates: [DiskRate] = []
    private var pollTask: Task<Void, Never>?
    private var onSample: (@Sendable (DiskActivityReading) async -> Void)?

    init(readCounters: @escaping @Sendable () -> [DiskDriverCounters] = DiskActivityReader.counters) {
        self.readCounters = readCounters
    }

    var isRunning: Bool { pollTask != nil }

    /// Starts sampling, or hands a monitor already running the new callback:
    /// the series goes on, and every sample from here on reaches the caller
    /// that asked last rather than the one that asked first.
    func start(onSample: @Sendable @escaping (DiskActivityReading) async -> Void) {
        self.onSample = onSample
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let (reading, deliver) = await self.nextSample() else { return }
                await deliver(reading)
                do { try await Task.sleep(for: Self.sampleInterval) } catch { return }
            }
        }
    }

    private func nextSample() -> (DiskActivityReading, @Sendable (DiskActivityReading) async -> Void)? {
        guard let onSample, let reading = sampleOnce() else { return nil }
        return (reading, onSample)
    }

    /// Stops sampling and forgets everything the samples built.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        onSample = nil
        previous = nil
        rates = []
    }

    /// One sample. Internal so a test can drive the clock and assert on what
    /// it answered; nil when the poll was cancelled while it waited for this
    /// actor, since `stop()` ran ahead of it.
    ///
    /// A gap beyond `maximumGap` empties the series and measures the next
    /// rate from this sample, and so does a step with nothing to measure, see
    /// `DiskRates.rate`: a point missing from the middle of the line would
    /// shift every one before it.
    func sampleOnce(now: Date = Date()) -> DiskActivityReading? {
        guard !Task.isCancelled else { return nil }
        let byID = DiskRates.byID(readCounters())
        if let previous {
            let gap = now.timeIntervalSince(previous.at)
            if gap <= Self.maximumGap,
                let rate = DiskRates.rate(from: previous.counters, to: byID, seconds: gap)
            {
                rates.append(rate)
                if rates.count > Self.historyLength { rates.removeFirst(rates.count - Self.historyLength) }
            } else {
                rates = []
            }
        }
        previous = (byID, now)
        return DiskActivityReading(observedAt: now, rates: rates)
    }
}
