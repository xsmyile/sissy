import XCTest

@testable import Sissy

final class PreferencesTests: XCTestCase {
    func testDefaultsAreSane() {
        let prefs = Preferences()

        XCTAssertTrue(prefs.sissyMotion)
        XCTAssertFalse(prefs.retiredServerAgent)
        XCTAssertEqual(prefs.limitsReading, .used)
    }

    /// The gauges have always read from the spent end. A file written before
    /// the choice existed has to keep them there — the other end is a
    /// preference, not an upgrade.
    func testAFileWithoutTheLimitsKeyKeepsTheGaugesOnWhatIsSpent() throws {
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))

        XCTAssertEqual(prefs.limitsReading, .used)
    }

    func testRoundTripJSON() throws {
        let original = Preferences(
            sissyMotion: false, retiredServerAgent: true, limitsReading: .left)
        let data = try JSONEncoder().encode(original)

        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: data), original)
    }

    /// A 0.1.8 `preferences.json` spells the motion switch `mascotMotion`.
    /// Losing that key would turn motion back on for everyone who had
    /// switched it off, which is the one direction the default cannot cover.
    func testMotionOffSurvivesTheLegacyKeyName() throws {
        let legacy = Data(#"{"mascotMotion":false}"#.utf8)

        XCTAssertFalse(try JSONDecoder().decode(Preferences.self, from: legacy).sissyMotion)
    }

    func testTheCurrentKeyWinsOverTheLegacyOne() throws {
        let both = Data(#"{"sissyMotion":true,"mascotMotion":false}"#.utf8)

        XCTAssertTrue(try JSONDecoder().decode(Preferences.self, from: both).sissyMotion)
    }

    func testMotionDefaultsOnWhenNeitherKeyIsPresent() throws {
        XCTAssertTrue(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)).sissyMotion)
    }

    /// A file written while Sissy still had a daemon carries keys this build
    /// has never heard of. It has to load, and the settings it still knows
    /// have to survive — a wipe here would silently re-enable motion and
    /// re-run the agent retirement.
    func testAPreferencesFileFromTheTwoProcessDaysStillLoads() throws {
        let legacy = Data(
            #"{"primaryMetric":"tokens","serverHost":"127.0.0.1","serverPort":5155,"authToken":"x","claudeLimits":true,"sissyMotion":false,"retiredServerAgent":true}"#
                .utf8
        )
        let prefs = try JSONDecoder().decode(Preferences.self, from: legacy)

        XCTAssertFalse(prefs.sissyMotion)
        XCTAssertTrue(prefs.retiredServerAgent)
    }

    func testAnUnreadableFileFallsBackToTheDefaults() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-prefs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not json".utf8).write(to: dir.appendingPathComponent(Preferences.fileName))

        XCTAssertEqual(Preferences.load(from: dir), Preferences())
    }

    func testSaveThenLoadRoundTripsThroughTheDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-prefs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefs = Preferences(
            sissyMotion: false, retiredServerAgent: true, usagePeriod: .preset(.thirtyDays))

        prefs.save(to: dir)

        XCTAssertEqual(Preferences.load(from: dir), prefs)
    }

    /// A file written before the period existed, and one naming a window this
    /// build does not know, both land on today rather than refusing to load —
    /// the decoder's whole contract.
    func testAFileWithNoPeriodOrAnUnknownOneReadsAsToday() throws {
        for json in ["{\"sissyMotion\":false}", "{\"usagePeriod\":\"fortnight\"}"] {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("sissy-prefs-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try Data(json.utf8).write(to: dir.appendingPathComponent(Preferences.fileName))

            XCTAssertEqual(Preferences.load(from: dir).usagePeriod, .preset(.today), json)
        }
    }
    /// A file written before a window could be picked stored the preset as a
    /// bare string, and it reads back as that same preset.
    func testAnOldPresetDecodesUnchanged() throws {
        let decoded = try JSONDecoder().decode(
            Preferences.self, from: Data("{\"usagePeriod\":\"7d\"}".utf8))

        XCTAssertEqual(decoded.usagePeriod, .preset(.sevenDays))
        XCTAssertNil(decoded.usagePeriodPickedAt)
        XCTAssertEqual(decoded.period(), .preset(.sevenDays))
    }

    /// A picked window survives the round trip with the instant it was picked.
    func testAPickedWindowRoundTrips() throws {
        let now = Date()
        let span = try XCTUnwrap(
            UsageDaySpan(from: now.addingTimeInterval(-3 * 86_400), to: now, now: now))
        let prefs = Preferences(usagePeriod: .days(span), usagePeriodPickedAt: now)

        let decoded = try JSONDecoder().decode(
            Preferences.self, from: JSONEncoder().encode(prefs))

        XCTAssertEqual(decoded.usagePeriod, .days(span))
        XCTAssertEqual(
            try XCTUnwrap(decoded.usagePeriodPickedAt).timeIntervalSince1970,
            now.timeIntervalSince1970, accuracy: 0.001)
    }

    /// A picked window is the panel's period for a day after it was picked and
    /// today from then on; one with no instant beside it cannot be aged and
    /// reads as today.
    func testAPickedWindowFallsBackToTodayAfterADay() throws {
        let pickedAt = Date()
        let span = try XCTUnwrap(
            UsageDaySpan(
                from: pickedAt.addingTimeInterval(-2 * 86_400),
                to: pickedAt.addingTimeInterval(-86_400), now: pickedAt))
        let prefs = Preferences(usagePeriod: .days(span), usagePeriodPickedAt: pickedAt)
        let unstamped = Preferences(usagePeriod: .days(span))

        XCTAssertEqual(prefs.period(now: pickedAt.addingTimeInterval(23 * 3_600)), .days(span))
        XCTAssertEqual(
            prefs.period(now: pickedAt.addingTimeInterval(Preferences.pickedPeriodLifetime)),
            .preset(.today))
        XCTAssertEqual(unstamped.period(now: pickedAt), .preset(.today))
    }

    /// An age that cannot be read retires the window: a `pickedAt` after now
    /// is a clock set back since the pick, and keeping the window until the
    /// clock catches up could keep it for far longer than a day.
    func testAPickedWindowStampedInTheFutureReadsAsToday() throws {
        let now = Date()
        let span = try XCTUnwrap(
            UsageDaySpan(
                from: now.addingTimeInterval(-2 * 86_400), to: now.addingTimeInterval(-86_400),
                now: now))
        let prefs = Preferences(usagePeriod: .days(span), usagePeriodPickedAt: now.addingTimeInterval(60))

        XCTAssertEqual(prefs.period(now: now), .preset(.today))
        XCTAssertNil(prefs.pickedPeriodExpiry(now: now))
    }

    /// A stored window whose last day has come to be after today, which a
    /// flight west makes of one that ended today, reads as today rather than
    /// naming a day that has not happened here.
    func testAPickedWindowEndingAfterTodayReadsAsToday() throws {
        let now = Date()
        let tomorrow = now.addingTimeInterval(86_400)
        let ahead = try XCTUnwrap(UsageDaySpan(from: now, to: tomorrow, now: tomorrow))
        let endingToday = try XCTUnwrap(
            UsageDaySpan(from: now.addingTimeInterval(-86_400), to: now, now: now))

        XCTAssertEqual(
            Preferences(usagePeriod: .days(ahead), usagePeriodPickedAt: now).period(now: now),
            .preset(.today))
        XCTAssertEqual(
            Preferences(usagePeriod: .days(endingToday), usagePeriodPickedAt: now).period(now: now),
            .days(endingToday))
    }

    /// The expiry is the instant the pick turns a day old, and nothing for a
    /// preset.
    func testAPickedWindowExpiresADayAfterItWasPicked() throws {
        let pickedAt = Date()
        let span = try XCTUnwrap(
            UsageDaySpan(
                from: pickedAt.addingTimeInterval(-86_400), to: pickedAt.addingTimeInterval(-86_400),
                now: pickedAt))
        let prefs = Preferences(usagePeriod: .days(span), usagePeriodPickedAt: pickedAt)

        XCTAssertEqual(
            prefs.pickedPeriodExpiry(now: pickedAt),
            pickedAt.addingTimeInterval(Preferences.pickedPeriodLifetime))
        XCTAssertNil(Preferences(usagePeriod: .preset(.sevenDays)).pickedPeriodExpiry(now: pickedAt))
    }
}
