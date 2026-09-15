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

/// The credential Claude Code keeps beside its config, which is the reading
/// the limits come from when there is one.
final class ClaudeFileCredentialsTests: XCTestCase {
    private func write(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-creds-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAnAccountThatHasNeverSignedInIsAbsent() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-missing-\(UUID().uuidString).json")

        guard case .absent = ClaudeFileCredentials.load(at: url) else {
            return XCTFail("a missing file is an account that has not signed in")
        }
    }

    func testTheTokenAndItsExpiryAreRead() throws {
        let url = try write(
            #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-x","expiresAt":1789487107266}}"#)

        guard case .found(let credentials) = ClaudeFileCredentials.load(at: url) else {
            return XCTFail("a well-formed file names a credential")
        }
        XCTAssertEqual(credentials.accessToken, "sk-ant-oat01-x")
        XCTAssertEqual(
            credentials.expiresAt?.timeIntervalSince1970 ?? 0, 1_789_487_107.266, accuracy: 0.01)
    }

    /// A payload this build cannot read is not a signed-out account: saying so
    /// would take a working row down over a shape that changed.
    func testAPayloadThatWillNotParseIsUnreadableRatherThanAbsent() throws {
        let url = try write(#"{"claudeAiOauth":{}}"#)

        guard case .unreadable = ClaudeFileCredentials.load(at: url) else {
            return XCTFail("a shape with no token is unreadable, not absent")
        }
    }
}
