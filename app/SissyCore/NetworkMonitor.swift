import Foundation

/// Samples the network once a second, and only while `LiveSampling` asks it
/// to, which is only while the Network tab is on screen.
///
/// Not on the frame: a frame is the whole panel's reading, and rebuilding it
/// once a second for one page's two numbers is the cost `LiveSampling`
/// exists to avoid. Each sample goes to the one callback `start` was handed,
/// and nothing else holds it.
///
/// A sample costs 1.1 to 1.2 ms of CPU in a Debug build, measured 2026-09-28
/// on a Mac16,8 running macOS 27.0, of which the counters, the filter and
/// the default route took 0.15 ms and the Wi-Fi read 0.2 to 0.35 ms when each
/// was timed alone; at one a second that is 1.2 to 2.0 ms of process CPU a
/// second with no page drawing it.
///
/// **In memory and nowhere else.** `stop()` drops the series and the counters
/// it was measured from, so a tab opened again starts a new series rather
/// than joining a line across minutes nobody sampled.
actor NetworkMonitor {
    static let sampleInterval: Duration = .seconds(1)
    /// Two minutes at one sample a second.
    static let historyLength = 120

    private let readCounters: @Sendable () -> [NetworkInterfaceCounters]
    private let readPrimary: @Sendable () -> String?
    private let readDisplayName: @Sendable (String) -> String?
    private let readWiFi: @Sendable (String) -> WiFiLink?

    private var previous: (counters: [String: NetworkByteCounts], at: Date)?
    private var rates: [NetworkRate] = []
    /// The interface last named, kept so the listing behind its display name
    /// is asked again only when the default route moves.
    private var interface: NetworkInterfaceName?
    private var pollTask: Task<Void, Never>?

    init(
        readCounters: @escaping @Sendable () -> [NetworkInterfaceCounters] = NetworkReader.counters,
        readPrimary: @escaping @Sendable () -> String? = NetworkReader.primaryInterface,
        readDisplayName: @escaping @Sendable (String) -> String? = NetworkReader.displayName,
        readWiFi: @escaping @Sendable (String) -> WiFiLink? = NetworkReader.wifi
    ) {
        self.readCounters = readCounters
        self.readPrimary = readPrimary
        self.readDisplayName = readDisplayName
        self.readWiFi = readWiFi
    }

    var isRunning: Bool { pollTask != nil }

    /// Starts sampling, and leaves a monitor already running as it is.
    func start(onSample: @Sendable @escaping (NetworkReading) async -> Void) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let reading = await self.sampleOnce() else { return }
                await onSample(reading)
                do { try await Task.sleep(for: Self.sampleInterval) } catch { return }
            }
        }
    }

    /// Stops sampling and forgets everything the samples built.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        previous = nil
        rates = []
        interface = nil
    }

    /// One sample. Internal so a test can drive the clock and assert on what
    /// it answered; nil when the poll was cancelled while it waited for this
    /// actor, since `stop()` ran ahead of it.
    func sampleOnce(now: Date = Date()) -> NetworkReading? {
        guard !Task.isCancelled else { return nil }
        let counters = readCounters()
        let byName = NetworkRates.byName(counters)
        if let previous,
            let rate = NetworkRates.rate(
                from: previous.counters, to: byName, seconds: now.timeIntervalSince(previous.at))
        {
            rates.append(rate)
            if rates.count > Self.historyLength { rates.removeFirst(rates.count - Self.historyLength) }
        }
        previous = (byName, now)
        let named = name(readPrimary())
        return NetworkReading(
            observedAt: now,
            interface: named,
            wifi: named.flatMap { readWiFi($0.bsdName) },
            sinceBoot: NetworkRates.sinceBoot(counters),
            rates: rates)
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
