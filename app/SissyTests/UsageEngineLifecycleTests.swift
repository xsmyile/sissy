import XCTest

@testable import Sissy

/// Nothing called `stop()` until termination was wired to it, so everything it
/// does ran for the first time here. Two properties matter: a teardown must
/// leave nothing running, and it must win against a concurrent `start()` in
/// either order — the window that used to boot the aggregator and the pricing
/// refresh against an engine that had already shut down.
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
    private func makeEngine(
        limitsProbe: ClaudeLimitsProbe = ClaudeLimitsProbe { _, _ in .absent }
    ) -> UsageEngine {
        var config = ServerConfig.defaults
        config.claudeDataDir = tempDir.appendingPathComponent("claude").path
        config.codexDataDir = tempDir.appendingPathComponent("codex").path
        config.remotePricing = false
        return UsageEngine(
            config: config,
            configURL: tempDir.appendingPathComponent("server.json"),
            limitsProbe: limitsProbe,
            claudeAccounts: .inert()
        )
    }

    /// A teardown has to leave no poll behind, and the limits poll is the one
    /// that reaches the network on a timer.
    func testAStoppedEngineRunsNoLimitsPoll() async {
        let reads = LockedValue(0)
        let engine = makeEngine(
            limitsProbe: ClaudeLimitsProbe { _, _ in
                reads.update { $0 += 1 }
                return .absent
            })
        await engine.start { _ in }
        await engine.stop()
        let afterStop = reads.load()

        await engine.start { _ in }

        XCTAssertEqual(reads.load(), afterStop, "a stopped engine restarted the limits poll")
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

    /// Which of the two reaches the actor first is deliberately not controlled,
    /// because that is the point: a boot racing a teardown has to end stopped
    /// whichever way it lands. The ordering this catches in practice is the one
    /// a boolean flag got wrong — a `stop()` arriving before `start()` left the
    /// flag false, and `start()` then booted as if nothing had happened.
    func testAStopWinsOverAConcurrentStart() async {
        let reads = LockedValue(0)
        let engine = makeEngine(
            limitsProbe: ClaudeLimitsProbe { _, _ in
                reads.update { $0 += 1 }
                return .absent
            })
        let booting = Task { await engine.start { _ in } }

        await engine.stop()
        await booting.value

        XCTAssertEqual(reads.load(), 0, "start() resumed into a torn-down engine")
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
