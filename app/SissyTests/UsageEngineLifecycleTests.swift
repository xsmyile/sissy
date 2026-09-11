import XCTest

@testable import Sissy

/// Nothing called `stop()` until termination was wired to it, so everything it
/// does ran for the first time here. Two properties matter: a teardown must
/// leave nothing running, and it must hold even when it lands while `start()`
/// is still suspended — which is the window that used to boot the aggregator
/// and the refresh loop against an engine that had already shut down.
final class UsageEngineLifecycleTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-engine-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Points every path at the temp tree and pins pricing to the embedded
    /// seed, so a test neither reads the real log trees nor reaches the network.
    private func makeEngine() -> UsageEngine {
        var config = ServerConfig.defaults
        config.claudeDataDir = tempDir.appendingPathComponent("claude").path
        config.codexDataDir = tempDir.appendingPathComponent("codex").path
        config.remotePricing = false
        return UsageEngine(
            config: config,
            configURL: tempDir.appendingPathComponent("server.json")
        )
    }

    /// The stake is a keychain dialog: `setClaudeLimits` is what starts the
    /// probe, and a control call arriving after teardown must not put a system
    /// prompt in front of someone who has quit.
    func testAStoppedEngineWillNotStartTheLimitsProbe() async {
        let engine = makeEngine()
        await engine.start { _ in }
        await engine.stop()

        await engine.setClaudeLimits(enabled: true)

        let claudeLimits = await engine.config.claudeLimits
        XCTAssertFalse(claudeLimits, "a stopped engine took a control call")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: tempDir.appendingPathComponent("server.json").path),
            "a stopped engine persisted a setting it did not apply"
        )
    }

    /// Termination can reach this more than once, and the readiness poll can
    /// still be in flight when it does.
    func testStopIsIdempotent() async {
        let engine = makeEngine()
        await engine.start { _ in }

        await engine.stop()
        await engine.stop()

        let readiness = await engine.providerReadiness()
        XCTAssertEqual(readiness.count, 2, "the resolved list outlives the readers")
    }

    /// The window the flag exists for. `stop()` is issued without awaiting
    /// `start()`, so it lands while `start()` is suspended; `start()` must then
    /// abandon the rest of its boot rather than resume into it.
    func testAStopLandingDuringStartLeavesNothingRunning() async {
        let engine = makeEngine()
        let booting = Task { await engine.start { _ in } }

        await engine.stop()
        await booting.value

        await engine.setClaudeLimits(enabled: true)
        let claudeLimits = await engine.config.claudeLimits
        XCTAssertFalse(claudeLimits, "start() resumed into a torn-down engine")
    }

    /// A provider that was never built still has to be listed, because "off"
    /// is the answer the Providers tab needs — and teardown must not lose it.
    func testTheResolvedListSurvivesATeardown() async {
        let engine = makeEngine()
        await engine.start { _ in }
        await engine.stop()

        let ids = await engine.providerReadiness().map(\.id)
        XCTAssertEqual(ids, [ProviderID.claudeCode, ProviderID.codex])
    }
}
