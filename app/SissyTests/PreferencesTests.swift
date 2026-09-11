import XCTest

@testable import Sissy

final class PreferencesTests: XCTestCase {
    func testDefaultsAreSane() {
        let prefs = Preferences()

        XCTAssertTrue(prefs.sissyMotion)
        XCTAssertFalse(prefs.retiredServerAgent)
    }

    func testRoundTripJSON() throws {
        let original = Preferences(sissyMotion: false, retiredServerAgent: true)
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
        let prefs = Preferences(sissyMotion: false, retiredServerAgent: true)

        prefs.save(to: dir)

        XCTAssertEqual(Preferences.load(from: dir), prefs)
    }
}
