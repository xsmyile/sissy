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

final class DiskPhysicalDriversTests: XCTestCase {
    private func driver(_ id: UInt64, _ read: UInt64, _ interconnect: String?) -> DiskDriver {
        DiskDriver(
            counters: DiskDriverCounters(id: id, bytes: DiskByteCounts(read: read, written: 0)),
            interconnect: interconnect)
    }

    /// The five drivers this Mac's registry held on 2026-09-28: the disk, the
    /// empty SD reader and three images, whose reads the disk serves again.
    func testDiskImagesAreLeftOutOfTheSum() {
        let registry = [
            driver(0x1_0000_0b5d, 0, "Secure Digital"),
            driver(0x1_0000_0bf0, 1_764_998_504_448, "Apple Fabric"),
            driver(0x1_0000_d828, 14_291_614_720, "Virtual Interface"),
            driver(0x1_0000_166e, 139_323_587_584, "Virtual Interface"),
            driver(0x1_0000_169b, 19_389_440, "Virtual Interface"),
        ]
        XCTAssertEqual(
            DiskActivityReader.physical(registry).map(\.id), [0x1_0000_0b5d, 0x1_0000_0bf0])
    }

    /// An external disk is physical whatever the bus it is on.
    func testExternalMediaIsKept() {
        let kept = DiskActivityReader.physical([
            driver(1, 10, "USB"), driver(2, 20, "Thunderbolt"), driver(3, 30, "Apple Fabric"),
        ])
        XCTAssertEqual(kept.map(\.id), [1, 2, 3])
    }

    /// A provider that says nothing is not an image.
    func testADriverWhoseProviderSaysNothingIsKept() {
        XCTAssertEqual(DiskActivityReader.physical([driver(1, 10, nil)]).map(\.id), [1])
    }

    func testNoDriversAreNoCounters() {
        XCTAssertEqual(DiskActivityReader.physical([]), [])
    }

    /// The image mounting or going while the tab is open is not a change in
    /// what the disk did, so it leaves the rate at the disk's own.
    func testMountingAnImageLeavesTheRateAtTheDisksOwn() {
        let before = DiskActivityReader.physical([driver(1, 1_000, "Apple Fabric")])
        let after = DiskActivityReader.physical([
            driver(1, 3_000, "Apple Fabric"), driver(2, 9_000_000, "Virtual Interface"),
        ])
        let rate = DiskRates.rate(
            from: DiskRates.byID(before), to: DiskRates.byID(after), seconds: 1)
        XCTAssertEqual(rate, DiskRate(read: 2_000, written: 0))
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
    private let start = SampleTime(
        wall: Date(timeIntervalSince1970: 1_790_000_000), instant: .now)

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

    func testTheSeriesKeepsTwoMinutesByTime() async throws {
        let monitor = steady()
        var last: DiskActivityReading?
        for second in 0...200 {
            last = await monitor.sampleOnce(now: start + TimeInterval(second))
        }
        let rates = try XCTUnwrap(last?.rates)
        XCTAssertEqual(rates.first?.at, (start + 200 - LiveCadence.window).wall)
        XCTAssertEqual(rates.count, 121)
    }

    func testBothCadencesFeedOneDatedSeries() async {
        let monitor = steady()
        for second in [0, 5, 10] {
            _ = await monitor.sampleOnce(now: start + TimeInterval(second), next: .background)
        }
        var last: DiskActivityReading?
        for second in [12, 13] { last = await monitor.sampleOnce(now: start + TimeInterval(second)) }
        XCTAssertEqual(last?.rates.map(\.at), [5, 10, 12, 13].map { (start + TimeInterval($0)).wall })
    }

    func testAGapBeyondTheBoundRestartsTheSeries() async {
        let monitor = steady()
        for second in 0..<3 { _ = await monitor.sampleOnce(now: start + TimeInterval(second)) }
        let afterGap = start + 2 + LiveCadence.watched.maximumGap + 1
        let resumed = await monitor.sampleOnce(now: afterGap)
        XCTAssertEqual(resumed?.rates, [])
        let next = await monitor.sampleOnce(now: afterGap + 1)
        XCTAssertEqual(next?.rates.map(\.rate), [DiskRate(read: 1_000, written: 500)])
    }

    func testALateSampleWithinTheBoundStaysInTheSeries() async {
        let monitor = steady()
        _ = await monitor.sampleOnce(now: start)
        _ = await monitor.sampleOnce(now: start + 1)
        let late = await monitor.sampleOnce(now: start + 1 + LiveCadence.watched.maximumGap)
        XCTAssertEqual(late?.rates.count, 2)
    }

    func testTheBackgroundBoundIsItsOwnStep() async {
        let monitor = steady()
        _ = await monitor.sampleOnce(now: start, next: .background)
        let atBound = await monitor.sampleOnce(
            now: start + LiveCadence.background.maximumGap, next: .background)
        XCTAssertEqual(atBound?.rates.count, 1)
        let pastBound = await monitor.sampleOnce(
            now: start + 2 * LiveCadence.background.maximumGap + 1)
        XCTAssertEqual(pastBound?.rates, [])
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
            last?.rates.map(\.rate),
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
            last?.rates.map(\.rate),
            [DiskRate(read: 1_000, written: 100), DiskRate(read: 100, written: 10)])
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
        XCTAssertEqual(sampled?.rates.map(\.rate), [DiskRate(read: 0, written: 0)])
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
        await monitor.run { _ in delivered.fulfill() }
        let running = await monitor.cadence
        XCTAssertEqual(running, .watched)
        await fulfillment(of: [delivered], timeout: 5)
        await monitor.stop()
        let stopped = await monitor.isRunning
        XCTAssertFalse(stopped)
    }
}

final class DiskLiveSamplingTests: XCTestCase {
    private let disk = DiskActivityMonitor(readCounters: { [] })

    private func sampling(enabled: Set<LiveReading> = [.network, .disk]) async -> LiveSampling {
        let live = LiveSampling(network: .readingNothing(), disk: disk, enabled: enabled)
        await live.start()
        return live
    }

    private let ignore: @Sendable (LiveSample) async -> Void = { _ in }

    func testTheDiskTabAskingWatchesOnlyTheDisk() async {
        let live = await sampling()
        await live.setDemand([.disk], onSample: ignore)
        let running = await live.running()
        XCTAssertEqual(running, [.disk: .watched, .network: .background])
        await live.stop()
    }

    /// A tab switch and a closing panel both say it as the empty demand,
    /// which leaves the disk logging in the background.
    func testTheDemandGoingMovesItToTheBackground() async {
        let live = await sampling()
        await live.setDemand([.disk], onSample: ignore)
        await live.setDemand([], onSample: ignore)
        let cadence = await disk.cadence
        XCTAssertEqual(cadence, .background)
        await live.stop()
    }

    func testSwitchingTabsMovesTheWatchWithoutOverlap() async {
        let live = await sampling()
        await live.setDemand([.disk], onSample: ignore)
        await live.setDemand([.network], onSample: ignore)
        let running = await live.running()
        XCTAssertEqual(running, [.disk: .background, .network: .watched])
        await live.stop()
    }

    func testDiskSwitchedOffIsNotStartedByDemand() async {
        let live = await sampling(enabled: [.network])
        await live.setDemand([.disk], onSample: ignore)
        let running = await live.running()
        XCTAssertEqual(running, [.network: .background])
        await live.stop()
    }

    func testSwitchingDiskOffStopsARunningReading() async {
        let live = await sampling(enabled: [.disk])
        await live.setDemand([.disk], onSample: ignore)
        await live.setEnabled(.disk, false)
        let off = await live.running()
        XCTAssertEqual(off, [:])
        await live.setEnabled(.disk, true)
        let on = await live.running()
        XCTAssertEqual(on, [.disk: .watched])
        await live.stop()
    }

    /// Switched off drops the ring: the next sample has nothing to measure
    /// from.
    func testSwitchingDiskOffDropsTheSeries() async throws {
        let disk = DiskActivityMonitor(readCounters: { [DiskDriverCounters(id: 1, bytes: .zero)] })
        let live = LiveSampling(network: .readingNothing(), disk: disk, enabled: [.disk])
        await live.start()
        _ = await disk.sampleOnce(now: SampleTime.now + 1)
        let before = await disk.sampleOnce(now: SampleTime.now + 2)
        XCTAssertFalse(try XCTUnwrap(before).rates.isEmpty)
        await live.setEnabled(.disk, false)
        let after = await disk.sampleOnce(now: SampleTime.now + 3)
        XCTAssertEqual(after?.rates, [])
    }

    func testTheBackgroundPublishesNothing() async {
        let read = expectation(description: "a background read")
        read.assertForOverFulfill = false
        let disk = DiskActivityMonitor(readCounters: {
            read.fulfill()
            return []
        })
        let live = LiveSampling(network: .readingNothing(), disk: disk, enabled: [.disk])
        let published = LockedValue(0)
        await live.setDemand([]) { _ in published.update { $0 += 1 } }
        await live.start()
        await fulfillment(of: [read], timeout: 5)
        await live.stop()
        XCTAssertEqual(published.load(), 0)
    }

    func testStopIsTerminal() async {
        let live = await sampling()
        await live.stop()
        await live.setDemand([.disk], onSample: ignore)
        let running = await live.running()
        XCTAssertEqual(running, [:])
    }

    func testARunningDiskDeliversItsSamples() async {
        let live = await sampling()
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
        rates: [
            RatePoint(
                at: Date(timeIntervalSince1970: 1_790_000_000),
                rate: DiskRate(read: 42_000_000, written: 3_100_000))
        ])

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

    func testASampleAcrossASwitchCycleIsDropped() {
        let host = UsageEngineHost()
        host.setLiveDemand([.disk])
        let before = host.liveGeneration
        host.applyDiskSwitch(false)
        host.applyDiskSwitch(true)
        host.receive(.disk(reading), generation: before)
        XCTAssertNil(host.diskActivityReading)
    }

    func testASampleAskedForAfterASwitchCycleIsKept() {
        let host = UsageEngineHost()
        host.setLiveDemand([.disk])
        host.applyDiskSwitch(false)
        host.applyDiskSwitch(true)
        host.receive(.disk(reading), generation: host.liveGeneration)
        XCTAssertEqual(host.diskActivityReading, reading)
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

    /// VoiceOver reads the legend's own wording.
    func testTheSpokenRateIsTheLegendsWording() {
        XCTAssertEqual(
            DiskActivityPlatter.spokenRate(DiskRate(read: 42_000_000, written: 3_100_000)),
            "Read 42 MB/s, Write 3.1 MB/s")
        XCTAssertEqual(DiskActivityPlatter.spokenRate(nil), "No rate yet")
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
        var config = ServerConfig.hermetic(
            claudeDir: tempDir.appendingPathComponent("claude"),
            codexDir: tempDir.appendingPathComponent("codex"))
        config.disk = diskOn
        return UsageEngine(
            config: config, configURL: configURL, limitsProbe: ClaudeLimitsProbe { _ in .absent },
            claudeAccounts: .inert(),
            diskMonitor: DiskMonitor(read: { now in
                DiskReading(
                    observedAt: now, home: nil, purgeable: 0, physicalMemory: 1_024, volumes: [])
            }),
            networkMonitor: .readingNothing(),
            diskActivityMonitor: disk)
    }

    func testTheEngineLogsInTheBackgroundAndSamplesForAPage() async {
        let engine = makeEngine()
        let idle = await disk.cadence
        XCTAssertNil(idle)
        await engine.start { _ in }
        let started = await disk.cadence
        XCTAssertEqual(started, .background)
        await engine.setLiveDemand([.disk]) { _ in }
        let asked = await disk.cadence
        XCTAssertEqual(asked, .watched)
        await engine.setLiveDemand([]) { _ in }
        let released = await disk.cadence
        XCTAssertEqual(released, .background)
        await engine.stop()
    }

    /// The disk switch covers the activity: off means no activity either.
    func testDiskOffMeansNoActivity() async {
        let engine = makeEngine(disk: false)
        await engine.start { _ in }
        await engine.setLiveDemand([.disk]) { _ in }
        let running = await disk.isRunning
        XCTAssertFalse(running)
        await engine.stop()
    }

    func testSwitchingTheDiskOffStopsTheSampling() async {
        let engine = makeEngine()
        await engine.start { _ in }
        await engine.setLiveDemand([.disk]) { _ in }
        await engine.setDisk(enabled: false)
        let off = await disk.isRunning
        XCTAssertFalse(off)
        await engine.setDisk(enabled: true)
        let on = await disk.cadence
        XCTAssertEqual(on, .watched)
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
