import Foundation

/// Reads the network's counters while the `network` switch is on, and samples
/// the whole reading once a second while `LiveSampling` asks for it, which is
/// only while the Network tab is on screen.
///
/// **Two cadences, one series**, see `LiveCadence`: with the tab gone only the
/// byte counters are read, every five seconds, and nothing is published, so
/// the default route, its name and the Wi-Fi link are read only for a page
/// that draws them. The tab opening switches the monitor to one a second at
/// once, and its first sample carries the two minutes the background kept.
///
/// Not on the frame: a frame is the whole panel's reading, and rebuilding it
/// once a second for one page's two numbers is the cost `LiveSampling`
/// exists to avoid. Each watched sample goes to the one callback `run` was
/// handed, and nothing else holds it.
///
/// A watched sample costs 1.1 to 1.2 ms of CPU in a Debug build, measured
/// 2026-09-28 on a Mac16,8 running macOS 27.0, of which the counters, the
/// filter and the default route took 0.15 ms and the Wi-Fi read 0.2 to
/// 0.35 ms when each was timed alone; at one a second that is 1.2 to 2.0 ms of
/// process CPU a second, which is why it runs only for the page.
///
/// **In memory and nowhere else.** `stop()` drops the series and the counters
/// it was measured from, so a switch turned on again starts a new series
/// rather than joining a line across minutes nobody sampled.
actor NetworkMonitor {
    private let readCounters: @Sendable () -> [NetworkInterfaceCounters]
    private let readPrimary: @Sendable () -> String?
    private let readDisplayName: @Sendable (String) -> String?
    private let readWiFi: @Sendable (String) -> WiFiLink?
    private let bootedAt: Date?

    private var log = RateLog<[String: NetworkByteCounts], NetworkRate>()
    /// The interface last named, kept so the listing behind its display name
    /// is asked again only when the default route moves.
    private var interface: NetworkInterfaceName?
    private var pollTask: Task<Void, Never>?
    private var onSample: (@Sendable (NetworkReading) async -> Void)?

    init(
        readCounters: @escaping @Sendable () -> [NetworkInterfaceCounters] = NetworkReader.counters,
        readPrimary: @escaping @Sendable () -> String? = NetworkReader.primaryInterface,
        readDisplayName: @escaping @Sendable (String) -> String? = NetworkReader.displayName,
        readWiFi: @escaping @Sendable (String) -> WiFiLink? = NetworkReader.wifi,
        bootedAt: Date? = NetworkReader.bootedAt()
    ) {
        self.bootedAt = bootedAt
        self.readCounters = readCounters
        self.readPrimary = readPrimary
        self.readDisplayName = readDisplayName
        self.readWiFi = readWiFi
    }

    var isRunning: Bool { pollTask != nil }

    /// The pace the monitor runs at, nil while it is stopped.
    var cadence: LiveCadence? {
        guard isRunning else { return nil }
        return onSample == nil ? .background : .watched
    }

    /// Runs the monitor, watched and publishing to `onSample` or in the
    /// background with nil, and hands one already running the new callback:
    /// the series goes on, and every sample from here on reaches the caller
    /// that asked last rather than the one that asked first.
    ///
    /// **A page arriving interrupts the background's wait**, so its first
    /// sample is taken at once rather than up to five seconds later. A page
    /// leaving does not: the one-second wait in flight ends, the sample it
    /// ends in is kept and not published, and the next wait is five seconds.
    func run(publishing onSample: (@Sendable (NetworkReading) async -> Void)?) {
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

    /// One step of the loop at the cadence in force: the counters alone in
    /// the background, the whole reading and where it goes while watched.
    private func step() -> (
        LiveCadence, (NetworkReading, @Sendable (NetworkReading) async -> Void)?
    )? {
        guard let onSample else { return record(next: .background) ? (.background, nil) : nil }
        guard let reading = sampleOnce(next: .watched) else { return nil }
        return (.watched, (reading, onSample))
    }

    /// Stops sampling and forgets everything the samples built.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        onSample = nil
        log = RateLog()
        interface = nil
    }

    /// Reads the counters and logs the rate since the last read, which is
    /// all a background step does. False when the loop was cancelled while it
    /// waited for this actor, since `stop()` ran ahead of it. Internal so a
    /// test can drive the clock.
    func record(now: Date = Date(), next: LiveCadence) -> Bool {
        guard !Task.isCancelled else { return false }
        log.record(NetworkRates.byName(readCounters()), at: now, next: next, rate: NetworkRates.rate)
        return true
    }

    /// One watched sample. Internal so a test can drive the clock and assert
    /// on what it answered; nil when the loop was cancelled while it waited
    /// for this actor, since `stop()` ran ahead of it.
    func sampleOnce(now: Date = Date(), next: LiveCadence = .watched) -> NetworkReading? {
        guard !Task.isCancelled else { return nil }
        let counters = readCounters()
        log.record(NetworkRates.byName(counters), at: now, next: next, rate: NetworkRates.rate)
        let named = name(readPrimary())
        return NetworkReading(
            observedAt: now,
            interface: named,
            wifi: named.flatMap { readWiFi($0.bsdName) },
            totals: NetworkRates.totals(counters, bootedAt: bootedAt),
            rates: log.points)
    }

    private func name(_ bsdName: String?) -> NetworkInterfaceName? {
        guard let bsdName else {
            interface = nil
            return nil
        }
        if let interface, interface.bsdName == bsdName { return interface }
        let named = NetworkInterfaceName(bsdName: bsdName, displayName: readDisplayName(bsdName))
        interface = named
        return named
    }
}
