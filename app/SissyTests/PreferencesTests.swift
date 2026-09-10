import XCTest

@testable import Sissy

final class PreferencesTests: XCTestCase {
    func testDefaultsAreSane() {
        let prefs = Preferences()
        XCTAssertEqual(prefs.primaryMetric, .tokens)
        // Default port depends on whether the test host is a Debug (`.dev`)
        // or Release bundle — 5156 lets a dev install coexist with a
        // release daemon on 5155 without preferences hand-edit.
        XCTAssertEqual(prefs.serverPort, SissyPaths.defaultServerPort)
        XCTAssertFalse(prefs.claudeLimits)
    }

    func testGeneratedSecretShape() {
        let secret = Preferences.makeSecret()
        XCTAssertEqual(secret.count, 32)
        XCTAssertNotNil(secret.range(of: #"^[A-Za-z0-9]+$"#, options: .regularExpression))
    }

    func testRoundTripJSON() throws {
        let original = Preferences(
            primaryMetric: .burnRate,
            serverPort: 9999,
            authToken: "abcd1234",
            claudeLimits: true
        )
        let data = try JSONEncoder().encode(original)
        let round = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertEqual(round, original)
    }

    /// A 0.1.8 `preferences.json` spells the motion switch `mascotMotion`.
    /// Losing that key would turn motion back on for everyone who had
    /// switched it off, which is the one direction the default cannot cover.
    func testMotionOffSurvivesTheLegacyKeyName() throws {
        let legacy = Data(#"{"mascotMotion":false}"#.utf8)
        let prefs = try JSONDecoder().decode(Preferences.self, from: legacy)
        XCTAssertFalse(prefs.sissyMotion)
    }

    func testTheCurrentKeyWinsOverTheLegacyOne() throws {
        let both = Data(#"{"sissyMotion":true,"mascotMotion":false}"#.utf8)
        let prefs = try JSONDecoder().decode(Preferences.self, from: both)
        XCTAssertTrue(prefs.sissyMotion)
    }

    func testMotionDefaultsOnWhenNeitherKeyIsPresent() throws {
        let empty = Data("{}".utf8)
        let prefs = try JSONDecoder().decode(Preferences.self, from: empty)
        XCTAssertTrue(prefs.sissyMotion)
    }

    /// The literals are restated rather than read from a constant: the point
    /// of the test is that the exact pair v0.1.8 shipped is what moves.
    private var legacyDefaultPort: Int { SissyPaths.isDev ? 8788 : 8787 }

    func testTheLegacyDefaultPortMovesToTheCurrentDefault() {
        var prefs = Preferences(serverPort: legacyDefaultPort)
        XCTAssertTrue(prefs.migrateLegacyServerPort())
        XCTAssertEqual(prefs.serverPort, SissyPaths.defaultServerPort)
    }

    /// A user who picked a port by hand outranks the new default; moving them
    /// would break an install that was already working.
    func testAHandPickedPortSurvivesTheMigration() {
        var prefs = Preferences(serverPort: 9999)
        XCTAssertFalse(prefs.migrateLegacyServerPort())
        XCTAssertEqual(prefs.serverPort, 9999)
    }

    func testTheMigrationDoesNotFireTwice() {
        var prefs = Preferences(serverPort: legacyDefaultPort)
        XCTAssertTrue(prefs.migrateLegacyServerPort())
        XCTAssertFalse(prefs.migrateLegacyServerPort())
    }

    private func makeSupportDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-prefs-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func writeServerConfig(port: Int, to directory: URL) throws {
        let json = #"{"host":"127.0.0.1","port":\#(port),"authToken":""}"#
        try Data(json.utf8).write(to: directory.appendingPathComponent("server.json"))
    }

    /// Preferences that will not parse used to fall back to this build's
    /// default port, which is only the right guess while the default never
    /// moves. `server.json` is the port the daemon actually read at boot.
    func testUnreadablePreferencesAdoptTheDaemonsPort() throws {
        let dir = try makeSupportDir()
        try Data("not json".utf8).write(to: dir.appendingPathComponent(Preferences.fileName))
        try writeServerConfig(port: 9001, to: dir)

        XCTAssertEqual(Preferences.load(from: dir).serverPort, 9001)
    }

    func testAFreshInstallTakesTheCompiledDefault() throws {
        let dir = try makeSupportDir()

        XCTAssertEqual(Preferences.load(from: dir).serverPort, SissyPaths.defaultServerPort)
    }

    func testAReadablePreferencesFileOutranksTheServerConfig() throws {
        let dir = try makeSupportDir()
        Preferences(serverPort: 9002).save(to: dir)
        try writeServerConfig(port: 9001, to: dir)

        XCTAssertEqual(Preferences.load(from: dir).serverPort, 9002)
    }

    /// The two halves compose: an install whose preferences were lost adopts
    /// the legacy port from `server.json`, which is what lets the migration
    /// see it and move it. Without the adoption it would read as a fresh
    /// install already on the new default, and the daemon would be left
    /// behind on the old one.
    func testALegacyPortAdoptedFromTheServerConfigStillMigrates() throws {
        let dir = try makeSupportDir()
        try writeServerConfig(port: legacyDefaultPort, to: dir)

        var prefs = Preferences.load(from: dir)
        XCTAssertEqual(prefs.serverPort, legacyDefaultPort)
        XCTAssertTrue(prefs.migrateLegacyServerPort())
        XCTAssertEqual(prefs.serverPort, SissyPaths.defaultServerPort)
    }
}
