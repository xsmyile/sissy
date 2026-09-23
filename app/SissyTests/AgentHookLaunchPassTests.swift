import XCTest

@testable import Sissy

/// The host's two decisions about the agent hooks, taken out of the pass so
/// they can be asked of files the test owns rather than the CLIs' own.
final class AgentHookLaunchPassTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-hook-pass-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var configURL: URL { root.appendingPathComponent("server.json") }

    private func loadUnreadableConfig() throws -> ServerConfig.LoadedForRun {
        try Data(#"{"agentHooks": true"#.utf8).write(to: configURL)
        return ServerConfig.loadForRun(from: configURL)
    }

    private func installedEntry() throws -> AgentHookInstaller {
        let bundledScript = root.appendingPathComponent("bundle/session-start.sh")
        let configuration = root.appendingPathComponent("home/.claude/settings.json")
        for directory in [bundledScript, configuration] {
            try FileManager.default.createDirectory(
                at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try "#!/bin/sh\nexit 0\n".write(to: bundledScript, atomically: true, encoding: .utf8)
        let installer = AgentHookInstaller(
            stateDirectory: root.appendingPathComponent("state"),
            targets: [AgentHookTarget(name: "Claude Code", url: configuration)])
        installer.install(bundledScript: bundledScript)
        return installer
    }

    /// A run on defaults because `server.json` would not parse reads the
    /// switch as off, and still looks in both files.
    func testAnUnreadableConfigStillLooks() throws {
        let loaded = try loadUnreadableConfig()

        XCTAssertEqual(
            AgentHookLaunchPass.decide(
                enabled: loaded.config.agentHooks,
                removalPending: loaded.config.agentHooksRemovalPending),
            .lookFirst)
    }

    /// An entry of this install's that such a run finds is a removal owed,
    /// whatever the unreadable file says.
    func testAnUnreadableRunOwesTheRemovalOfThisInstallsEntry() throws {
        let loaded = try loadUnreadableConfig()
        let installer = try installedEntry()

        let pass = AgentHookLaunchPass.decide(
            enabled: loaded.config.agentHooks,
            removalPending: loaded.config.agentHooksRemovalPending)

        XCTAssertTrue(pass.proceeds(holdsOwnEntry: installer.holdsOwnEntry()))
    }

    /// Once the file parses again, a switch that is on puts the entry back on
    /// that launch.
    func testAReadableConfigWithTheSwitchOnReinstalls() throws {
        var config = ServerConfig.defaults
        config.agentHooks = true
        try ServerConfig.save(config, to: configURL)
        let loaded = ServerConfig.loadForRun(from: configURL)

        XCTAssertEqual(
            AgentHookLaunchPass.decide(
                enabled: loaded.config.agentHooks,
                removalPending: loaded.config.agentHooksRemovalPending),
            .apply)
    }

    func testASwitchThatIsOnIsReaffirmed() {
        XCTAssertEqual(
            AgentHookLaunchPass.decide(enabled: true, removalPending: false),
            .apply)
    }

    func testAPendingRemovalIsRetried() {
        XCTAssertEqual(
            AgentHookLaunchPass.decide(enabled: false, removalPending: true),
            .apply)
    }

    func testASwitchThatIsOffOnlyLooks() {
        XCTAssertEqual(
            AgentHookLaunchPass.decide(enabled: false, removalPending: false),
            .lookFirst)
    }

    func testALookThatFindsNoEntryDoesNotProceed() {
        XCTAssertFalse(AgentHookLaunchPass.lookFirst.proceeds(holdsOwnEntry: false))
    }

    func testALookThatFindsAnEntryProceeds() {
        XCTAssertTrue(AgentHookLaunchPass.lookFirst.proceeds(holdsOwnEntry: true))
    }

    func testAnEntrySurvivingAReportedRemovalKeepsItOwed() {
        XCTAssertTrue(
            AgentHookInstaller.removalOwed(enabled: false, refused: [], entrySurvives: true))
    }

    func testARefusedTargetKeepsTheRemovalOwed() {
        XCTAssertTrue(
            AgentHookInstaller.removalOwed(
                enabled: false, refused: ["Codex"], entrySurvives: false))
    }

    func testAClearRemovalIsNoLongerOwed() {
        XCTAssertFalse(
            AgentHookInstaller.removalOwed(enabled: false, refused: [], entrySurvives: false))
    }

    func testAnInstallOwesNoRemoval() {
        XCTAssertFalse(
            AgentHookInstaller.removalOwed(enabled: true, refused: ["Codex"], entrySurvives: true))
    }
}
