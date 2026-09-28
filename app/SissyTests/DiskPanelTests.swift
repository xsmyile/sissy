import XCTest

@testable import Sissy

final class DiskPanelTests: XCTestCase {
    private static let gigabyte: Int64 = 1_000_000_000
    /// The Mac this was measured on, 24 GiB of RAM.
    private static let ram: UInt64 = 25_769_803_776

    private func reading(
        free: Int64? = 77 * gigabyte, total: Int64 = 494 * gigabyte, purgeable: Int64? = 9_400_000_000,
        volumes: [DiskVolume] = []
    ) -> DiskReading {
        DiskReading(
            observedAt: Date(timeIntervalSince1970: 1_790_000_000),
            home: free.map { DiskVolume(id: "H", name: "Macintosh HD", total: total, free: $0) },
            purgeable: purgeable, swap: MacSwapUsage(used: 1_200_000_000, total: 2_000_000_000),
            physicalMemory: Self.ram, volumes: volumes)
    }

    private func memory(_ pressure: MacHealthLevel) -> MacHealthReading {
        MacHealthReading(
            observedAt: Date(timeIntervalSince1970: 1_790_000_000), pressure: pressure,
            freeMemoryPercent: 75, swap: nil, physicalMemory: Self.ram, loadAverage: nil,
            activeCores: 12, uptime: 60)
    }

    private func snapshot(mac: MacHealthReading? = nil, disk: DiskReading?) -> UsagePanelSnapshot {
        UsagePanelSnapshot.make(
            frame: FrameData(
                tokens: 0, cost: 0, burn: nil, providers: [], keepAwake: .off, mac: mac, disk: disk))
    }

    // MARK: Formatters

    func testTheCaptionNamesWhatTheFreeSpaceIsOutOf() {
        XCTAssertEqual(
            UsageFormat.diskVolume(total: 494 * Self.gigabyte, name: "Macintosh HD"),
            "of 494 GB · Macintosh HD")
    }

    /// In the base-ten bytes the free space above it is read in, so a volume
    /// graded warn at 51 GB free is not under a legend saying 48.
    func testTheLegendIsInTheFreeSpacesOwnBytes() {
        XCTAssertEqual(
            UsageFormat.diskThresholds(physicalMemory: Self.ram),
            "warn under 52 GB · critical under 26 GB")
    }

    func testAVolumeReadsFreeOfTotal() {
        let volume = DiskVolume(id: "B", name: "Backup", total: 2_000_398_934_016, free: 812 * Self.gigabyte)
        XCTAssertEqual(UsageFormat.diskVolumeFree(volume), "812 GB free of 2.0 TB")
    }

    func testTheCaptionSaysWhenTheDiskWasRead() {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(
            UsageFormat.diskReading(observedAt: at, now: at.addingTimeInterval(12)), "read 12s ago")
    }

    // MARK: Snapshot

    func testTheBlockWordsEveryFigure() throws {
        let disk = try XCTUnwrap(snapshot(disk: reading()).disk)

        XCTAssertEqual(disk.free, .init(text: "77 GB free", level: .normal))
        XCTAssertEqual(disk.volume, "of 494 GB · Macintosh HD")
        XCTAssertEqual(disk.thresholds, "warn under 52 GB · critical under 26 GB")
        XCTAssertEqual(disk.purgeable, "9.4 GB")
        XCTAssertEqual(disk.swap, "1.2 GB")
        XCTAssertEqual(disk.used, 417.0 / 494.0, accuracy: 1e-9)
        XCTAssertEqual(disk.volumes, [])
    }

    /// Each mark sits where the free space drops under its multiple, so a
    /// fill past it is a disk at that step.
    func testTheMarksSitWhereEachStepBegins() throws {
        let disk = try XCTUnwrap(snapshot(disk: reading()).disk)
        let total = Double(494 * Self.gigabyte)

        XCTAssertEqual(try XCTUnwrap(disk.warnMark), 1 - Double(2 * Self.ram) / total, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(disk.criticalMark), 1 - Double(Self.ram) / total, accuracy: 1e-9)
        XCTAssertLessThan(try XCTUnwrap(disk.warnMark), try XCTUnwrap(disk.criticalMark))
    }

    /// A volume smaller than the multiple is past the mark from empty, which
    /// is a mark at the bar's start rather than off its edge.
    func testAMarkPastASmallVolumeSitsAtTheStart() throws {
        let disk = try XCTUnwrap(
            snapshot(disk: reading(free: 10 * Self.gigabyte, total: 20 * Self.gigabyte)).disk)

        XCTAssertEqual(disk.warnMark, 0)
        XCTAssertEqual(disk.criticalMark, 0)
        XCTAssertEqual(disk.free.level, .critical)
    }

    func testAnUnreadHomeVolumeIsTheDash() throws {
        let disk = try XCTUnwrap(snapshot(disk: reading(free: nil, purgeable: nil)).disk)

        XCTAssertEqual(disk.free, .init(text: UsageFormat.macLevel(nil), level: nil))
        XCTAssertNil(disk.volume)
        XCTAssertNil(disk.warnMark)
        XCTAssertEqual(disk.used, 0)
        XCTAssertEqual(disk.purgeable, "—")
    }

    func testEveryOtherVolumeIsARow() throws {
        let backup = DiskVolume(
            id: "B", name: "Backup", total: 2_000 * Self.gigabyte, free: 500 * Self.gigabyte)
        let disk = try XCTUnwrap(snapshot(disk: reading(volumes: [backup])).disk)

        XCTAssertEqual(
            disk.volumes, [.init(id: "B", name: "Backup", free: "500 GB free of 2.0 TB", used: 0.75)])
    }

    // MARK: Tabs

    func testAReadingGivesTheDiskATabAfterTheMac() {
        XCTAssertEqual(
            PanelTab.visible(in: snapshot(mac: memory(.normal), disk: reading())),
            [.usage, .sessions, .mac, .disk])
    }

    /// Off, or not read yet: no reading and no tab, and the Mac's tab does not
    /// depend on it.
    func testNoReadingDrawsNoDiskTab() {
        let snapshot = snapshot(mac: memory(.normal), disk: nil)

        XCTAssertNil(snapshot.disk)
        XCTAssertEqual(PanelTab.visible(in: snapshot), [.usage, .sessions, .mac])
    }

    func testTheDiskHasATabWithTheMacSwitchedOff() {
        XCTAssertEqual(PanelTab.visible(in: snapshot(disk: reading())), [.usage, .sessions, .disk])
    }

    func testTheDiskTabComesBeforeForgeInTheShortcuts() {
        XCTAssertEqual(PanelTab.disk.shortcut, "4")
        XCTAssertEqual(PanelTab.forge.shortcut, "5")
    }

    // MARK: Badges

    /// A low disk under a normal kernel badges the Disk tab and leaves the Mac
    /// tab's memory alone.
    func testALowDiskBadgesTheDiskTabAndNotTheMacs() {
        let snapshot = snapshot(mac: memory(.normal), disk: reading(free: 10 * Self.gigabyte))

        XCTAssertEqual(PanelTab.disk.badge(in: snapshot), .disk(.critical))
        XCTAssertNil(PanelTab.mac.badge(in: snapshot))
    }

    func testMemoryPressureBadgesTheMacTabAndNotTheDisks() {
        let snapshot = snapshot(mac: memory(.warn), disk: reading())

        XCTAssertEqual(PanelTab.mac.badge(in: snapshot), .memory(.warn))
        XCTAssertNil(PanelTab.disk.badge(in: snapshot))
    }

    func testADiskAtWarnBadgesAtWarn() {
        XCTAssertEqual(
            PanelTab.disk.badge(in: snapshot(disk: reading(free: 40 * Self.gigabyte))), .disk(.warn))
    }

    func testTheBadgeNamesWhatItIsAbout() {
        XCTAssertEqual(PanelTabBadge.disk(.warn).reason, "Disk at warn")
        XCTAssertEqual(PanelTabBadge.memory(.critical).reason, "Memory at critical")
    }
}
