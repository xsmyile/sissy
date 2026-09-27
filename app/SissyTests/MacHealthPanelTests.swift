import XCTest

@testable import Sissy

final class MacHealthPanelTests: XCTestCase {
    private let gigabyte: UInt64 = 1_000_000_000

    private func reading(
        pressure: MacHealthLevel? = .normal,
        freeMemoryPercent: Int? = 75,
        swap: MacSwapUsage? = MacSwapUsage(used: 0, total: 0),
        diskFree: Int64? = 77_000_000_000,
        heaviest: MacHeaviestApps? = nil
    ) -> MacHealthReading {
        MacHealthReading(
            observedAt: Date(timeIntervalSince1970: 1_790_000_000), pressure: pressure,
            freeMemoryPercent: freeMemoryPercent, swap: swap, physicalMemory: 24 * gigabyte,
            loadAverage: MacLoadAverage(one: 3.04, five: 2.5, fifteen: 2), activeCores: 12,
            uptime: 10 * 86_400 + 17 * 3_600 + 5 * 60, diskFree: diskFree,
            diskObservedAt: nil, heaviest: heaviest)
    }

    private func frame(mac: MacHealthReading?) -> FrameData {
        FrameData(tokens: 0, cost: 0, burn: nil, providers: [], keepAwake: .off, mac: mac)
    }

    // MARK: Formatters

    func testANormalMemoryReadsInTheKernelsWord() {
        XCTAssertEqual(UsageFormat.macMemory(.normal), "Memory normal")
        XCTAssertEqual(UsageFormat.macMemory(.critical), "Memory critical")
    }

    /// The kernel not answering is the dash, never a normal nobody measured.
    func testAnUnreadPressureIsTheDash() {
        XCTAssertEqual(UsageFormat.macLevel(nil), "—")
        XCTAssertEqual(UsageFormat.macMemory(nil), "Memory " + UsageFormat.macLevel(nil))
    }

    func testFreeMemoryIsTheKernelsShare() {
        XCTAssertEqual(UsageFormat.macFreeMemory(75), "75% free")
    }

    func testStorageReadsWholeGigabytesFromTen() {
        XCTAssertEqual(UsageFormat.storage(77_400_000_000), "77 GB")
        XCTAssertEqual(UsageFormat.storage(10_200_000_000), "10 GB")
    }

    func testStorageKeepsADecimalUnderTenGigabytes() {
        XCTAssertEqual(UsageFormat.storage(1_540_000_000), "1.5 GB")
        XCTAssertEqual(UsageFormat.storage(512_000_000), "512 MB")
    }

    /// No swap is none, not a small amount of kilobytes.
    func testNoSwapReadsAsZeroBytes() {
        XCTAssertEqual(UsageFormat.storage(0), "0 B")
    }

    func testSwapAndDiskShareOneLine() {
        XCTAssertEqual(
            UsageFormat.macStorage(
                swap: MacSwapUsage(used: 0, total: 0), diskFree: 77_000_000_000),
            "0 B swap · 77 GB free")
    }

    func testSwapAndDiskSayWhicheverWasRead() {
        XCTAssertEqual(UsageFormat.macStorage(swap: nil, diskFree: 23_000_000_000), "23 GB free")
        XCTAssertEqual(UsageFormat.macStorage(swap: nil, diskFree: nil), "—")
    }

    func testLoadIsReadAgainstTheCores() {
        XCTAssertEqual(
            UsageFormat.macLoad(MacLoadAverage(one: 3.04, five: 0, fifteen: 0), cores: 12),
            "3.0 on 12 cores")
        XCTAssertEqual(
            UsageFormat.macLoad(MacLoadAverage(one: 0.5, five: 0, fifteen: 0), cores: 1),
            "0.5 on 1 core")
        XCTAssertEqual(UsageFormat.macLoad(nil, cores: 12), "—")
    }

    func testUptimeReadsInDaysAndHours() {
        XCTAssertEqual(UsageFormat.uptime(10 * 86_400 + 17 * 3_600 + 5 * 60), "10d 17h")
        XCTAssertEqual(UsageFormat.uptime(2 * 3_600 + 3 * 60), "2h 3m")
    }

    func testTheHeaderSaysWhenTheFiguresWereSampled() {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(
            UsageFormat.macReading(observedAt: at, now: at.addingTimeInterval(12)),
            "sampled 12s ago")
    }

    // MARK: Snapshot

    func testTheBlockWordsEveryFigure() throws {
        let mac = try XCTUnwrap(UsagePanelSnapshot.make(frame: frame(mac: reading())).mac)

        XCTAssertEqual(mac.memory, .init(text: "Memory normal", level: .normal))
        XCTAssertEqual(mac.freeMemory, "75% free")
        XCTAssertEqual(mac.disk, .init(text: "77 GB free", level: .normal))
        XCTAssertEqual(mac.storage, .init(text: "0 B swap · 77 GB free", level: .normal))
        XCTAssertEqual(mac.load, "3.0 on 12 cores")
        XCTAssertEqual(mac.uptime, "10d 17h")
        XCTAssertEqual(mac.heaviest, [])
    }

    /// A disk under two multiples of RAM warns on its own figures, whatever
    /// the kernel is saying about memory.
    func testTheDiskWearsItsOwnLevel() throws {
        let mac = try XCTUnwrap(
            UsagePanelSnapshot.make(frame: frame(mac: reading(diskFree: 23_000_000_000))).mac)

        XCTAssertEqual(mac.memory.level, .normal)
        XCTAssertEqual(mac.disk?.level, .critical)
        XCTAssertEqual(mac.storage.level, .critical)
    }

    func testTheHeaviestAppsCarryTheirFootprint() throws {
        let apps = MacHeaviestApps(
            observedAt: Date(timeIntervalSince1970: 1_790_000_000),
            apps: [
                MacAppFootprint(
                    name: "Docker", path: "/Applications/Docker.app", footprint: 7_400_000_000)
            ])
        let mac = try XCTUnwrap(
            UsagePanelSnapshot.make(frame: frame(mac: reading(heaviest: apps))).mac)

        XCTAssertEqual(
            mac.heaviest,
            [.init(id: "/Applications/Docker.app", name: "Docker", footprint: "7.40 GB")])
    }

    // MARK: Overview

    func testTheMacLineFollowsTheProvidersWhenThereIsAReading() {
        let snapshot = UsagePanelSnapshot.make(frame: frame(mac: reading()))

        XCTAssertEqual(PanelModule.visible(in: snapshot), [.providers, .mac, .identities])
    }

    /// Switched off or not sampled yet, the frame carries no reading and the
    /// Overview draws no line rather than one saying so.
    func testNoReadingDrawsNoMacLine() {
        let snapshot = UsagePanelSnapshot.make(frame: frame(mac: nil))

        XCTAssertNil(snapshot.mac)
        XCTAssertFalse(PanelModule.visible(in: snapshot).contains(.mac))
    }
}
