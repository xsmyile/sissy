import XCTest

@testable import Sissy

final class DiskCounterParsingTests: XCTestCase {
    func testBothCountersAreReadAsSixtyFourBitFigures() {
        let statistics: [String: Any] = [
            "Bytes (Read)": NSNumber(value: UInt64(5_000_000_000_000)),
            "Bytes (Write)": NSNumber(value: UInt64(7_000_000_000)),
            "Operations (Read)": NSNumber(value: 1),
        ]
        XCTAssertEqual(
            DiskActivityReader.parse(statistics: statistics),
            DiskByteCounts(read: 5_000_000_000_000, written: 7_000_000_000))
    }

    func testADriverThatAnswersOneCounterIsNotRead() {
        XCTAssertNil(DiskActivityReader.parse(statistics: ["Bytes (Read)": NSNumber(value: 1)]))
        XCTAssertNil(DiskActivityReader.parse(statistics: ["Bytes (Write)": NSNumber(value: 1)]))
        XCTAssertNil(DiskActivityReader.parse(statistics: [:]))
    }

    func testACounterThatIsNotANumberIsNotRead() {
        XCTAssertNil(
            DiskActivityReader.parse(statistics: ["Bytes (Read)": "12", "Bytes (Write)": "3"]))
    }
}

final class DiskRatesTests: XCTestCase {
    private func counters(_ read: UInt64, _ written: UInt64) -> DiskByteCounts {
        DiskByteCounts(read: read, written: written)
    }

    func testTheRateIsTheDifferenceOverTheGap() {
        let rate = DiskRates.rate(
            from: [1: counters(1_000, 200)], to: [1: counters(43_000, 3_400)], seconds: 2)
        XCTAssertEqual(rate, DiskRate(read: 21_000, written: 1_600))
    }

    func testDriversAreSummed() {
        let rate = DiskRates.rate(
            from: [1: counters(0, 0), 2: counters(100, 100)],
            to: [1: counters(500, 50), 2: counters(400, 700)], seconds: 1)
        XCTAssertEqual(rate, DiskRate(read: 800, written: 650))
    }

    /// An unplugged disk takes its counters with it, and the sum going down
    /// is not a negative rate.
    func testADriverThatLeavesContributesNothing() {
        let rate = DiskRates.rate(
            from: [1: counters(0, 0), 2: counters(9_000_000, 9_000_000)],
            to: [1: counters(500, 50)], seconds: 1)
        XCTAssertEqual(rate, DiskRate(read: 500, written: 50))
    }

    /// A driver that attaches brings a counter with a history nobody sampled,
    /// which is not this second's traffic.
    func testADriverThatArrivesContributesNothing() {
        let rate = DiskRates.rate(
            from: [1: counters(0, 0)],
            to: [1: counters(500, 50), 2: counters(9_000_000, 9_000_000)], seconds: 1)
        XCTAssertEqual(rate, DiskRate(read: 500, written: 50))
    }

    func testACounterThatGoesBackwardsContributesNothingNotAWrap() {
        let rate = DiskRates.rate(
            from: [1: counters(9_000, 9_000), 2: counters(0, 0)],
            to: [1: counters(100, 200), 2: counters(30, 40)], seconds: 1)
        XCTAssertEqual(rate, DiskRate(read: 30, written: 40))
    }

    func testTheTwoDirectionsAreJudgedApart() {
        let rate = DiskRates.rate(
            from: [1: counters(9_000, 0)], to: [1: counters(100, 700)], seconds: 1)
        XCTAssertEqual(rate, DiskRate(read: 0, written: 700))
    }

    func testNoTimeElapsedIsNoRate() {
        XCTAssertNil(DiskRates.rate(from: [1: .zero], to: [1: .zero], seconds: 0))
        XCTAssertNil(DiskRates.rate(from: [1: .zero], to: [1: .zero], seconds: -1))
    }

    /// Zero would be a measurement, and nothing was measured.
    func testNoDriverInCommonIsNoRate() {
        XCTAssertNil(DiskRates.rate(from: [1: .zero], to: [2: .zero], seconds: 1))
        XCTAssertNil(DiskRates.rate(from: [:], to: [:], seconds: 1))
    }

    func testTheSameDriverListedTwiceCountsOnce() {
        let byID = DiskRates.byID([
            DiskDriverCounters(id: 1, bytes: counters(1, 1)),
            DiskDriverCounters(id: 1, bytes: counters(2, 2)),
        ])
        XCTAssertEqual(byID, [1: counters(2, 2)])
    }
}

final class DiskActivityMonitorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// A monitor reading `drivers` as they stand at each call, step by step:
    /// `sequence[n]` is what the nth read answers, and the last one repeats.
    private func monitor(_ sequence: [[DiskDriverCounters]]) -> DiskActivityMonitor {
        let reads = LockedValue(0)
        return DiskActivityMonitor(readCounters: {
            let n = reads.load()
            reads.store(n + 1)
            return sequence[min(n, sequence.count - 1)]
        })
    }

    private func steady(step: UInt64 = 1_000) -> DiskActivityMonitor {
        let reads = LockedValue<UInt64>(0)
        return DiskActivityMonitor(readCounters: {
            let n = reads.load()
            reads.store(n + 1)
            return [
                DiskDriverCounters(
                    id: 1, bytes: DiskByteCounts(read: n * step, written: n * step / 2))
            ]
        })
    }

    private func driver(_ id: UInt64, _ read: UInt64, _ written: UInt64) -> DiskDriverCounters {
        DiskDriverCounters(id: id, bytes: DiskByteCounts(read: read, written: written))
    }

    func testTheFirstSampleHasNoRate() async throws {
        let sampled = await steady().sampleOnce(now: start)
        let reading = try XCTUnwrap(sampled)
        XCTAssertEqual(reading.rates, [])
        XCTAssertNil(reading.current)
    }

    func testTheSecondSampleMeasuresTheRate() async throws {
        let monitor = steady()
        _ = await monitor.sampleOnce(now: start)
        let sampled = await monitor.sampleOnce(now: start + 1)
        let reading = try XCTUnwrap(sampled)
        XCTAssertEqual(reading.current, DiskRate(read: 1_000, written: 500))
    }

    func testTheSeriesKeepsTwoMinutes() async {
        let monitor = steady()
        var last: DiskActivityReading?
        for second in 0...(DiskActivityMonitor.historyLength + 10) {
            last = await monitor.sampleOnce(now: start + TimeInterval(second))
        }
        XCTAssertEqual(last?.rates.count, DiskActivityMonitor.historyLength)
    }

    /// The gap is the network's, so both sparklines lay a second the same way.
    func testTheGapIsTheNetworksOwn() {
        XCTAssertEqual(DiskActivityMonitor.maximumGap, NetworkMonitor.maximumGap)
        XCTAssertEqual(DiskActivityMonitor.historyLength, NetworkMonitor.historyLength)
        XCTAssertEqual(DiskActivityMonitor.sampleInterval, NetworkMonitor.sampleInterval)
    }

    func testAGapBeyondTheBoundRestartsTheSeries() async {
        let monitor = steady()
        for second in 0..<3 { _ = await monitor.sampleOnce(now: start + TimeInterval(second)) }
        let afterGap = start + 2 + DiskActivityMonitor.maximumGap + 1
        let resumed = await monitor.sampleOnce(now: afterGap)
        XCTAssertEqual(resumed?.rates, [])
        let next = await monitor.sampleOnce(now: afterGap + 1)
        XCTAssertEqual(next?.rates, [DiskRate(read: 1_000, written: 500)])
    }

    func testALateSampleWithinTheBoundStaysInTheSeries() async {
        let monitor = steady()
        _ = await monitor.sampleOnce(now: start)
        _ = await monitor.sampleOnce(now: start + 1)
        let late = await monitor.sampleOnce(now: start + 1 + DiskActivityMonitor.maximumGap)
        XCTAssertEqual(late?.rates.count, 2)
    }

    /// An external disk plugged in mid-series adds nothing to the sample it
    /// arrives in, and its traffic counts from the next.
    func testADriverAppearingKeepsTheSeriesAndJoinsTheNextRate() async {
        let monitor = monitor([
            [driver(1, 0, 0)],
            [driver(1, 100, 10)],
            [driver(1, 200, 20), driver(2, 9_000_000, 9_000_000)],
            [driver(1, 300, 30), driver(2, 9_000_500, 9_000_040)],
        ])
        var last: DiskActivityReading?
        for second in 0..<4 { last = await monitor.sampleOnce(now: start + TimeInterval(second)) }
        XCTAssertEqual(
            last?.rates,
            [
                DiskRate(read: 100, written: 10), DiskRate(read: 100, written: 10),
                DiskRate(read: 600, written: 50),
            ])
    }

    func testADriverLeavingKeepsTheSeriesAtTheRemainingDrivesRate() async {
        let monitor = monitor([
            [driver(1, 0, 0), driver(2, 5_000_000, 5_000_000)],
            [driver(1, 100, 10), driver(2, 5_000_900, 5_000_090)],
            [driver(1, 200, 20)],
        ])
        var last: DiskActivityReading?
        for second in 0..<3 { last = await monitor.sampleOnce(now: start + TimeInterval(second)) }
        XCTAssertEqual(
            last?.rates, [DiskRate(read: 1_000, written: 100), DiskRate(read: 100, written: 10)])
    }

    /// With no driver in both samples there is nothing to measure, and a
    /// point missing from the middle of the line would shift every other.
    func testASampleWithNothingInCommonRestartsTheSeries() async {
        let monitor = monitor([
            [driver(1, 0, 0)], [driver(1, 100, 10)], [], [driver(1, 300, 30)], [driver(1, 400, 40)],
        ])
        var readings: [DiskActivityReading] = []
        for second in 0..<5 {
            if let reading = await monitor.sampleOnce(now: start + TimeInterval(second)) {
                readings.append(reading)
            }
        }
        XCTAssertEqual(readings.map(\.rates.count), [0, 1, 0, 0, 1])
    }

    func testACounterGoingBackwardsIsNotARate() async {
        let monitor = monitor([[driver(1, 9_000, 9_000)], [driver(1, 100, 100)]])
        _ = await monitor.sampleOnce(now: start)
        let sampled = await monitor.sampleOnce(now: start + 1)
        XCTAssertEqual(sampled?.rates, [DiskRate(read: 0, written: 0)])
    }

    /// A tab opened again starts a new series rather than drawing a line
    /// across the minutes nobody sampled.
    func testStopDropsTheSeries() async throws {
        let monitor = steady()
        _ = await monitor.sampleOnce(now: start)
        _ = await monitor.sampleOnce(now: start + 1)
        await monitor.stop()
        let sampled = await monitor.sampleOnce(now: start + 2)
        let reading = try XCTUnwrap(sampled)
        XCTAssertEqual(reading.rates, [])
    }

    func testARunningMonitorDeliversAndStopsOnDemand() async {
        let monitor = steady()
        let idle = await monitor.isRunning
        XCTAssertFalse(idle)
        let delivered = expectation(description: "a sample")
        delivered.assertForOverFulfill = false
        await monitor.start { _ in delivered.fulfill() }
        let running = await monitor.isRunning
        XCTAssertTrue(running)
        await fulfillment(of: [delivered], timeout: 5)
        await monitor.stop()
        let stopped = await monitor.isRunning
        XCTAssertFalse(stopped)
    }
}

final class DiskLiveSamplingTests: XCTestCase {
    private let disk = DiskActivityMonitor(readCounters: { [] })

    private func sampling(enabled: Set<LiveReading> = [.network, .disk]) -> LiveSampling {
        LiveSampling(
            network: NetworkMonitor(
                readCounters: { [] }, readPrimary: { nil }, readDisplayName: { _ in nil },
                readWiFi: { _ in nil }),
            disk: disk, enabled: enabled)
    }

    private let ignore: @Sendable (LiveSample) async -> Void = { _ in }

    func testTheDiskTabAskingStartsOnlyTheDisk() async {
        let live = sampling()
        await live.setDemand([.disk], onSample: ignore)
        let running = await live.running()
        XCTAssertEqual(running, [.disk])
    }

    /// A tab switch and a closing panel both say it as the empty demand.
    func testTheDemandGoingStopsIt() async {
        let live = sampling()
        await live.setDemand([.disk], onSample: ignore)
        await live.setDemand([], onSample: ignore)
        let running = await live.running()
        XCTAssertEqual(running, [])
        let sampling = await disk.isRunning
        XCTAssertFalse(sampling)
    }

    func testSwitchingTabsMovesTheSamplingWithoutOverlap() async {
        let live = sampling()
        await live.setDemand([.disk], onSample: ignore)
        await live.setDemand([.network], onSample: ignore)
        let running = await live.running()
        XCTAssertEqual(running, [.network])
    }

    func testDiskSwitchedOffIsNotStartedByDemand() async {
        let live = sampling(enabled: [.network])
        await live.setDemand([.disk], onSample: ignore)
        let running = await live.running()
        XCTAssertEqual(running, [])
    }

    func testSwitchingDiskOffStopsARunningReading() async {
        let live = sampling()
        await live.setDemand([.disk], onSample: ignore)
        await live.setEnabled(.disk, false)
        let off = await live.running()
        XCTAssertEqual(off, [])
        await live.setEnabled(.disk, true)
        let on = await live.running()
        XCTAssertEqual(on, [.disk])
    }

    func testStopIsTerminal() async {
        let live = sampling()
        await live.setDemand([.disk], onSample: ignore)
        await live.stop()
        await live.setDemand([.disk], onSample: ignore)
        let running = await live.running()
        XCTAssertEqual(running, [])
    }

    func testARunningDiskDeliversItsSamples() async {
        let live = sampling()
        let delivered = expectation(description: "a sample")
        delivered.assertForOverFulfill = false
        await live.setDemand([.disk]) { sample in
            if case .disk = sample { delivered.fulfill() }
        }
        await fulfillment(of: [delivered], timeout: 5)
        await live.stop()
    }
}

@MainActor
final class DiskActivityHostTests: XCTestCase {
    private let reading = DiskActivityReading(
        observedAt: Date(timeIntervalSince1970: 1_790_000_000),
        rates: [DiskRate(read: 42_000_000, written: 3_100_000)])

    func testASampleNobodyAskedForIsDropped() {
        let host = UsageEngineHost()
        host.receive(.disk(reading), generation: host.liveGeneration)
        XCTAssertNil(host.diskActivityReading)
    }

    func testASampleFromAnEarlierDemandIsDropped() {
        let host = UsageEngineHost()
        host.setLiveDemand([.disk])
        let first = host.liveGeneration
        host.setLiveDemand([])
        host.setLiveDemand([.disk])
        host.receive(.disk(reading), generation: first)
        XCTAssertNil(host.diskActivityReading)
    }

    func testTheDemandGoingClearsTheReading() {
        let host = UsageEngineHost()
        host.setLiveDemand([.disk])
        host.receive(.disk(reading), generation: host.liveGeneration)
        XCTAssertEqual(host.diskActivityReading, reading)
        host.setLiveDemand([])
        XCTAssertNil(host.diskActivityReading)
    }

    func testAskingForTheNetworkDoesNotKeepTheDiskReading() {
        let host = UsageEngineHost()
        host.setLiveDemand([.disk])
        host.receive(.disk(reading), generation: host.liveGeneration)
        host.setLiveDemand([.network])
        XCTAssertNil(host.diskActivityReading)
    }

    func testOnlyTheDiskTabAsksForTheDisk() {
        for tab in PanelTab.allCases {
            XCTAssertEqual(tab.liveReadings.contains(.disk), tab == .disk, "\(tab)")
        }
    }
}

final class DiskActivityFormatTests: XCTestCase {
    func testTheLegendNamesEachDirection() {
        XCTAssertEqual(UsageFormat.diskRead(42_000_000), "Read 42 MB/s")
        XCTAssertEqual(UsageFormat.diskWrite(3_100_000), "Write 3.1 MB/s")
        XCTAssertEqual(UsageFormat.diskRead(nil), "Read " + UsageFormat.macLevel(nil))
    }
}

final class DiskActivityEngineTests: XCTestCase {
    private var tempDir: URL!
    private let disk = DiskActivityMonitor(readCounters: { [] })

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-disk-activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var configURL: URL { tempDir.appendingPathComponent("server.json") }

    private func makeEngine(disk diskOn: Bool = true) -> UsageEngine {
        var config = ServerConfig.defaults
        config.claudeDataDir = tempDir.appendingPathComponent("claude").path
        config.codexDataDir = tempDir.appendingPathComponent("codex").path
        config.remotePricing = false
        config.statusChecks = false
        config.macHealth = false
        config.disk = diskOn
        return UsageEngine(
            config: config, configURL: configURL, limitsProbe: ClaudeLimitsProbe { _ in .absent },
            claudeAccounts: .inert(),
            diskMonitor: DiskMonitor(read: { now in
                DiskReading(
                    observedAt: now, home: nil, purgeable: 0, physicalMemory: 1_024, volumes: [])
            }),
            networkMonitor: NetworkMonitor(
                readCounters: { [] }, readPrimary: { nil }, readDisplayName: { _ in nil },
                readWiFi: { _ in nil }),
            diskActivityMonitor: disk)
    }

    func testTheEngineSamplesOnlyWhileAPageAsks() async {
        let engine = makeEngine()
        let idle = await disk.isRunning
        XCTAssertFalse(idle)
        await engine.setLiveDemand([.disk]) { _ in }
        let asked = await disk.isRunning
        XCTAssertTrue(asked)
        await engine.setLiveDemand([]) { _ in }
        let released = await disk.isRunning
        XCTAssertFalse(released)
    }

    /// The disk switch covers the activity: off means no activity either.
    func testDiskOffMeansNoActivity() async {
        let engine = makeEngine(disk: false)
        await engine.setLiveDemand([.disk]) { _ in }
        let running = await disk.isRunning
        XCTAssertFalse(running)
    }

    func testSwitchingTheDiskOffStopsTheSampling() async {
        let engine = makeEngine()
        await engine.setLiveDemand([.disk]) { _ in }
        await engine.setDisk(enabled: false)
        let off = await disk.isRunning
        XCTAssertFalse(off)
        await engine.setDisk(enabled: true)
        let on = await disk.isRunning
        XCTAssertTrue(on)
        await engine.stop()
    }

    func testAStoppedEngineStartsNothing() async {
        let engine = makeEngine()
        await engine.stop()
        await engine.setLiveDemand([.disk]) { _ in }
        let running = await disk.isRunning
        XCTAssertFalse(running)
    }
}
