import Darwin
import XCTest

@testable import Sissy

final class NetworkCounterParsingTests: XCTestCase {
    /// One `RTM_IFINFO2` message as the kernel lays it out: the header, then
    /// the `sockaddr_dl` naming the interface.
    private func interfaceMessage(
        _ name: String, received: UInt64, sent: UInt64, flags: Int32 = 0
    ) -> [UInt8] {
        let nameBytes = Array(name.utf8)
        let link: [UInt8] =
            [UInt8(8 + nameBytes.count), UInt8(AF_LINK), 0, 0, 0, UInt8(nameBytes.count), 0, 0]
            + nameBytes
        var header = if_msghdr2()
        header.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size + link.count)
        header.ifm_type = UInt8(RTM_IFINFO2)
        header.ifm_flags = flags
        header.ifm_data.ifi_ibytes = received
        header.ifm_data.ifi_obytes = sent
        return withUnsafeBytes(of: header) { Array($0) } + link
    }

    /// An address message, which the walk has to step over by its length.
    private func addressMessage(length: Int = 20) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: length)
        bytes[0] = UInt8(length)
        bytes[3] = UInt8(RTM_NEWADDR)
        return bytes
    }

    private func parse(_ bytes: [UInt8]) -> [NetworkInterfaceCounters] {
        bytes.withUnsafeBytes { NetworkReader.parse($0) }
    }

    func testReadsNameAndBothCountersOfEachInterface() {
        let parsed = parse(
            interfaceMessage("lo0", received: 10, sent: 10, flags: IFF_LOOPBACK) + addressMessage()
                + interfaceMessage("en0", received: 3_133_868_032, sent: 887_108_608))
        XCTAssertEqual(
            parsed,
            [
                NetworkInterfaceCounters(
                    name: "lo0", bytes: NetworkByteCounts(received: 10, sent: 10), isLoopback: true),
                NetworkInterfaceCounters(
                    name: "en0", bytes: NetworkByteCounts(received: 3_133_868_032, sent: 887_108_608),
                    isLoopback: false),
            ])
    }

    /// The reason for `NET_RT_IFLIST2`: a counter past 4 GiB survives whole.
    func testCountersPastFourGibibytesAreNotTruncated() {
        let parsed = parse(interfaceMessage("en0", received: 5_000_000_000_000, sent: 1 << 40))
        XCTAssertEqual(parsed.first?.bytes, NetworkByteCounts(received: 5_000_000_000_000, sent: 1 << 40))
    }

    func testAMessageRunningPastTheBufferEndsTheWalk() {
        let whole = interfaceMessage("en0", received: 1, sent: 2)
        let parsed = parse(whole + interfaceMessage("en1", received: 3, sent: 4).dropLast(3))
        XCTAssertEqual(parsed.map(\.name), ["en0"])
    }

    func testAZeroLengthMessageEndsTheWalk() {
        XCTAssertEqual(parse([0, 0, 0, 0] + interfaceMessage("en0", received: 1, sent: 2)), [])
    }
}

final class NetworkInterfaceFilterTests: XCTestCase {
    private func counters(_ name: String, loopback: Bool = false) -> NetworkInterfaceCounters {
        NetworkInterfaceCounters(name: name, bytes: .zero, isLoopback: loopback)
    }

    func testWiFiAndEthernetArePhysical() {
        for name in ["en0", "en4", "en12"] {
            XCTAssertTrue(NetworkInterfaceFilter.isPhysical(counters(name)), name)
        }
    }

    /// The families the kernel listed on the Mac this was measured on.
    func testSystemPlumbingIsNot() {
        for name in [
            "lo0", "gif0", "stf0", "awdl0", "llw0", "utun4", "bridge0", "anpi1", "ap1", "nan0",
        ] {
            XCTAssertFalse(NetworkInterfaceFilter.isPhysical(counters(name)), name)
        }
    }

    func testTheLoopbackFlagWinsOverTheName() {
        XCTAssertFalse(NetworkInterfaceFilter.isPhysical(counters("en9", loopback: true)))
    }

    func testAFamilyIsMatchedWholeRatherThanByPrefix() {
        XCTAssertTrue(NetworkInterfaceFilter.isPhysical(counters("apple0")))
    }

    /// A tunnelled download counted on `utun` too would be counted twice.
    func testSinceBootSumsOnlyThePhysicalLinks() {
        let all = [
            NetworkInterfaceCounters(
                name: "en0", bytes: NetworkByteCounts(received: 100, sent: 10), isLoopback: false),
            NetworkInterfaceCounters(
                name: "en5", bytes: NetworkByteCounts(received: 50, sent: 5), isLoopback: false),
            NetworkInterfaceCounters(
                name: "utun4", bytes: NetworkByteCounts(received: 90, sent: 9), isLoopback: false),
            NetworkInterfaceCounters(
                name: "lo0", bytes: NetworkByteCounts(received: 1_000, sent: 1_000), isLoopback: true),
        ]
        XCTAssertEqual(NetworkRates.sinceBoot(all), NetworkByteCounts(received: 150, sent: 15))
    }
}

final class NetworkRateTests: XCTestCase {
    private func counts(_ received: UInt64, _ sent: UInt64) -> NetworkByteCounts {
        NetworkByteCounts(received: received, sent: sent)
    }

    func testTheRateIsTheDeltaOverTheGap() {
        let rate = NetworkRates.rate(
            from: ["en0": counts(1_000, 500)], to: ["en0": counts(5_000, 1_500)], seconds: 2)
        XCTAssertEqual(rate, NetworkRate(received: 2_000, sent: 500))
    }

    /// A counter that went down is an interface that reset, not a transfer
    /// the size of the unsigned range.
    func testACounterThatWentBackwardsContributesNothing() {
        let rate = NetworkRates.rate(
            from: ["en0": counts(9_000, 9_000), "en5": counts(0, 0)],
            to: ["en0": counts(100, 100), "en5": counts(4_000, 2_000)], seconds: 1)
        XCTAssertEqual(rate, NetworkRate(received: 4_000, sent: 2_000))
    }

    /// An interface the previous sample did not have starts from its first
    /// reading, since its whole counter since boot did not move in a second.
    func testANewInterfaceContributesNothingUntilItsSecondSample() {
        let rate = NetworkRates.rate(
            from: ["en0": counts(0, 0)], to: ["en0": counts(1_000, 0), "en5": counts(7_000_000, 0)],
            seconds: 1)
        XCTAssertEqual(rate, NetworkRate(received: 1_000, sent: 0))
    }

    func testAnInterfaceThatLeftTakesNothingAway() {
        let rate = NetworkRates.rate(
            from: ["en0": counts(0, 0), "en5": counts(7_000_000, 0)], to: ["en0": counts(1_000, 0)],
            seconds: 1)
        XCTAssertEqual(rate, NetworkRate(received: 1_000, sent: 0))
    }

    func testNoTimeElapsedIsNoRate() {
        XCTAssertNil(NetworkRates.rate(from: [:], to: [:], seconds: 0))
        XCTAssertNil(NetworkRates.rate(from: [:], to: [:], seconds: -1))
    }
}

final class NetworkMonitorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// A monitor whose counters grow by `step` bytes a sample on `en0`.
    private func monitor(
        step: UInt64 = 1_000, primary: String? = "en0",
        displayNames: LockedValue<[String]> = LockedValue([])
    ) -> NetworkMonitor {
        let sample = LockedValue<UInt64>(0)
        return NetworkMonitor(
            readCounters: {
                let count = sample.load()
                sample.store(count + 1)
                return [
                    NetworkInterfaceCounters(
                        name: "en0", bytes: NetworkByteCounts(received: count * step, sent: count * step / 2),
                        isLoopback: false)
                ]
            },
            readPrimary: { primary },
            readDisplayName: { name in
                displayNames.store(displayNames.load() + [name])
                return "Wi-Fi"
            },
            readWiFi: { name in name == "en0" ? WiFiLink(rssi: -59, transmitRate: 286) : nil })
    }

    func testTheFirstSampleHasTotalsAndNoRate() async throws {
        let sampled = await monitor().sampleOnce(now: start)
        let reading = try XCTUnwrap(sampled)
        XCTAssertEqual(reading.rates, [])
        XCTAssertNil(reading.current)
        XCTAssertEqual(reading.interface, NetworkInterfaceName(bsdName: "en0", displayName: "Wi-Fi"))
        XCTAssertEqual(reading.wifi, WiFiLink(rssi: -59, transmitRate: 286))
    }

    func testTheSecondSampleMeasuresTheRate() async throws {
        let monitor = monitor()
        _ = await monitor.sampleOnce(now: start)
        let sampled = await monitor.sampleOnce(now: start + 1)
        let reading = try XCTUnwrap(sampled)
        XCTAssertEqual(reading.current, NetworkRate(received: 1_000, sent: 500))
        XCTAssertEqual(reading.sinceBoot, NetworkByteCounts(received: 1_000, sent: 500))
    }

    func testTheSeriesKeepsTwoMinutes() async throws {
        let monitor = monitor()
        var last: NetworkReading?
        for second in 0...(NetworkMonitor.historyLength + 10) {
            last = await monitor.sampleOnce(now: start + TimeInterval(second))
        }
        XCTAssertEqual(last?.rates.count, NetworkMonitor.historyLength)
    }

    /// The listing behind the display name costs 1.6 ms, so it is asked once
    /// per interface rather than once per sample.
    func testTheDisplayNameIsAskedOncePerInterface() async {
        let asked = LockedValue<[String]>([])
        let monitor = monitor(displayNames: asked)
        for second in 0..<5 { _ = await monitor.sampleOnce(now: start + TimeInterval(second)) }
        XCTAssertEqual(asked.load(), ["en0"])
    }

    func testNoDefaultRouteNamesNoInterfaceAndReadsNoSignal() async throws {
        let sampled = await monitor(primary: nil).sampleOnce(now: start)
        let reading = try XCTUnwrap(sampled)
        XCTAssertNil(reading.interface)
        XCTAssertNil(reading.wifi)
    }

    func testTheSignalIsReadOnlyForTheWiFiInterface() async throws {
        let sampled = await monitor(primary: "en5").sampleOnce(now: start)
        let reading = try XCTUnwrap(sampled)
        XCTAssertNil(reading.wifi)
    }

    /// A tab opened again starts a new series rather than drawing a line
    /// across the minutes nobody sampled.
    func testStopDropsTheSeries() async throws {
        let monitor = monitor()
        _ = await monitor.sampleOnce(now: start)
        _ = await monitor.sampleOnce(now: start + 1)
        await monitor.stop()
        let sampled = await monitor.sampleOnce(now: start + 60)
        let reading = try XCTUnwrap(sampled)
        XCTAssertEqual(reading.rates, [])
    }
}

final class LiveSamplingTests: XCTestCase {
    private func sampling(enabled: Set<LiveReading> = [.network]) -> LiveSampling {
        LiveSampling(
            network: NetworkMonitor(
                readCounters: { [] }, readPrimary: { nil }, readDisplayName: { _ in nil },
                readWiFi: { _ in nil }),
            enabled: enabled)
    }

    private let ignore: @Sendable (LiveSample) async -> Void = { _ in }

    func testNothingRunsUntilAPageAsks() async {
        let running = await sampling().running()
        XCTAssertEqual(running, [])
    }

    func testAPageAskingStartsItsReading() async {
        let live = sampling()
        await live.setDemand([.network], onSample: ignore)
        let running = await live.running()
        XCTAssertEqual(running, [.network])
    }

    /// A tab switch and a closing panel both say it as the empty demand.
    func testTheDemandGoingStopsIt() async {
        let live = sampling()
        await live.setDemand([.network], onSample: ignore)
        await live.setDemand([], onSample: ignore)
        let running = await live.running()
        XCTAssertEqual(running, [])
    }

    func testASwitchedOffReadingIsNotStartedByDemand() async {
        let live = sampling(enabled: [])
        await live.setDemand([.network], onSample: ignore)
        let running = await live.running()
        XCTAssertEqual(running, [])
    }

    func testSwitchingOffStopsARunningReading() async {
        let live = sampling()
        await live.setDemand([.network], onSample: ignore)
        await live.setEnabled(.network, false)
        let off = await live.running()
        XCTAssertEqual(off, [])
        await live.setEnabled(.network, true)
        let on = await live.running()
        XCTAssertEqual(on, [.network])
    }

    /// The engine's stop is terminal: a page asking afterwards starts nothing
    /// behind an engine that has gone.
    func testStopIsTerminal() async {
        let live = sampling()
        await live.setDemand([.network], onSample: ignore)
        await live.stop()
        await live.setDemand([.network], onSample: ignore)
        let running = await live.running()
        XCTAssertEqual(running, [])
    }

    func testARunningReadingDeliversItsSamples() async {
        let live = sampling()
        let delivered = expectation(description: "a sample")
        delivered.assertForOverFulfill = false
        await live.setDemand([.network]) { sample in
            if case .network = sample { delivered.fulfill() }
        }
        await fulfillment(of: [delivered], timeout: 5)
        await live.stop()
    }
}

@MainActor
final class NetworkHostTests: XCTestCase {
    private let reading = NetworkReading(
        observedAt: Date(timeIntervalSince1970: 1_790_000_000), interface: nil, wifi: nil,
        sinceBoot: .zero, rates: [])

    func testASampleNobodyAskedForIsDropped() {
        let host = UsageEngineHost()
        host.receive(.network(reading))
        XCTAssertNil(host.networkReading)
    }

    func testTheDemandGoingClearsTheReading() {
        let host = UsageEngineHost()
        host.setLiveDemand([.network])
        host.receive(.network(reading))
        XCTAssertEqual(host.networkReading, reading)
        host.setLiveDemand([])
        XCTAssertNil(host.networkReading)
    }

    func testOnlyTheNetworkTabAsksForTheNetwork() {
        for tab in PanelTab.allCases {
            XCTAssertEqual(tab.liveReadings, tab == .network ? [.network] : [], "\(tab)")
        }
    }

    func testTheNetworkTabFollowsItsSwitchAndSitsBeforeForge() {
        let snapshot = UsagePanelSnapshot.make(
            frame: FrameData(tokens: 0, cost: 0, burn: nil, providers: [], keepAwake: .off))
        XCTAssertEqual(PanelTab.visible(in: snapshot, network: true), [.usage, .sessions, .network])
        XCTAssertEqual(PanelTab.visible(in: snapshot, network: false), [.usage, .sessions])
        let order = PanelTab.allCases
        XCTAssertEqual(order.firstIndex(of: .network).map { $0 + 1 }, order.firstIndex(of: .forge))
    }
}

final class NetworkFormatTests: XCTestCase {
    func testARateReadsAtAPersonsGrain() {
        XCTAssertEqual(UsageFormat.networkRate(0), "0 KB/s")
        XCTAssertEqual(UsageFormat.networkRate(310_400), "310 KB/s")
        XCTAssertEqual(UsageFormat.networkRate(2_440_000), "2.4 MB/s")
        XCTAssertEqual(UsageFormat.networkRate(48_600_000), "49 MB/s")
        XCTAssertEqual(UsageFormat.networkRate(1_260_000_000), "1.3 GB/s")
    }

    /// A step is taken on the printed figure, so no rate grows a fourth digit.
    func testARateNeverReadsFourDigitsAtAStep() {
        XCTAssertEqual(UsageFormat.networkRate(999_600), "1.0 MB/s")
        XCTAssertEqual(UsageFormat.networkRate(9_960_000), "10 MB/s")
        XCTAssertEqual(UsageFormat.networkRate(999_600_000), "1.0 GB/s")
    }

    func testTheHeadlineNamesEachDirection() {
        XCTAssertEqual(UsageFormat.networkDown(2_440_000), "↓ 2.4 MB/s")
        XCTAssertEqual(UsageFormat.networkUp(310_400), "↑ 310 KB/s")
        XCTAssertEqual(UsageFormat.networkDown(nil), "↓ " + UsageFormat.macLevel(nil))
    }

    func testTheCaptionNamesTheLink() {
        XCTAssertEqual(
            UsageFormat.networkCaption(NetworkInterfaceName(bsdName: "en0", displayName: "Wi-Fi")),
            "Wi-Fi · now")
        XCTAssertEqual(UsageFormat.networkCaption(nil), "Not connected · now")
    }

    func testTheInterfaceCarriesItsBSDNameOnce() {
        XCTAssertEqual(
            UsageFormat.networkInterface(NetworkInterfaceName(bsdName: "en0", displayName: "Wi-Fi")),
            "Wi-Fi (en0)")
        XCTAssertEqual(
            UsageFormat.networkInterface(
                NetworkInterfaceName(bsdName: "en4", displayName: "Ethernet Adapter (en4)")),
            "Ethernet Adapter (en4)")
        XCTAssertEqual(
            UsageFormat.networkInterface(NetworkInterfaceName(bsdName: "utun4", displayName: nil)),
            "utun4")
    }

    func testTheSignalAndSinceBootRows() {
        XCTAssertEqual(
            UsageFormat.networkSignal(WiFiLink(rssi: -59, transmitRate: 286)), "-59 dBm · 286 Mbps")
        XCTAssertEqual(
            UsageFormat.networkSinceBoot(NetworkByteCounts(received: 1_400_000_000, sent: 3_000_000_000)),
            "↓ 1.4 GB · ↑ 3.0 GB")
    }
}

final class NetworkEngineTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-network-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var configURL: URL { tempDir.appendingPathComponent("server.json") }

    /// A monitor reading no hardware, so the suite never samples the Mac.
    private let monitor = NetworkMonitor(
        readCounters: { [] }, readPrimary: { nil }, readDisplayName: { _ in nil },
        readWiFi: { _ in nil })

    private func makeEngine() -> UsageEngine {
        var config = ServerConfig.defaults
        config.claudeDataDir = tempDir.appendingPathComponent("claude").path
        config.codexDataDir = tempDir.appendingPathComponent("codex").path
        config.remotePricing = false
        config.statusChecks = false
        config.macHealth = false
        return UsageEngine(
            config: config, configURL: configURL, limitsProbe: ClaudeLimitsProbe { _ in .absent },
            claudeAccounts: .inert(), networkMonitor: monitor)
    }

    func testTheEngineSamplesOnlyWhileAPageAsks() async {
        let engine = makeEngine()
        let idle = await monitor.isRunning
        XCTAssertFalse(idle)
        await engine.setLiveDemand([.network]) { _ in }
        let asked = await monitor.isRunning
        XCTAssertTrue(asked)
        await engine.setLiveDemand([]) { _ in }
        let released = await monitor.isRunning
        XCTAssertFalse(released)
    }

    func testTheSwitchStopsTheSamplingAndIsWrittenDown() async throws {
        let engine = makeEngine()
        await engine.setLiveDemand([.network]) { _ in }
        await engine.setNetwork(enabled: false)
        let running = await monitor.isRunning
        XCTAssertFalse(running)
        XCTAssertEqual(try ServerConfig.load(from: configURL).network, false)
    }

    func testAStoppedEngineStartsNothing() async {
        let engine = makeEngine()
        await engine.stop()
        await engine.setLiveDemand([.network]) { _ in }
        let running = await monitor.isRunning
        XCTAssertFalse(running)
    }

    func testAConfigWrittenBeforeTheSwitchLandsOnItOn() throws {
        try Data(#"{"macHealth": false}"#.utf8).write(to: configURL)
        XCTAssertTrue(try ServerConfig.load(from: configURL).network)
        try Data(#"{"network": false}"#.utf8).write(to: configURL)
        XCTAssertFalse(try ServerConfig.load(from: configURL).network)
    }
}
