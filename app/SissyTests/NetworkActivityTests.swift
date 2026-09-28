import Darwin
import XCTest

@testable import Sissy

final class NetworkCounterParsingTests: XCTestCase {
    /// One `RTM_IFINFO2` message as the kernel lays it out: the header, then
    /// the `sockaddr_dl` naming the interface.
    private func interfaceMessage(
        _ name: String, received: UInt64, sent: UInt64, flags: Int32 = 0, lastChange: Int = 0
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
        header.ifm_data.ifi_lastchange.tv_sec = Int32(lastChange)
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

    /// Wall-clock seconds, as the kernel wrote them on macOS 27.0.
    func testReadsWhenTheLinkLastChanged() {
        let parsed = parse(interfaceMessage("en0", received: 1, sent: 2, lastChange: 1_790_577_837))
        XCTAssertEqual(parsed.first?.lastChange, Date(timeIntervalSince1970: 1_790_577_837))
    }

    func testALinkTheKernelNeverDatedHasNoChange() {
        XCTAssertNil(parse(interfaceMessage("en0", received: 1, sent: 2)).first?.lastChange)
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
        XCTAssertEqual(
            NetworkRates.totals(all, bootedAt: nil).bytes, NetworkByteCounts(received: 150, sent: 15))
    }
}

final class NetworkTotalsTests: XCTestCase {
    private let boot = Date(timeIntervalSince1970: 1_790_515_911)

    private func counters(
        _ name: String, received: UInt64 = 1_000, changed after: TimeInterval?
    ) -> NetworkInterfaceCounters {
        NetworkInterfaceCounters(
            name: name, bytes: NetworkByteCounts(received: received, sent: 10), isLoopback: false,
            lastChange: after.map { boot + $0 })
    }

    func testLinksThatLastChangedWhileBootingAreSinceBoot() {
        let totals = NetworkRates.totals(
            [counters("en0", changed: 14), counters("en4", changed: 65)], bootedAt: boot)
        XCTAssertNil(totals.since)
    }

    /// A counter that restarted after boot holds nothing from before its
    /// restart, so the figure is dated by it rather than by the boot.
    func testACounterThatRestartedAfterBootDatesTheTotals() {
        let totals = NetworkRates.totals(
            [counters("en0", changed: 14), counters("en5", changed: 61_926)], bootedAt: boot)
        XCTAssertEqual(totals.since, boot + 61_926)
        XCTAssertEqual(totals.bytes, NetworkByteCounts(received: 2_000, sent: 20))
    }

    func testTheLatestRestartDatesTheTotals() {
        let totals = NetworkRates.totals(
            [counters("en0", changed: 7_200), counters("en5", changed: 3_600)], bootedAt: boot)
        XCTAssertEqual(totals.since, boot + 7_200)
    }

    func testALinkThatCarriedNothingDatesNothing() {
        let idle = NetworkInterfaceCounters(
            name: "en5", bytes: .zero, isLoopback: false, lastChange: boot + 7_200)
        let totals = NetworkRates.totals([counters("en0", changed: 14), idle], bootedAt: boot)
        XCTAssertNil(totals.since)
    }

    func testATunnelThatChangedDatesNothing() {
        let totals = NetworkRates.totals(
            [counters("en0", changed: 14), counters("utun4", changed: 7_200)], bootedAt: boot)
        XCTAssertNil(totals.since)
    }

    func testWithNoBootTimeNoChangeCountsAsTheBoots() {
        let totals = NetworkRates.totals([counters("en0", changed: 14)], bootedAt: nil)
        XCTAssertEqual(totals.since, boot + 14)
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
    private let start = SampleTime(
        wall: Date(timeIntervalSince1970: 1_790_000_000), instant: .now)

    /// A monitor whose counters grow by `step` bytes a sample on `en0`,
    /// dated as having been up since boot.
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
            readWiFi: { name in name == "en0" ? WiFiLink(rssi: -59, transmitRate: 286) : nil },
            bootedAt: start.wall)
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
        XCTAssertEqual(reading.totals.bytes, NetworkByteCounts(received: 1_000, sent: 500))
    }

    /// Two minutes by time: a point is dropped once it is older than the
    /// window before the latest sample, whatever the count.
    func testTheSeriesKeepsTwoMinutesByTime() async throws {
        let monitor = monitor()
        var last: NetworkReading?
        for second in 0...200 {
            last = await monitor.sampleOnce(now: start + TimeInterval(second))
        }
        let rates = try XCTUnwrap(last?.rates)
        XCTAssertEqual(rates.first?.at, (start + 200 - LiveCadence.window).wall)
        XCTAssertEqual(rates.last?.at, (start + 200).wall)
        XCTAssertEqual(rates.count, 121)
    }

    /// The background keeps the same two minutes at its own pace, and the
    /// first watched sample carries them.
    func testTheBackgroundKeepsTwoMinutesAtItsOwnPace() async throws {
        let monitor = monitor()
        for step in 0...60 {
            _ = await monitor.record(now: start + TimeInterval(step * 5), next: .background)
        }
        let sampled = await monitor.sampleOnce(now: start + 305)
        let rates = try XCTUnwrap(sampled?.rates)
        XCTAssertEqual(rates.first?.at, (start + 185).wall)
        XCTAssertEqual(rates.count, 25)
    }

    /// One ring across both cadences: five-second points from the background
    /// and one-second points from the page, each dated by its own sample.
    func testBothCadencesFeedOneDatedSeries() async throws {
        let monitor = monitor()
        for second in [0, 5, 10] {
            _ = await monitor.record(now: start + TimeInterval(second), next: .background)
        }
        var last: NetworkReading?
        for second in [12, 13, 14] { last = await monitor.sampleOnce(now: start + TimeInterval(second)) }
        XCTAssertEqual(last?.rates.map(\.at), [5, 10, 12, 13, 14].map { (start + TimeInterval($0)).wall })
        XCTAssertEqual(last?.rates.first?.rate, NetworkRate(received: 200, sent: 100))
    }

    /// A rate averaged over a sleep would be drawn as a line across seconds
    /// nobody measured, so the series starts again from the sample after it.
    func testAGapBeyondTheWatchedBoundRestartsTheSeries() async throws {
        let monitor = monitor()
        for second in 0..<3 { _ = await monitor.sampleOnce(now: start + TimeInterval(second)) }
        let afterGap = start + 2 + LiveCadence.watched.maximumGap + 1
        let resumed = await monitor.sampleOnce(now: afterGap)
        XCTAssertEqual(resumed?.rates, [])
        let next = await monitor.sampleOnce(now: afterGap + 1)
        XCTAssertEqual(next?.rates.map(\.rate), [NetworkRate(received: 1_000, sent: 500)])
    }

    func testALateSampleWithinTheBoundStaysInTheSeries() async throws {
        let monitor = monitor()
        _ = await monitor.sampleOnce(now: start)
        _ = await monitor.sampleOnce(now: start + 1)
        let late = await monitor.sampleOnce(now: start + 1 + LiveCadence.watched.maximumGap)
        XCTAssertEqual(late?.rates.count, 2)
    }

    /// Five seconds is a gap at the page's pace and one step at the
    /// background's, so the bound follows the cadence in force.
    func testTheBoundFollowsTheCadence() async throws {
        let watched = monitor()
        _ = await watched.sampleOnce(now: start)
        let afterWatched = await watched.sampleOnce(now: start + 5)
        XCTAssertEqual(afterWatched?.rates, [])
        let background = monitor()
        _ = await background.record(now: start, next: .background)
        _ = await background.record(now: start + 5, next: .background)
        let atBound = await background.sampleOnce(
            now: start + 5 + LiveCadence.background.maximumGap, next: .background)
        XCTAssertEqual(atBound?.rates.count, 2)
        let pastBound = await background.sampleOnce(
            now: start + 5 + 2 * LiveCadence.background.maximumGap + 1)
        XCTAssertEqual(pastBound?.rates, [])
    }

    /// The page's first sample comes up to a background step after the last
    /// background one, and is judged by the pace that step was waited at.
    func testThePagesFirstSampleKeepsTheBackgroundSeries() async throws {
        let monitor = monitor()
        _ = await monitor.record(now: start, next: .background)
        _ = await monitor.record(now: start + 5, next: .background)
        let opened = await monitor.sampleOnce(now: start + 10)
        XCTAssertEqual(opened?.rates.count, 2)
    }

    /// A counter that restarts while the tab is open costs that sample its
    /// rate, and the totals from then on are dated by the restart.
    func testACounterThatRestartsDatesTheTotals() async throws {
        let restart = start + 3_600
        let samples = LockedValue<[NetworkInterfaceCounters]>([
            NetworkInterfaceCounters(
                name: "en0", bytes: NetworkByteCounts(received: 9_000, sent: 9_000), isLoopback: false,
                lastChange: (start + 10).wall),
            NetworkInterfaceCounters(
                name: "en0", bytes: NetworkByteCounts(received: 500, sent: 100), isLoopback: false,
                lastChange: restart.wall),
        ])
        let monitor = NetworkMonitor(
            readCounters: {
                let next = samples.load()
                samples.store(Array(next.dropFirst()))
                return [next[0]]
            },
            readPrimary: { nil }, readDisplayName: { _ in nil }, readWiFi: { _ in nil },
            bootedAt: start.wall)
        let before = await monitor.sampleOnce(now: restart - 1)
        XCTAssertNil(before?.totals.since)
        let after = await monitor.sampleOnce(now: restart)
        XCTAssertEqual(after?.rates.map(\.rate), [NetworkRate(received: 0, sent: 0)])
        XCTAssertEqual(after?.totals.since, restart.wall)
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
    private func sampling(
        enabled: Set<LiveReading> = [.network], network: NetworkMonitor = .readingNothing()
    ) -> LiveSampling {
        LiveSampling(
            network: network, disk: DiskActivityMonitor(readCounters: { [] }), enabled: enabled)
    }

    private let ignore: @Sendable (LiveSample) async -> Void = { _ in }

    func testNothingRunsUntilTheEngineStarts() async {
        let live = sampling()
        await live.setDemand([.network], onSample: ignore)
        let running = await live.running()
        XCTAssertEqual(running, [:])
    }

    /// With the switch on and no page, the counters are logged in the
    /// background.
    func testAStartedReadingRunsInTheBackground() async {
        let live = sampling()
        await live.start()
        let running = await live.running()
        XCTAssertEqual(running, [.network: .background])
        await live.stop()
    }

    /// The tab on screen moves the monitor to one a second, and a tab switch
    /// or a closing panel, both the empty demand, moves it back.
    func testThePageSetsTheCadence() async {
        let live = sampling()
        await live.start()
        await live.setDemand([.network], onSample: ignore)
        let watched = await live.running()
        XCTAssertEqual(watched, [.network: .watched])
        await live.setDemand([], onSample: ignore)
        let background = await live.running()
        XCTAssertEqual(background, [.network: .background])
        await live.stop()
    }

    /// A page opening does not wait out the background's five seconds.
    func testAPageArrivingIsServedAtOnce() async {
        let read = expectation(description: "a background read")
        read.assertForOverFulfill = false
        let network = NetworkMonitor.readingNothing(onCounters: { read.fulfill() })
        let live = sampling(network: network)
        await live.start()
        await fulfillment(of: [read], timeout: 5)
        let delivered = expectation(description: "a sample for the page")
        delivered.assertForOverFulfill = false
        await live.setDemand([.network]) { _ in delivered.fulfill() }
        await fulfillment(of: [delivered], timeout: 3)
        await live.stop()
    }

    /// In the background only the counters are read, and nothing is
    /// published, whatever callback the last page left.
    func testTheBackgroundReadsTheCountersAndPublishesNothing() async {
        let read = expectation(description: "a background read")
        read.assertForOverFulfill = false
        let asked = LockedValue(0)
        let network = NetworkMonitor(
            readCounters: {
                read.fulfill()
                return []
            },
            readPrimary: {
                asked.update { $0 += 1 }
                return nil
            },
            readDisplayName: { _ in nil },
            readWiFi: { _ in
                asked.update { $0 += 1 }
                return nil
            })
        let live = sampling(network: network)
        let published = LockedValue(0)
        await live.setDemand([]) { _ in published.update { $0 += 1 } }
        await live.start()
        await fulfillment(of: [read], timeout: 5)
        await live.stop()
        XCTAssertEqual(published.load(), 0)
        XCTAssertEqual(asked.load(), 0)
    }

    func testASwitchedOffReadingIsNotStarted() async {
        let live = sampling(enabled: [])
        await live.start()
        await live.setDemand([.network], onSample: ignore)
        let running = await live.running()
        XCTAssertEqual(running, [:])
    }

    func testSwitchingOffStopsARunningReading() async {
        let live = sampling()
        await live.start()
        await live.setDemand([.network], onSample: ignore)
        await live.setEnabled(.network, false)
        let off = await live.running()
        XCTAssertEqual(off, [:])
        await live.setEnabled(.network, true)
        let on = await live.running()
        XCTAssertEqual(on, [.network: .watched])
        await live.stop()
    }

    /// The switch off drops the ring, so a switch on starts a new series.
    func testSwitchingOffDropsTheSeries() async throws {
        let network = NetworkMonitor.readingNothing()
        let live = sampling(network: network)
        await live.start()
        _ = await network.sampleOnce(now: SampleTime.now + 1)
        let before = await network.sampleOnce(now: SampleTime.now + 2)
        XCTAssertFalse(try XCTUnwrap(before).rates.isEmpty)
        await live.setEnabled(.network, false)
        let after = await network.sampleOnce(now: SampleTime.now + 3)
        XCTAssertEqual(after?.rates, [])
    }

    /// The engine's stop is terminal: a page asking afterwards starts nothing
    /// behind an engine that has gone.
    func testStopIsTerminal() async {
        let live = sampling()
        await live.start()
        await live.stop()
        await live.start()
        await live.setDemand([.network], onSample: ignore)
        let running = await live.running()
        XCTAssertEqual(running, [:])
    }

    /// A page asking again while the reading runs is the one its samples go
    /// to from then on.
    func testTheLatestCallerReceivesTheSamples() async {
        let live = sampling()
        await live.start()
        let first = LockedValue(0)
        let latest = expectation(description: "a sample to the second caller")
        latest.assertForOverFulfill = false
        await live.setDemand([.network]) { _ in first.update { $0 += 1 } }
        await live.setDemand([.network]) { _ in latest.fulfill() }
        await fulfillment(of: [latest], timeout: 5)
        await live.stop()
        XCTAssertLessThanOrEqual(first.load(), 1)
    }

    func testARunningReadingDeliversItsSamples() async {
        let live = sampling()
        await live.start()
        let delivered = expectation(description: "a sample")
        delivered.assertForOverFulfill = false
        await live.setDemand([.network]) { sample in
            if case .network = sample { delivered.fulfill() }
        }
        await fulfillment(of: [delivered], timeout: 5)
        await live.stop()
    }
}

extension NetworkMonitor {
    /// A monitor reading no hardware, so a suite never samples the Mac;
    /// `onCounters` runs on every counter read.
    static func readingNothing(onCounters: @escaping @Sendable () -> Void = {}) -> NetworkMonitor {
        NetworkMonitor(
            readCounters: {
                onCounters()
                return []
            },
            readPrimary: { nil }, readDisplayName: { _ in nil }, readWiFi: { _ in nil })
    }
}

@MainActor
final class NetworkHostTests: XCTestCase {
    private let reading = NetworkReading(
        observedAt: Date(timeIntervalSince1970: 1_790_000_000), interface: nil, wifi: nil,
        totals: NetworkTotals(bytes: .zero, since: nil), rates: [])

    func testASampleNobodyAskedForIsDropped() {
        let host = UsageEngineHost()
        host.receive(.network(reading), generation: host.liveGeneration)
        XCTAssertNil(host.networkReading)
    }

    /// A tab switched away and back inside a second asks for the same thing,
    /// and the sample taken for the first visit belongs to a dropped series.
    func testASampleFromAnEarlierDemandIsDropped() {
        let host = UsageEngineHost()
        host.setLiveDemand([.network])
        let first = host.liveGeneration
        host.setLiveDemand([])
        host.setLiveDemand([.network])
        host.receive(.network(reading), generation: first)
        XCTAssertNil(host.networkReading)
    }

    /// A sample already waiting for the main actor when the switch went off
    /// and on again was taken for a series the switch dropped, and the demand
    /// reads the same on both sides of the pair.
    func testASampleAcrossASwitchCycleIsDropped() {
        let host = UsageEngineHost()
        host.setLiveDemand([.network])
        let before = host.liveGeneration
        host.applyNetworkSwitch(false)
        host.applyNetworkSwitch(true)
        host.receive(.network(reading), generation: before)
        XCTAssertNil(host.networkReading)
    }

    func testASampleAskedForAfterASwitchCycleIsKept() {
        let host = UsageEngineHost()
        host.setLiveDemand([.network])
        host.applyNetworkSwitch(false)
        host.applyNetworkSwitch(true)
        host.receive(.network(reading), generation: host.liveGeneration)
        XCTAssertEqual(host.networkReading, reading)
    }

    func testTheDemandGoingClearsTheReading() {
        let host = UsageEngineHost()
        host.setLiveDemand([.network])
        host.receive(.network(reading), generation: host.liveGeneration)
        XCTAssertEqual(host.networkReading, reading)
        host.setLiveDemand([])
        XCTAssertNil(host.networkReading)
    }

    func testOnlyTheNetworkTabAsksForTheNetwork() {
        for tab in PanelTab.allCases {
            XCTAssertEqual(tab.liveReadings.contains(.network), tab == .network, "\(tab)")
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

    func testTheTotalsClaimBootOnlyWhenTheCountersDo() {
        let now = Date(timeIntervalSince1970: 1_790_620_338)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome") ?? .gmt
        let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
        let bytes = NetworkByteCounts(received: 1, sent: 1)
        XCTAssertEqual(UsageFormat.networkTotalsLabel(nil, now: now, calendar: calendar), "Since boot")
        XCTAssertEqual(
            UsageFormat.networkTotalsLabel(
                NetworkTotals(bytes: bytes, since: nil), now: now, calendar: calendar),
            "Since boot")
        let today = now - 3_600
        XCTAssertEqual(
            UsageFormat.networkTotalsLabel(
                NetworkTotals(bytes: bytes, since: today), now: now, calendar: calendar),
            "Since " + today.formatted(style.hour().minute()))
        let earlier = now - 3 * 86_400
        XCTAssertEqual(
            UsageFormat.networkTotalsLabel(
                NetworkTotals(bytes: bytes, since: earlier), now: now, calendar: calendar),
            "Since " + earlier.formatted(style.day().month(.abbreviated)))
    }

    func testTheSignalAndSinceBootRows() {
        XCTAssertEqual(
            UsageFormat.networkSignal(WiFiLink(rssi: -59, transmitRate: 286)), "-59 dBm · 286 Mbps")
        XCTAssertEqual(
            UsageFormat.networkTotals(
                NetworkTotals(
                    bytes: NetworkByteCounts(received: 1_400_000_000, sent: 3_000_000_000), since: nil)),
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

    private let monitor = NetworkMonitor.readingNothing()

    private func makeEngine() -> UsageEngine {
        var config = ServerConfig.defaults
        config.claudeDataDir = tempDir.appendingPathComponent("claude").path
        config.codexDataDir = tempDir.appendingPathComponent("codex").path
        config.remotePricing = false
        config.statusChecks = false
        config.macHealth = false
        config.disk = false
        return UsageEngine(
            config: config, configURL: configURL, limitsProbe: ClaudeLimitsProbe { _ in .absent },
            claudeAccounts: .inert(), networkMonitor: monitor)
    }

    /// The engine starts the background log, a page moves it to one a
    /// second, and the page going moves it back.
    func testTheEngineLogsInTheBackgroundAndSamplesForAPage() async {
        let engine = makeEngine()
        let idle = await monitor.cadence
        XCTAssertNil(idle)
        await engine.start { _ in }
        let started = await monitor.cadence
        XCTAssertEqual(started, .background)
        await engine.setLiveDemand([.network]) { _ in }
        let asked = await monitor.cadence
        XCTAssertEqual(asked, .watched)
        await engine.setLiveDemand([]) { _ in }
        let released = await monitor.cadence
        XCTAssertEqual(released, .background)
        await engine.stop()
        let stopped = await monitor.cadence
        XCTAssertNil(stopped)
    }

    func testTheSwitchStopsTheSamplingAndIsWrittenDown() async throws {
        let engine = makeEngine()
        await engine.start { _ in }
        await engine.setLiveDemand([.network]) { _ in }
        await engine.setNetwork(enabled: false)
        let running = await monitor.isRunning
        XCTAssertFalse(running)
        XCTAssertEqual(try ServerConfig.load(from: configURL).network, false)
        await engine.stop()
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

/// Points placed by time, so a series fed at two cadences reads true against
/// one axis.
@MainActor
final class RateSparklineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let width: CGFloat = 240

    private func x(_ age: TimeInterval) -> CGFloat {
        RateSparkline.x(of: now - age, now: now, width: width)
    }

    func testTheWindowSpansTheWidth() {
        XCTAssertEqual(x(0), width)
        XCTAssertEqual(x(LiveCadence.window), 0)
        XCTAssertEqual(x(LiveCadence.window / 2), width / 2)
    }

    /// A five-second step is five times as wide as a one-second one.
    func testMixedSpacingIsDrawnInProportion() {
        let second = width / CGFloat(LiveCadence.window)
        XCTAssertEqual(x(95) - x(100), 5 * second, accuracy: 0.001)
        XCTAssertEqual(x(0) - x(1), second, accuracy: 0.001)
    }

    func testAPointOutsideTheWindowIsClampedToThePlot() {
        XCTAssertEqual(x(-10), width)
        XCTAssertEqual(x(LiveCadence.window + 30), 0)
    }

    func testTheHoverPicksThePointNearestInTime() {
        let times = [100, 95, 90, 2, 1, 0].map { now - TimeInterval($0) }
        let pointer = x(93)
        XCTAssertEqual(RateSparkline.index(at: pointer, of: times, now: now, width: width), 1)
        XCTAssertEqual(RateSparkline.index(at: width, of: times, now: now, width: width), 5)
    }

    /// Left of the oldest point is minutes the series never saw.
    func testTheHoverLeftOfTheSeriesPicksNothing() {
        let times = [100, 95].map { now - TimeInterval($0) }
        XCTAssertNil(RateSparkline.index(at: 0, of: times, now: now, width: width))
        XCTAssertEqual(
            RateSparkline.index(
                at: x(100 + RateSparkline.hoverSlack / 2), of: times, now: now, width: width), 0)
    }
}
