import XCTest

@testable import Sissy

/// The day key names the day in the zone the calendar is in when it is asked,
/// not the zone the process launched in: a Mac carried across an ocean keeps
/// Sissy running, and the tail's buckets follow `Calendar.current`.
final class DayKeyFormatterTests: XCTestCase {
    private static let rome = TimeZone(identifier: "Europe/Rome")!
    private static let newYork = TimeZone(identifier: "America/New_York")!
    /// 23:30 UTC, which is already the next day in Rome and still this one in
    /// New York.
    private static let lateEvening = Date(timeIntervalSince1970: 1_790_206_200)
    private static let romeKey = "2026-09-24"
    private static let newYorkKey = "2026-09-23"

    func testAKeyFollowsTheZoneInForceWhenItIsAsked() {
        let zone = ZoneBox(Self.rome)
        let formatter = DayKeyFormatter { zone.value }
        let inRome = formatter.string(from: Self.lateEvening)

        zone.value = Self.newYork
        let inNewYork = formatter.string(from: Self.lateEvening)

        XCTAssertEqual(inRome, "2026-09-24")
        XCTAssertEqual(inNewYork, "2026-09-23")
    }

    func testAKeyParsesToMidnightInTheZoneInForce() throws {
        let zone = ZoneBox(Self.rome)
        let formatter = DayKeyFormatter { zone.value }
        _ = formatter.string(from: Self.lateEvening)

        zone.value = Self.newYork
        let parsed = try XCTUnwrap(formatter.date(from: "2026-09-23"))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.newYork
        XCTAssertEqual(parsed, calendar.startOfDay(for: Self.lateEvening))
    }

    func testTheSharedFormatterAgreesWithTheCalendarTheTailBucketsBy() throws {
        let now = Date()
        let key = UsageReaderShared.dayFormatter.string(from: now)

        let parsed = try XCTUnwrap(UsageReaderShared.dayFormatter.date(from: key))

        XCTAssertEqual(parsed, Calendar.current.startOfDay(for: now))
    }

    /// The reaction itself is Foundation's to vouch for: the system zone
    /// cannot be moved from a test, so what is pinned here is that the
    /// notification reaches the reset at all.
    func testTheSystemZoneNotificationResetsTheCachedZone() {
        let center = NotificationCenter()
        let resets = ResetCounter()
        let observer = DayKeyFormatter.observeSystemZone(on: center) { resets.increment() }
        defer { center.removeObserver(observer) }

        center.post(name: .NSSystemTimeZoneDidChange, object: nil)

        XCTAssertEqual(resets.value, 1)
    }

    func testTheSharedFormatterFollowsTheCalendarAfterAZoneChange() {
        let original = NSTimeZone.default
        defer {
            NSTimeZone.default = original
            NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        }
        let before = UsageReaderShared.dayFormatter.string(from: Self.lateEvening)
        let (target, expected) =
            before == Self.romeKey ? (Self.newYork, Self.newYorkKey) : (Self.rome, Self.romeKey)

        NSTimeZone.default = target
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)

        XCTAssertEqual(Calendar.current.timeZone, target)
        XCTAssertEqual(UsageReaderShared.dayFormatter.string(from: Self.lateEvening), expected)
    }
}

private final class ResetCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }

    var value: Int { lock.withLock { count } }
}

private final class ZoneBox: @unchecked Sendable {
    private let lock = NSLock()
    private var zone: TimeZone

    init(_ zone: TimeZone) { self.zone = zone }

    var value: TimeZone {
        get { lock.withLock { zone } }
        set { lock.withLock { zone = newValue } }
    }
}
