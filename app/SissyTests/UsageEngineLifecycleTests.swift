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
        limitsProbe: ClaudeLimitsProbe = ClaudeLimitsProbe { _, _ in .absent },
        statusMonitor: ProviderStatusMonitor? = nil
    ) -> UsageEngine {
        var config = ServerConfig.defaults
        config.claudeDataDir = tempDir.appendingPathComponent("claude").path
        config.codexDataDir = tempDir.appendingPathComponent("codex").path
        config.remotePricing = false
        return UsageEngine(
            config: config,
            configURL: tempDir.appendingPathComponent("server.json"),
            limitsProbe: limitsProbe,
            claudeAccounts: .inert(),
            statusMonitor: statusMonitor
                ?? ProviderStatusMonitor(providers: []) { _ in
                    throw ProviderStatusError.malformedPayload
                }
        )
    }

    /// A monitor whose every fetch fulfils the expectation handed to it.
    ///
    /// Inverted at the call sites, because what these tests assert is that
    /// something does *not* happen — and a poll loop starts its work in a
    /// detached task, so reading a counter straight after the teardown proves
    /// only that the task had not been scheduled yet.
    private func signallingMonitor(_ fetched: XCTestExpectation) -> ProviderStatusMonitor {
        ProviderStatusMonitor(providers: [ProviderID.claudeCode]) { _ in
            fetched.fulfill()
            return ProviderStatusReading(
                indicator: .operational, description: "All Systems Operational",
                checkedAt: Date())
        }
    }

    /// Long enough for a poll task that was started to reach its first fetch,
    /// which is immediate: the loop opens with no delay at all.
    private static let orphanPollWindow: TimeInterval = 1

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

    /// The status poll is the second thing that reaches the network on a timer,
    /// and it is reached across two suspensions a teardown can land in: the
    /// boot's own, and a Settings toggle flipped while the app is quitting.
    /// Neither may leave a loop behind, because nothing holds a handle to one
    /// that is.
    ///
    /// Only the toggle is pinned here. The boot's window is an actor hop —
    /// `ClaudeLimitsProbe.start` spawns its request and returns rather than
    /// awaiting the credential — so a test of that path passes whether the
    /// guard is there or not, and a test that cannot fail is worse than none.
    /// The guard covers both; this holds the half that can be held.
    func testTheStatusToggleDoesNotRestartAStoppedEngine() async {
        let fetched = XCTestExpectation(description: "status fetch after teardown")
        fetched.isInverted = true
        let engine = makeEngine(statusMonitor: signallingMonitor(fetched))
        await engine.stop()

        await engine.setStatusChecks(enabled: false)
        await engine.setStatusChecks(enabled: true)

        await fulfillment(of: [fetched], timeout: Self.orphanPollWindow)
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
