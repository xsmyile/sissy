import XCTest

@testable import Sissy

/// Where a CLI's files are, resolved from the one config home Sissy reads.
final class ProviderHomeTests: XCTestCase {
    func testTheHomeComesFromTheConfiguredLogTree() {
        var config = ServerConfig.defaults
        config.claudeDataDir = "/tmp/sissy-tests/elsewhere/projects"

        let home = config.providerHome(vendor: ProviderID.claudeCode)

        XCTAssertEqual(home.id, ProviderID.claudeCode)
        XCTAssertEqual(home.dataDir.path, "/tmp/sissy-tests/elsewhere/projects")
        XCTAssertEqual(home.home.path, "/tmp/sissy-tests/elsewhere")
    }

    /// The credential sits inside the home, which is what keeps it and the log
    /// tree from ever being read out of two different places.
    func testTheCredentialAndTheLogTreeShareAHome() {
        var config = ServerConfig.defaults
        config.claudeDataDir = "/tmp/sissy-tests/elsewhere/projects"

        let home = config.providerHome(vendor: ProviderID.claudeCode)

        XCTAssertEqual(
            home.claudeCredentialsURL.path, "/tmp/sissy-tests/elsewhere/.credentials.json")
    }

    /// The default home is the one asymmetry the CLI itself makes: its config
    /// home is `~/.claude` but the profile sits beside it at `$HOME`.
    func testTheDefaultHomeReadsItsProfileBesideItself() {
        let home = ProviderHome(
            id: ProviderID.claudeCode,
            home: AccountDefaults.claudeHome,
            dataDir: AccountDefaults.claudeHome.appendingPathComponent("projects")
        )

        XCTAssertEqual(
            home.claudeProfileURL.path,
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json").path)
    }
}
