import XCTest

@testable import Sissy

final class PreferencesTests: XCTestCase {
    func testDefaultsAreSane() {
        let prefs = Preferences()
        XCTAssertEqual(prefs.primaryMetric, .tokens)
        // Default port depends on whether the test host is a Debug (`.dev`)
        // or Release bundle — 8788 lets a dev install coexist with a
        // release daemon on 8787 without preferences hand-edit.
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
}
