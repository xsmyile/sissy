import XCTest

@testable import Sissy

final class MacHealthPanelTests: XCTestCase {
    private let gigabyte: UInt64 = 1_000_000_000

    private func reading(
        pressure: MacHealthLevel? = .normal,
        freeMemoryPercent: Int? = 75,
        swap: MacSwapUsage? = MacSwapUsage(used: 0, total: 0),
        heaviest: MacHeaviestApps? = nil
    ) -> MacHealthReading {
        MacHealthReading(
            observedAt: Date(timeIntervalSince1970: 1_790_000_000), pressure: pressure,
            freeMemoryPercent: freeMemoryPercent, swap: swap, physicalMemory: 24 * gigabyte,
            loadAverage: MacLoadAverage(one: 3.04, five: 2.5, fifteen: 2), activeCores: 12,
            uptime: 10 * 86_400 + 17 * 3_600 + 5 * 60, heaviest: heaviest)
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

    func testStorageReadsTerabytesToOneDecimal() {
        XCTAssertEqual(UsageFormat.storage(2_000_398_934_016), "2.0 TB")
        XCTAssertEqual(UsageFormat.storage(999_000_000_000), "999 GB")
    }

    func testSwapIsTheSwapInUseOrTheDash() {
        XCTAssertEqual(UsageFormat.macSwap(MacSwapUsage(used: 1_200_000_000, total: 2_000_000_000)), "1.2 GB")
        XCTAssertEqual(UsageFormat.macSwap(nil), "—")
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
        XCTAssertEqual(mac.swap, "0 B")
        XCTAssertEqual(mac.load, "3.0 on 12 cores")
        XCTAssertEqual(mac.uptime, "10d 17h")
        XCTAssertEqual(mac.heaviest, [])
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

    // MARK: Tabs

    func testAReadingGivesTheMacATabOfItsOwn() {
        let snapshot = UsagePanelSnapshot.make(frame: frame(mac: reading()))

        XCTAssertEqual(PanelTab.visible(in: snapshot), [.usage, .sessions, .mac])
    }

    /// Switched off or not sampled yet, the frame carries no reading and the
    /// panel draws no tab rather than one saying so.
    func testNoReadingDrawsNoMacTab() {
        let snapshot = UsagePanelSnapshot.make(frame: frame(mac: nil))

        XCTAssertNil(snapshot.mac)
        XCTAssertEqual(PanelTab.visible(in: snapshot), [.usage, .sessions])
    }

    /// The Mac has a tab, so Usage no longer carries a line for it; and with
    /// no provider in the frame there is no providers platter to draw either.
    func testUsageLeavesTheMacToItsTab() {
        let snapshot = UsagePanelSnapshot.make(frame: frame(mac: reading()))

        XCTAssertEqual(PanelModule.visible(in: snapshot), [.identities])
    }

    func testANormalMacPutsNothingOnItsTab() {
        let snapshot = UsagePanelSnapshot.make(frame: frame(mac: reading()))

        XCTAssertNil(PanelTab.mac.badge(in: snapshot))
    }

    func testPressureBadgesTheMacTabAtItsLevel() {
        let snapshot = UsagePanelSnapshot.make(frame: frame(mac: reading(pressure: .warn)))

        XCTAssertEqual(PanelTab.mac.badge(in: snapshot), .memory(.warn))
    }
}
