import XCTest

@testable import Sissy

/// `server.json` is hand-editable, so an unclosed brace is an ordinary way for it
/// to stop parsing. The run carries on with the defaults, and nothing it does
/// may save those defaults over the user's file.
final class ServerConfigUnreadableTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-config-unreadable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var configURL: URL { tempDir.appendingPathComponent("server.json") }
    private static let brokenBytes = Data(#"{"agentHooks": true, "historyRetentionDays": 30"#.utf8)

    private func writeBrokenConfig() throws {
        try Self.brokenBytes.write(to: configURL)
    }

    func testAnUnreadableConfigRunsOnTheDefaults() throws {
        try writeBrokenConfig()

        let loaded = ServerConfig.loadForRun(from: configURL)

        XCTAssertEqual(loaded.config.agentHooks, ServerConfig.defaults.agentHooks)
        XCTAssertFalse(loaded.isWritable)
    }

    func testAnUnreadableConfigIsCopiedAside() throws {
        try writeBrokenConfig()

        let loaded = ServerConfig.loadForRun(from: configURL)

        let copy = try XCTUnwrap(loaded.setAside)
        XCTAssertEqual(try Data(contentsOf: copy), Self.brokenBytes)
        XCTAssertEqual(try Data(contentsOf: configURL), Self.brokenBytes)
    }

    func testAnAbsentConfigIsWritable() {
        let loaded = ServerConfig.loadForRun(from: configURL)

        XCTAssertTrue(loaded.isWritable)
        XCTAssertNil(loaded.setAside)
    }

    func testAReadableConfigIsWritable() throws {
        var config = ServerConfig.defaults
        config.historyRetentionDays = 30
        try ServerConfig.save(config, to: configURL)

        let loaded = ServerConfig.loadForRun(from: configURL)

        XCTAssertTrue(loaded.isWritable)
        XCTAssertEqual(loaded.config.historyRetentionDays, 30)
    }

    func testASettingChangedThisRunDoesNotOverwriteTheFile() async throws {
        try writeBrokenConfig()
        let engine = makeEngine(isWritable: false)

        await engine.setAgentHooks(enabled: true)

        XCTAssertEqual(try Data(contentsOf: configURL), Self.brokenBytes)
    }

    /// A provider switch is applied by a new engine that reads the file
    /// again, so a toggle that cannot be saved cannot be applied either, and
    /// says so rather than reporting a switch that the rebuild would undo.
    func testAProviderToggleIsRefusedWhenItCannotBeSaved() async throws {
        try writeBrokenConfig()
        let engine = makeEngine(isWritable: false)

        let saved = await engine.setProvider(id: ProviderID.codex, enabled: false)

        XCTAssertFalse(saved)
    }

    private func makeEngine(isWritable: Bool) -> UsageEngine {
        var config = ServerConfig.defaults
        config.claudeDataDir = tempDir.appendingPathComponent("claude").path
        config.codexDataDir = tempDir.appendingPathComponent("codex").path
        config.remotePricing = false
        config.statusChecks = false
        return UsageEngine(
            config: config,
            configURL: configURL,
            configIsWritable: isWritable,
            limitsProbe: ClaudeLimitsProbe { _ in .absent },
            claudeAccounts: .inert())
    }
}
