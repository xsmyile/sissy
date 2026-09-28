import XCTest

@testable import Sissy

/// Which volumes the Disk tab lists, and what each one reads as.
final class DiskVolumesTests: XCTestCase {
    private func attributes(
        path: String = "/Volumes/Backup", uuid: String? = "B", name: String? = "Backup",
        isLocal: Bool = true, isBrowsable: Bool = true, total: Int? = 2_000, available: Int? = 800
    ) -> DiskVolumeAttributes {
        DiskVolumeAttributes(
            path: path, uuid: uuid, name: name, isLocal: isLocal, isBrowsable: isBrowsable,
            total: total, available: available)
    }

    /// Only a local mount Finder would show is asked anything: a network one
    /// can block the call that asks.
    func testOnlyALocalBrowsableMountIsACandidate() {
        XCTAssertTrue(DiskVolumes.isCandidate(DiskMount(path: "/", isLocal: true, isBrowsable: true)))
        XCTAssertFalse(
            DiskVolumes.isCandidate(DiskMount(path: "/Volumes/nas", isLocal: false, isBrowsable: true)))
        XCTAssertFalse(
            DiskVolumes.isCandidate(
                DiskMount(path: "/System/Volumes/VM", isLocal: true, isBrowsable: false)))
    }

    func testALocalBrowsableVolumeIsListed() {
        XCTAssertTrue(DiskVolumes.isListed(attributes(), homeID: "H"))
    }

    func testANetworkVolumeIsNotListed() {
        XCTAssertFalse(DiskVolumes.isListed(attributes(isLocal: false), homeID: "H"))
    }

    func testAVolumeFinderWouldNotShowIsNotListed() {
        XCTAssertFalse(DiskVolumes.isListed(attributes(isBrowsable: false), homeID: "H"))
    }

    /// `/` and the home directory answer the same UUID through the firmlink,
    /// measured 2026-09-28, and the headline already is that volume.
    // MARK: Home mount

    private func mount(_ path: String, local: Bool = true) -> DiskMount {
        DiskMount(path: path, isLocal: local, isBrowsable: true)
    }

    func testTheHomeLivesOnTheLongestMountHoldingIt() {
        let table = [mount("/"), mount("/System/Volumes/Data"), mount("/Users/me", local: false)]
        XCTAssertEqual(DiskVolumes.mount(of: "/Users/me/Documents", in: table)?.path, "/Users/me")
        XCTAssertEqual(DiskVolumes.mount(of: "/Users/you", in: table)?.path, "/")
    }

    func testAMountPointHoldsOnlyWholeComponents() {
        let table = [mount("/"), mount("/Users", local: false)]
        XCTAssertEqual(DiskVolumes.mount(of: "/Users2/me", in: table)?.path, "/")
    }

    func testALocalHomeIsReadable() {
        XCTAssertTrue(DiskVolumes.isHomeReadable("/Users/me", in: [mount("/")]))
    }

    func testAHomeOnANetworkMountIsNotReadable() {
        let table = [mount("/"), mount("/Network/Servers/files/me", local: false)]
        XCTAssertFalse(DiskVolumes.isHomeReadable("/Network/Servers/files/me", in: table))
    }

    func testAHomeTheTableDoesNotPlaceIsNotReadable() {
        XCTAssertFalse(DiskVolumes.isHomeReadable("/Users/me", in: []))
    }

    /// The whole read against a table whose only mount is remote asks no
    /// volume anything: no home reading, no volumes, and nothing blocked.
    func testAReadWithANetworkHomeReadsNoHome() {
        let reading = DiskReader.read(mounts: [mount("/", local: false)], homePath: "/Users/me")
        XCTAssertNil(reading.home)
        XCTAssertNil(reading.purgeable)
        XCTAssertEqual(reading.volumes, [])
    }

    func testTheHomeVolumeIsLeftToTheHeadline() {
        XCTAssertFalse(DiskVolumes.isListed(attributes(path: "/", uuid: "H"), homeID: "H"))
    }

    /// A volume with no UUID is told apart by its mount path.
    func testAVolumeWithNoUUIDIsKeyedByItsPath() {
        XCTAssertEqual(attributes(uuid: nil).id, "/Volumes/Backup")
    }

    func testTheImportantUsageFigureIsPreferred() {
        let volume = DiskVolumes.volume(attributes(), importantFree: 900)
        XCTAssertEqual(volume, DiskVolume(id: "B", name: "Backup", total: 2_000, free: 900))
        XCTAssertEqual(volume?.used, 1_100)
    }

    /// A volume that answers no important-usage figure, which is what a
    /// non-APFS drive does, falls back to the plain available one.
    func testAVolumeWithoutTheImportantFigureFallsBackToAvailable() {
        XCTAssertEqual(DiskVolumes.volume(attributes(), importantFree: nil)?.free, 800)
    }

    func testAVolumeWithNoCapacityIsNotAVolume() {
        XCTAssertNil(DiskVolumes.volume(attributes(total: nil), importantFree: 1))
        XCTAssertNil(DiskVolumes.volume(attributes(total: 0), importantFree: 1))
        XCTAssertNil(DiskVolumes.volume(attributes(available: nil), importantFree: nil))
    }

    func testPurgeableIsTheImportantFigureLessTheAvailableOne() {
        XCTAssertEqual(DiskVolumes.purgeable(important: 51_041, available: 41_571), 9_470)
        XCTAssertEqual(DiskVolumes.purgeable(important: 10, available: 20), 0)
    }

    /// Without the important-usage figure nothing was measured, which is not
    /// a volume holding no purgeable space.
    func testPurgeableIsUnreadWithoutBothFigures() {
        XCTAssertNil(DiskVolumes.purgeable(important: nil, available: 41_571))
        XCTAssertNil(DiskVolumes.purgeable(important: 51_041, available: nil))
    }

    func testAnUnnamedVolumeIsNamedByItsMountPoint() {
        XCTAssertEqual(DiskVolumes.volume(attributes(name: nil), importantFree: 1)?.name, "Backup")
    }

    func testVolumesAreOrderedByName() {
        let volumes = [
            DiskVolume(id: "1", name: "Zeta", total: 1, free: 1),
            DiskVolume(id: "2", name: "alpha", total: 1, free: 1),
            DiskVolume(id: "3", name: "Backup 10", total: 1, free: 1),
            DiskVolume(id: "4", name: "Backup 9", total: 1, free: 1),
        ]
        XCTAssertEqual(
            DiskVolumes.ordered(volumes).map(\.name), ["alpha", "Backup 9", "Backup 10", "Zeta"])
    }
}

final class DiskReadingTests: XCTestCase {
    private func reading(free: Int64?, physicalMemory: UInt64 = 100) -> DiskReading {
        DiskReading(
            observedAt: Date(),
            home: free.map { DiskVolume(id: "H", name: "Macintosh HD", total: 1_000, free: $0) },
            purgeable: nil, physicalMemory: physicalMemory, volumes: [])
    }

    func testTheHomeVolumeIsGradedInMultiplesOfRAM() {
        XCTAssertEqual(reading(free: 50).level, .critical)
        XCTAssertEqual(reading(free: 150).level, .warn)
        XCTAssertEqual(reading(free: 200).level, .normal)
    }

    /// No home volume read is not a healthy disk.
    func testAnUnreadHomeVolumeIsNoLevel() {
        XCTAssertNil(reading(free: nil).level)
    }

    /// The real disks, asserted on their invariants rather than on what this
    /// Mac happens to hold while the suite runs.
    func testTheRealReadingIsInternallyConsistent() throws {
        let reading = DiskReader.read()
        let home = try XCTUnwrap(reading.home)
        XCTAssertGreaterThan(home.total, 0)
        XCTAssertLessThanOrEqual(home.free, home.total)
        XCTAssertGreaterThanOrEqual(reading.purgeable ?? 0, 0)
        XCTAssertFalse(reading.volumes.contains { $0.id == home.id }, "the home volume was listed")
    }
}

/// The menu bar's dot: the worse of memory and disk, each only while its own
/// module put a reading on the frame.
final class FrameMacLevelTests: XCTestCase {
    private func frame(pressure: MacHealthLevel??, diskFree: Int64?) -> FrameData {
        let mac = pressure.map {
            MacHealthReading(
                observedAt: Date(), pressure: $0, freeMemoryPercent: nil, swap: nil,
                loadAverage: nil, activeCores: 1, uptime: 0)
        }
        let disk = diskFree.map {
            DiskReading(
                observedAt: Date(), home: DiskVolume(id: "H", name: "HD", total: 1_000, free: $0),
                purgeable: nil, physicalMemory: 100, volumes: [])
        }
        return FrameData(
            tokens: 0, cost: 0, burn: nil, providers: [], keepAwake: .off, mac: mac, disk: disk)
    }

    func testTheDotWearsTheWorseOfMemoryAndDisk() {
        XCTAssertEqual(frame(pressure: .normal, diskFree: 150).macLevel, .warn)
        XCTAssertEqual(frame(pressure: .critical, diskFree: 500).macLevel, .critical)
        XCTAssertEqual(frame(pressure: .normal, diskFree: 500).macLevel, .normal)
    }

    /// The disk switched off leaves the memory alone on the dot, and the
    /// memory switched off leaves the disk.
    func testEitherModuleOffLeavesTheOther() {
        XCTAssertEqual(frame(pressure: .warn, diskFree: nil).macLevel, .warn)
        XCTAssertEqual(frame(pressure: nil, diskFree: 50).macLevel, .critical)
        XCTAssertEqual(frame(pressure: .some(nil), diskFree: 50).macLevel, .critical)
    }

    func testNothingReadIsNoLevel() {
        XCTAssertNil(frame(pressure: nil, diskFree: nil).macLevel)
        XCTAssertNil(frame(pressure: .some(nil), diskFree: nil).macLevel)
    }
}

final class DiskMonitorTests: XCTestCase {
    private func monitor(reads: FrameCounter = FrameCounter()) -> DiskMonitor {
        DiskMonitor(read: { now in
            reads.bump()
            return DiskReading(
                observedAt: now, home: nil, purgeable: nil, physicalMemory: 1,
                volumes: [])
        })
    }

    func testNoReadYetIsNoReading() {
        XCTAssertNil(monitor().currentReading())
    }

    func testAReadPublishesAndEarnsAFrame() async {
        let reads = FrameCounter()
        let frames = FrameCounter()
        let monitor = monitor(reads: reads)
        await monitor.sampleOnce { frames.bump() }
        XCTAssertNotNil(monitor.currentReading())
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(frames.count, 1)
    }

    func testStoppingDropsTheReading() async {
        let monitor = monitor()
        await monitor.sampleOnce {}
        await monitor.stop()
        XCTAssertNil(monitor.currentReading())
    }

    /// A read stuck in the filesystem holds its dispatch thread and nothing
    /// else: `stop()` still completes, and the reading goes.
    func testStopCompletesWhileAReadIsStuck() async {
        let stuck = StuckRead()
        addTeardownBlock { stuck.release() }
        let monitor = DiskMonitor(read: stuck.read)
        await monitor.start {}
        await fulfillment(of: [stuck.entered], timeout: 2)

        let stopped = expectation(description: "stop() returned")
        Task {
            await monitor.stop()
            stopped.fulfill()
        }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertNil(monitor.currentReading())
    }

    /// A read that comes back after `stop()` publishes nothing and costs no
    /// frame.
    func testAReadReturningAfterStopPublishesNothing() async throws {
        let stuck = StuckRead()
        let frames = FrameCounter()
        let monitor = DiskMonitor(read: stuck.read)
        await monitor.start { frames.bump() }
        await fulfillment(of: [stuck.entered], timeout: 2)
        await monitor.stop()

        stuck.release()
        await fulfillment(of: [stuck.returned], timeout: 2)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(monitor.currentReading())
        XCTAssertEqual(frames.count, 0)
    }

    /// A restart behind a stuck read waits on that read rather than parking a
    /// second thread behind the same volume, and is served when it returns.
    func testARestartBehindAStuckReadJoinsIt() async throws {
        let stuck = StuckRead()
        addTeardownBlock { stuck.release() }
        let monitor = DiskMonitor(read: stuck.read)
        await monitor.start {}
        await fulfillment(of: [stuck.entered], timeout: 2)
        await monitor.stop()
        let published = expectation(description: "the restart published")
        await monitor.start { published.fulfill() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(stuck.calls, 1)

        stuck.release()
        await fulfillment(of: [published], timeout: 2)
        XCTAssertNotNil(monitor.currentReading())
        await monitor.stop()
    }

    /// The dear read is never taken faster than `SystemHealthMonitor`'s disk
    /// read was, once a minute.
    func testTheReadIntervalIsAMinute() {
        XCTAssertEqual(DiskMonitor.readInterval, .seconds(60))
    }
}

final class DiskConfigTests: XCTestCase {
    private func load(_ json: [String: Any]) throws -> ServerConfig {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-disk-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return try ServerConfig.load(from: url)
    }

    /// A whole `server.json` written before the key existed, as an upgrade
    /// finds it.
    private func configBeforeTheKey(macHealth: Bool) throws -> [String: Any] {
        let data = try JSONEncoder().encode(ServerConfig.defaults)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "disk")
        object["macHealth"] = macHealth
        return object
    }

    /// Before the split, Mac health off also stopped the disk reads, so an
    /// upgrade must not start them.
    func testAConfigWithoutTheKeyTakesMacHealthOff() throws {
        let config = try load(configBeforeTheKey(macHealth: false))
        XCTAssertFalse(config.disk)
        XCTAssertFalse(config.macHealth, "the rest of the file was read")
    }

    func testAConfigWithoutTheKeyTakesMacHealthOn() throws {
        XCTAssertTrue(try load(configBeforeTheKey(macHealth: true)).disk)
    }

    func testAConfigNamingTheKeyKeepsItWhateverMacHealthSays() throws {
        var object = try configBeforeTheKey(macHealth: false)
        object["disk"] = true
        XCTAssertTrue(try load(object).disk)
    }

    func testAConfigWithNeitherKeyReadsTheDisks() throws {
        XCTAssertTrue(try load(["keepAwake": "off"]).disk)
    }

    func testAnExplicitOffSurvivesAPartlyReadableFile() throws {
        XCTAssertFalse(try load(["disk": false, "keepAwake": 7]).disk)
    }
}

/// A disk read that blocks its thread until released, the way a stuck
/// volume would.
private final class StuckRead: @unchecked Sendable {
    let entered = XCTestExpectation(description: "the read began")
    let returned = XCTestExpectation(description: "the read returned")
    private let gate = DispatchSemaphore(value: 0)
    private let counter = FrameCounter()

    var calls: Int { counter.count }

    var read: @Sendable (Date) -> DiskReading {
        { [self] now in
            counter.bump()
            entered.fulfill()
            gate.wait()
            returned.fulfill()
            return DiskReading(
                observedAt: now, home: nil, purgeable: nil, physicalMemory: 1, volumes: [])
        }
    }

    func release() { gate.signal() }
}

/// A counter a `@Sendable` closure can advance.
private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func bump() { lock.withLock { value += 1 } }
}
