import XCTest

@testable import Sissy

/// The Mac's own reading: the kernel's level, the disk graded against RAM, and
/// the apps holding the most besides the agents.
final class MacHealthLevelTests: XCTestCase {
    private static let gigabyte: UInt64 = 1 << 30

    func testTheKernelsThreeStepsMapToTheirLevels() {
        XCTAssertEqual(MacHealthLevel(kernelPressure: 1), .normal)
        XCTAssertEqual(MacHealthLevel(kernelPressure: 2), .warn)
        XCTAssertEqual(MacHealthLevel(kernelPressure: 4), .critical)
    }

    /// A value the kernel has never answered is not rounded to the nearest
    /// step: it is no reading.
    func testAnUnknownKernelValueIsNoLevel() {
        XCTAssertNil(MacHealthLevel(kernelPressure: 0))
        XCTAssertNil(MacHealthLevel(kernelPressure: 3))
    }

    func testTheLevelsEscalateInOrder() {
        XCTAssertLessThan(MacHealthLevel.normal, .warn)
        XCTAssertLessThan(MacHealthLevel.warn, .critical)
    }

    /// The Mac that froze on 2026-09-27: 24 GB of RAM and 23 GB free, which is
    /// under one multiple and critical, where 69 GB free on the same Mac is
    /// over two and fine.
    func testTheDiskIsGradedInMultiplesOfRAM() {
        let ram = 24 * Self.gigabyte
        func level(_ free: UInt64) -> MacHealthLevel {
            MacHealthLevel.disk(free: Int64(free), physicalMemory: ram)
        }
        XCTAssertEqual(level(23 * Self.gigabyte), .critical)
        XCTAssertEqual(level(24 * Self.gigabyte), .warn)
        XCTAssertEqual(level(47 * Self.gigabyte), .warn)
        XCTAssertEqual(level(48 * Self.gigabyte), .normal)
        XCTAssertEqual(level(69 * Self.gigabyte), .normal)
    }

    func testANegativeFreeFigureIsCritical() {
        XCTAssertEqual(MacHealthLevel.disk(free: -1, physicalMemory: 1), .critical)
    }

    func testTheSwapFieldsAreReadFromTheKernelsStruct() {
        var usage = xsw_usage()
        usage.xsu_total = 2_048
        usage.xsu_used = 512
        usage.xsu_avail = 1_536
        XCTAssertEqual(MacSwapUsage(usage), MacSwapUsage(used: 512, total: 2_048))
    }
}

final class MacHealthReadingTests: XCTestCase {
    private func reading(pressure: MacHealthLevel?, diskFree: Int64?) -> MacHealthReading {
        var reading = MacHealthReading(
            observedAt: Date(), pressure: pressure, freeMemoryPercent: nil, swap: nil,
            physicalMemory: 100, loadAverage: nil, activeCores: 1, uptime: 0)
        reading.diskFree = diskFree
        return reading
    }

    func testTheOverallLevelIsTheWorseOfTheKernelAndTheDisk() {
        XCTAssertEqual(reading(pressure: .normal, diskFree: 150).level, .warn)
        XCTAssertEqual(reading(pressure: .critical, diskFree: 500).level, .critical)
        XCTAssertEqual(reading(pressure: .warn, diskFree: 50).level, .critical)
        XCTAssertEqual(reading(pressure: .normal, diskFree: 500).level, .normal)
    }

    func testOneSideMissingLeavesTheOther() {
        XCTAssertEqual(reading(pressure: nil, diskFree: 50).level, .critical)
        XCTAssertEqual(reading(pressure: .warn, diskFree: nil).level, .warn)
        XCTAssertNil(reading(pressure: .warn, diskFree: nil).diskLevel)
    }

    /// Neither side read is not a healthy Mac.
    func testNothingReadIsNoLevel() {
        XCTAssertNil(reading(pressure: nil, diskFree: nil).level)
    }

    /// The real kernel, asserted on its invariants rather than on what this
    /// Mac happens to be doing while the suite runs.
    func testTheRealReadingIsInternallyConsistent() {
        let reading = SystemHealthReader.read()
        XCTAssertGreaterThan(reading.physicalMemory, 0)
        XCTAssertGreaterThan(reading.activeCores, 0)
        if let percent = reading.freeMemoryPercent {
            XCTAssertTrue((0...100).contains(percent), "free memory read as \(percent)%")
        }
        if let swap = reading.swap {
            XCTAssertLessThanOrEqual(swap.used, swap.total)
        }
    }
}

final class MacAppGroupingTests: XCTestCase {
    func testAHelperInsideABundleCountsTowardsTheBundle() {
        let helper =
            "/Applications/Orca.app/Contents/Frameworks/Orca Helper (Renderer).app"
            + "/Contents/MacOS/Orca Helper (Renderer)"
        let grouped = MacAppGrouping.group(executablePath: helper)
        XCTAssertEqual(grouped.path, "/Applications/Orca.app")
        XCTAssertEqual(grouped.name, "Orca")
    }

    func testAProcessOutsideABundleIsNamedByItsExecutable() {
        let grouped = MacAppGrouping.group(executablePath: "/opt/homebrew/bin/node")
        XCTAssertEqual(grouped.path, "/opt/homebrew/bin/node")
        XCTAssertEqual(grouped.name, "node")
    }

    /// A component that merely contains `.app` is not a bundle.
    func testOnlyAComponentEndingInAppIsABundle() {
        let grouped = MacAppGrouping.group(executablePath: "/Users/me/my.apple/tool")
        XCTAssertEqual(grouped.name, "tool")
        XCTAssertEqual(
            MacAppGrouping.group(executablePath: "/x/..app/Contents/MacOS/y").path, "/x/..app")
    }

    func testTheHeaviestAreSummedPerAppDearestFirstAndBounded() {
        let apps = MacAppGrouping.heaviest([
            ("/Applications/Helium.app/Contents/MacOS/Helium", 100),
            ("/Applications/Helium.app/Contents/Frameworks/H.app/Contents/MacOS/H", 300),
            ("/Applications/Helium.app/Contents/Frameworks/H.app/Contents/MacOS/H", 300),
            ("/usr/local/bin/python3", 500),
            ("/Applications/Mail.app/Contents/MacOS/Mail", 200),
            ("/usr/bin/small", 1),
            ("", 9_999),
        ])
        XCTAssertEqual(apps.map(\.name), ["Helium", "python3", "Mail"])
        XCTAssertEqual(apps.map(\.footprint), [700, 500, 200])
    }

    func testATieIsBrokenByName() {
        let apps = MacAppGrouping.heaviest([("/b/zed", 5), ("/a/alpha", 5)])
        XCTAssertEqual(apps.map(\.name), ["alpha", "zed"])
    }
}

final class SystemHealthMonitorTests: XCTestCase {
    private func monitor(
        levels: [MacHealthLevel] = [.normal], diskReads: Counter = Counter(),
        heaviest: MacHeaviestApps? = nil
    ) -> SystemHealthMonitor {
        let sweep = Counter()
        return SystemHealthMonitor(
            read: { now in
                let index = min(sweep.next() - 1, levels.count - 1)
                return MacHealthReading(
                    observedAt: now, pressure: levels[index], freeMemoryPercent: 40, swap: nil,
                    physicalMemory: 10, loadAverage: nil, activeCores: 2, uptime: 1)
            },
            diskFree: {
                _ = diskReads.next()
                return 1_000
            },
            heaviest: { heaviest })
    }

    func testNoSampleYetIsNoReading() {
        XCTAssertNil(monitor().currentReading())
    }

    func testASampleCarriesTheDiskAndTheHeaviestApps() async {
        let apps = MacHeaviestApps(
            observedAt: Date(), apps: [MacAppFootprint(name: "Mail", path: "/M.app", footprint: 3)])
        let monitor = monitor(heaviest: apps)
        await monitor.sampleOnce {}
        let reading = monitor.currentReading()
        XCTAssertEqual(reading?.diskFree, 1_000)
        XCTAssertNotNil(reading?.diskObservedAt)
        XCTAssertEqual(reading?.heaviest, apps)
        XCTAssertEqual(reading?.level, .normal)
    }

    /// The disk read is the dear one, so two samples inside its interval read
    /// it once, and a pressure event reads it again.
    func testTheDiskIsReadOncePerIntervalAndOnAPressureEvent() async {
        let reads = Counter()
        let monitor = monitor(diskReads: reads)
        await monitor.sampleOnce {}
        await monitor.sampleOnce {}
        XCTAssertEqual(reads.count, 1)
        await monitor.sampleOnce(forcingFrame: true) {}
        XCTAssertEqual(reads.count, 2)
    }

    func testAQuietMacCostsNoFrameAfterTheFirst() async {
        let monitor = monitor()
        let frames = Counter()
        await monitor.sampleOnce { _ = frames.next() }
        await monitor.sampleOnce { _ = frames.next() }
        XCTAssertEqual(frames.count, 1)
    }

    func testALevelChangeIsWorthAFrame() async {
        let monitor = monitor(levels: [.normal, .warn])
        let frames = Counter()
        await monitor.sampleOnce { _ = frames.next() }
        await monitor.sampleOnce { _ = frames.next() }
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(monitor.currentReading()?.pressure, .warn)
    }

    func testAPressureEventAlwaysEarnsAFrame() async {
        let monitor = monitor()
        let frames = Counter()
        await monitor.sampleOnce { _ = frames.next() }
        await monitor.sampleOnce(forcingFrame: true) { _ = frames.next() }
        XCTAssertEqual(frames.count, 2)
    }

    func testStoppingDropsTheReading() async {
        let monitor = monitor()
        await monitor.sampleOnce {}
        await monitor.stop()
        XCTAssertNil(monitor.currentReading())
    }
}

/// The apps ride the agent sweep, and only while the Mac module asks for them.
final class AgentSweepAppsTests: XCTestCase {
    private func process(_ pid: pid_t, parent: pid_t, _ path: String)
        -> AgentProcessReader.KernelProcess
    {
        AgentProcessReader.KernelProcess(
            pid: pid, parent: parent, executablePath: path, startedAt: Date())
    }

    /// An agent and everything it started are the Sessions tab's, so none of
    /// them is counted towards an app.
    func testTheAgentsAndTheirTreesAreLeftOut() {
        let processes = [
            process(10, parent: 1, "/usr/local/bin/claude"),
            process(11, parent: 10, "/opt/homebrew/bin/node"),
            process(12, parent: 11, "/Applications/Xcode.app/Contents/MacOS/Xcode"),
            process(20, parent: 1, "/Applications/Xcode.app/Contents/MacOS/Xcode"),
            process(21, parent: 20, "/Applications/Xcode.app/Contents/Helpers/x.app/Contents/MacOS/x"),
            process(30, parent: 1, "/opt/homebrew/bin/node"),
        ]
        var childrenOf: [pid_t: [pid_t]] = [:]
        for process in processes { childrenOf[process.parent, default: []].append(process.pid) }
        let apps = AgentProcessReader.heaviestApps(
            processes: processes, agents: [10], childrenOf: childrenOf
        ) { UInt64($0) }
        XCTAssertEqual(apps.map(\.name), ["Xcode", "node"])
        XCTAssertEqual(apps.map(\.footprint), [41, 30])
    }

    func testTheMonitorPublishesAppsOnlyWhileAsked() async {
        let apps = MacHeaviestApps(observedAt: Date(), apps: [])
        let monitor = AgentProcessMonitor(sweep: { now, measuring in
            AgentProcessSweep(
                agents: AgentProcessReading(observedAt: now, agents: []),
                apps: measuring ? apps : nil)
        })
        await monitor.sampleOnce {}
        XCTAssertNil(monitor.currentApps())
        await monitor.setMeasuresApps(true)
        await monitor.sampleOnce {}
        XCTAssertEqual(monitor.currentApps(), apps)
        await monitor.setMeasuresApps(false)
        XCTAssertNil(monitor.currentApps(), "switching off left the last apps published")
    }
}

final class MacHealthConfigTests: XCTestCase {
    private func load(_ json: [String: Any]) throws -> ServerConfig {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-mac-health-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return try ServerConfig.load(from: url)
    }

    /// A `server.json` written before the key existed reads as on.
    func testAConfigWithoutTheKeyReadsAsOn() throws {
        let data = try JSONEncoder().encode(ServerConfig.defaults)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "macHealth")
        object["statusChecks"] = false
        let config = try load(object)
        XCTAssertTrue(config.macHealth)
        XCTAssertFalse(config.statusChecks, "the rest of the file was not read")
    }

    /// An explicit off survives a file the decoder can only partly read, where
    /// falling back to the default would switch the module back on.
    func testAnExplicitOffSurvivesAPartlyReadableFile() throws {
        XCTAssertFalse(try load(["macHealth": false, "keepAwake": 7]).macHealth)
    }
}

/// A counter a `@Sendable` closure can advance.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
