import IOKit.pwr_mgt
import XCTest

@testable import Sissy

/// The path from `server.json` to a frame: which providers the config resolves
/// to, and what the two control calls the app makes — the limits switch and the
/// keep-awake switch — do to the file, the probe and the next frame.
///
/// The engine came out of the deleted server with none of this covered. Its
/// collaborators were: the readers, the aggregator, the frame builder, pricing,
/// persistence. What ran untested was the wiring between them.
final class UsageEngineControlTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-engine-control-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var claudeDir: URL { tempDir.appendingPathComponent("claude") }
    private var codexDir: URL { tempDir.appendingPathComponent("codex") }
    private var configURL: URL { tempDir.appendingPathComponent("server.json") }

    private static let tokensPerTurn = 1_000_000
    /// The name a user reads in `pmset -g assertions`, counted rather than
    /// looked for: another suite's `KeepAwake` can be holding one under the
    /// same name, and what a teardown has to prove is that it did not leak.
    private static let systemAssertionName = "Sissy is keeping this Mac awake"

    /// Points every path at the temp tree, pins pricing to the embedded seed so
    /// nothing reaches the network, and answers the keychain with `absent` —
    /// which is the reply that stops the probe before its own request, so
    /// turning the limits switch on in a test raises neither a system dialog
    /// nor a call to Anthropic.
    private func makeEngine(
        claudeCode: Bool? = nil,
        codex: Bool? = nil,
        keepAwake: KeepAwakeMode = .off,
        keepAwakePolicy: KeepAwakePolicy = .default,
        pollIntervalSeconds: Double = 60
    ) -> UsageEngine {
        var config = ServerConfig.defaults
        config.claudeDataDir = claudeDir.path
        config.codexDataDir = codexDir.path
        config.remotePricing = false
        config.pollIntervalSeconds = pollIntervalSeconds
        config.providers = ProviderToggles(claudeCode: claudeCode, codex: codex)
        config.keepAwake = keepAwake
        return UsageEngine(
            config: config,
            configURL: configURL,
            limitsProbe: ClaudeLimitsProbe { _ in .absent },
            keepAwakePolicy: keepAwakePolicy
        )
    }

    /// One assistant turn, timestamped now so it lands in today's bucket. It is
    /// what gives the engine a reading to replay — a setting changed before the
    /// first one has nothing to rebuild.
    /// Each turn gets its own request id and its own file, because the reader
    /// is built to count a turn once: the same id written twice is what the
    /// dedup ledger exists to collapse, and it would land as no new tokens at
    /// all.
    private func writeClaudeTurn(requestId: String = "r1", file: String = "a.jsonl") throws {
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let line = """
            {"type":"assistant","timestamp":"\(iso.string(from: Date()))",\
            "requestId":"\(requestId)","message":{"model":"claude-sonnet-4-6",\
            "usage":{"input_tokens":\(Self.tokensPerTurn),"output_tokens":0,\
            "cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
            """
        try (line + "\n").write(
            to: claudeDir.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    // MARK: Provider resolution

    func testAnUnsetClaudeToggleMetersAndAnUnsetCodexOneAsksTheDisk() async {
        let engine = makeEngine()
        await engine.start { _ in }
        addTeardownBlock { await engine.stop() }

        let readiness = await engine.providerReadiness()
        XCTAssertEqual(readiness.map(\.id), [ProviderID.claudeCode, ProviderID.codex])
        XCTAssertEqual(readiness[0].activation, .on)
        XCTAssertEqual(readiness[1].activation, .autoNotFound)
        XCTAssertEqual(readiness[0].dataDir, claudeDir)
        XCTAssertEqual(readiness[1].dataDir, codexDir)
    }

    func testACodexTreeOnDiskIsMeteredWithoutBeingAskedFor() async throws {
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let engine = makeEngine()
        await engine.start { _ in }
        addTeardownBlock { await engine.stop() }

        let readiness = await engine.providerReadiness()
        XCTAssertEqual(readiness[1].activation, .autoDetected)
        XCTAssertNotNil(readiness[1].scan, "a metering provider reports its scan")
    }

    /// The difference between "off" and "not there": both are listed, and
    /// neither is read. It is the listing the Providers tab renders.
    func testAProviderSwitchedOffIsStillListedAndNeverRead() async throws {
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let engine = makeEngine(claudeCode: false, codex: false)
        await engine.start { _ in }
        addTeardownBlock { await engine.stop() }

        let readiness = await engine.providerReadiness()
        XCTAssertEqual(readiness.map(\.activation), [.off, .off])
        XCTAssertNil(readiness[0].scan, "a provider that is off has no reader")
        XCTAssertNil(readiness[1].scan)
    }

    // MARK: The limits switch

    func testTurningTheLimitsSwitchOnPersistsItWhereARelaunchWillReadIt() async throws {
        let engine = makeEngine()
        await engine.start { _ in }
        addTeardownBlock { await engine.stop() }

        await engine.setClaudeLimits(enabled: true)

        let inMemory = await engine.config.claudeLimits
        XCTAssertTrue(inMemory)
        XCTAssertTrue(try ServerConfig.load(from: configURL).claudeLimits)
    }

    func testTurningTheLimitsSwitchOffPersistsThatToo() async throws {
        let engine = makeEngine()
        await engine.start { _ in }
        addTeardownBlock { await engine.stop() }
        await engine.setClaudeLimits(enabled: true)

        await engine.setClaudeLimits(enabled: false)

        let inMemory = await engine.config.claudeLimits
        XCTAssertFalse(inMemory)
        XCTAssertFalse(try ServerConfig.load(from: configURL).claudeLimits)
    }

    /// The setter guards on the value actually changing, so a switch already
    /// where it is asked to be writes nothing.
    func testSettingTheLimitsSwitchToWhereItAlreadyIsTouchesNothing() async {
        let engine = makeEngine()
        await engine.start { _ in }
        addTeardownBlock { await engine.stop() }

        await engine.setClaudeLimits(enabled: false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
    }

    // MARK: The keep-awake switch

    func testTheKeepAwakeModeReachesTheFileAndTheAssertion() async throws {
        let engine = makeEngine()
        await engine.start { _ in }

        let baseline = heldSystemAssertions()

        await engine.setKeepAwake(mode: KeepAwakeMode.on.rawValue)

        let mode = await engine.config.keepAwake
        XCTAssertEqual(mode, .on)
        XCTAssertEqual(try ServerConfig.load(from: configURL).keepAwake, .on)
        XCTAssertEqual(heldSystemAssertions(), baseline + 1, "the switch took no assertion")

        await engine.stop()
        XCTAssertEqual(heldSystemAssertions(), baseline, "a teardown left the Mac held awake")
    }

    /// The panel counts up from this rather than being told a duration, so
    /// the frame has to carry the instant the hold started — and carry nothing
    /// once the hold is gone, or the control would run a stopwatch over a Mac
    /// that is free to sleep.
    func testTheHoldSaysWhenItWasTaken() async throws {
        try writeClaudeTurn()
        let frames = FrameRecorder()
        let engine = makeEngine(codex: false)
        let firstFrame = frames.expectation(forFrameCount: 1)
        await engine.start { frames.record($0) }
        await fulfillment(of: [firstFrame], timeout: 5)
        addTeardownBlock { await engine.stop() }
        XCTAssertNil(frames.all.last?.keepAwake.since, "an idle Mac reported a hold")

        let before = Date()
        let onFrame = frames.expectation(forFrameCount: frames.count + 1)
        await engine.setKeepAwake(mode: KeepAwakeMode.on.rawValue)
        await fulfillment(of: [onFrame], timeout: 5)

        let held = try XCTUnwrap(frames.all.last?.keepAwake)
        XCTAssertTrue(held.active)
        let since = try XCTUnwrap(held.since)
        XCTAssertGreaterThanOrEqual(since, before)
        XCTAssertLessThanOrEqual(since, Date())

        let offFrame = frames.expectation(forFrameCount: frames.count + 1)
        await engine.setKeepAwake(mode: KeepAwakeMode.off.rawValue)
        await fulfillment(of: [offFrame], timeout: 5)

        let released = try XCTUnwrap(frames.all.last?.keepAwake)
        XCTAssertFalse(released.active)
        XCTAssertNil(released.since)
    }

    /// The screen half is a setting the engine owns, so it has to reach the
    /// file and the assertions the same way the mode does — and reach the
    /// frame, which is where the panel words its control from.
    func testTheScreenSettingReachesTheFileAndTheFrame() async throws {
        try writeClaudeTurn()
        let frames = FrameRecorder()
        let engine = makeEngine(codex: false, keepAwake: .on)
        let firstFrame = frames.expectation(forFrameCount: 1)
        await engine.start { frames.record($0) }
        await fulfillment(of: [firstFrame], timeout: 5)
        addTeardownBlock { await engine.stop() }
        XCTAssertEqual(frames.all.last?.keepAwake.coversScreen, true, "the default dropped the screen")

        let dropped = frames.expectation(forFrameCount: frames.count + 1)
        await engine.setKeepScreenAwake(enabled: false)
        await fulfillment(of: [dropped], timeout: 5)

        let state = try XCTUnwrap(frames.all.last?.keepAwake)
        XCTAssertTrue(state.active, "dropping the screen released the whole hold")
        XCTAssertFalse(state.coversScreen)
        XCTAssertEqual(try ServerConfig.load(from: configURL).keepScreenAwake, false)
    }

    /// Nothing is held when the switch is off, so the screen half has nothing
    /// to report either — a frame saying otherwise would word the panel's
    /// control around a screen assertion that does not exist.
    func testTheScreenIsNotCoveredWhileTheSwitchIsOff() async throws {
        try writeClaudeTurn()
        let frames = FrameRecorder()
        let engine = makeEngine(codex: false)
        let firstFrame = frames.expectation(forFrameCount: 1)
        await engine.start { frames.record($0) }
        await fulfillment(of: [firstFrame], timeout: 5)
        addTeardownBlock { await engine.stop() }

        let state = try XCTUnwrap(frames.all.last?.keepAwake)
        XCTAssertFalse(state.active)
        XCTAssertFalse(state.coversScreen)
    }

    // MARK: The automatic mode

    /// The whole point of the automatic mode: the hold is earned by a turn
    /// landing, not by the switch being flipped. A cold scan reports what
    /// happened before Sissy was launched, so it earns nothing.
    ///
    /// The poll is turned down because the turn below is written by this
    /// process, and the watcher is created with `IgnoreSelf` — deliberately,
    /// since in production Sissy never writes inside the trees it reads. The
    /// safety-net poll is what sees a file the writer is not allowed to
    /// announce, so it is the path these tests exercise.
    func testAutomaticModeHoldsOnlyOnceATurnLands() async throws {
        try writeClaudeTurn()
        let frames = FrameRecorder()
        let engine = makeEngine(codex: false, keepAwake: .auto, pollIntervalSeconds: 1)
        let cold = frames.expectation(forFrameCount: 1)
        await engine.start { frames.record($0) }
        await fulfillment(of: [cold], timeout: 5)
        addTeardownBlock { await engine.stop() }

        XCTAssertEqual(frames.all.last?.keepAwake.mode, .auto)
        XCTAssertEqual(frames.all.last?.keepAwake.active, false, "a cold scan earned a hold")

        let held = frames.expectation("the hold is taken") { $0.keepAwake.active }
        try writeClaudeTurn(requestId: "r2", file: "b.jsonl")
        await fulfillment(of: [held], timeout: 5)
        let state = try XCTUnwrap(frames.all.last?.keepAwake)
        XCTAssertEqual(state.mode, .auto)
        XCTAssertNotNil(state.since)
    }

    /// A setting the user changed replays the same totals through the same
    /// path an emit takes. It is not an agent working, and reading growth
    /// rather than arrival is what tells the two apart.
    func testAConfigChangeIsNotAgentActivity() async throws {
        try writeClaudeTurn()
        let frames = FrameRecorder()
        let engine = makeEngine(codex: false, keepAwake: .auto)
        let cold = frames.expectation(forFrameCount: 1)
        await engine.start { frames.record($0) }
        await fulfillment(of: [cold], timeout: 5)
        addTeardownBlock { await engine.stop() }

        let replayed = frames.expectation("the setting is replayed") { !$0.keepAwake.coversScreen }
        await engine.setKeepScreenAwake(enabled: false)
        await fulfillment(of: [replayed], timeout: 5)

        XCTAssertEqual(frames.all.last?.keepAwake.active, false, "a setting change earned a hold")
    }

    /// Silence is what ends an automatic hold, and it has to end on its own:
    /// no emit arrives to say the agents stopped, which is the whole reason
    /// the engine keeps a deadline. The idle window is shorter than the poll
    /// that feeds it on purpose — the release must not need an emit.
    func testAnAutomaticHoldLetsGoAfterItsIdleWindow() async throws {
        try writeClaudeTurn()
        let frames = FrameRecorder()
        let engine = makeEngine(
            codex: false,
            keepAwake: .auto,
            keepAwakePolicy: KeepAwakePolicy(idleWindow: 0.4, manualCeiling: 3600),
            pollIntervalSeconds: 1)
        let cold = frames.expectation(forFrameCount: 1)
        await engine.start { frames.record($0) }
        await fulfillment(of: [cold], timeout: 5)
        addTeardownBlock { await engine.stop() }

        let held = frames.expectation("the hold is taken") { $0.keepAwake.active }
        try writeClaudeTurn(requestId: "r2", file: "b.jsonl")
        await fulfillment(of: [held], timeout: 5)

        let released = frames.expectation("the hold lets go") { !$0.keepAwake.active }
        await fulfillment(of: [released], timeout: 5)

        let state = try XCTUnwrap(frames.all.last?.keepAwake)
        XCTAssertNil(state.since)
        XCTAssertEqual(state.mode, .auto, "letting go switched the mode off")
    }

    /// A manual hold has no evidence behind it, so it is the one with a
    /// ceiling — and at the ceiling the switch goes off rather than the hold
    /// going quiet, because "on and holding nothing" already means an
    /// assertion was refused.
    func testAManualHoldSwitchesItselfOffAtItsCeiling() async throws {
        try writeClaudeTurn()
        let frames = FrameRecorder()
        let engine = makeEngine(
            codex: false,
            keepAwake: .on,
            keepAwakePolicy: KeepAwakePolicy(idleWindow: 600, manualCeiling: 0.4))
        let baseline = heldSystemAssertions()
        let expired = frames.expectation("the ceiling switches it off") { $0.keepAwake.mode == .off }
        await engine.start { frames.record($0) }
        addTeardownBlock { await engine.stop() }
        await fulfillment(of: [expired], timeout: 5)

        let state = try XCTUnwrap(frames.all.last?.keepAwake)
        XCTAssertFalse(state.active)
        XCTAssertEqual(try ServerConfig.load(from: configURL).keepAwake, .off)
        XCTAssertEqual(heldSystemAssertions(), baseline, "the ceiling left the Mac held awake")
    }

    func testAModeTheEngineDoesNotKnowIsIgnored() async {
        let engine = makeEngine()
        await engine.start { _ in }
        addTeardownBlock { await engine.stop() }

        await engine.setKeepAwake(mode: "sometimes")

        let mode = await engine.config.keepAwake
        XCTAssertEqual(mode, .off)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
    }

    /// Where a reading is written down. A snapshot describes the trees one
    /// config named, so it follows that config — which is also what keeps a
    /// test run out of the install's own reading.
    func testTheReadingIsWrittenBesideTheConfigThatNamedTheTree() async throws {
        try writeClaudeTurn()
        let frames = FrameRecorder()
        let engine = makeEngine(codex: false)
        let firstFrame = frames.expectation(forFrameCount: 1)
        await engine.start { frames.record($0) }
        await fulfillment(of: [firstFrame], timeout: 5)

        await engine.stop()

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: tempDir.appendingPathComponent("usage-state.json").path),
            "the snapshot went somewhere other than the config's own directory")
    }

    // MARK: The replay a setting change triggers

    /// A setting change re-emits so the panel shows it without waiting for the
    /// next token event — and the frame it re-emits has to carry the reading the
    /// last real frame did. Totals read from one moment and a breakdown from
    /// another is what this pins.
    func testASettingChangeReplaysTheReadingItFound() async throws {
        try writeClaudeTurn()
        let frames = FrameRecorder()
        let engine = makeEngine(codex: false)
        let firstFrame = frames.expectation(forFrameCount: 1)
        await engine.start { frames.record($0) }
        await fulfillment(of: [firstFrame], timeout: 5)

        let replay = frames.expectation(forFrameCount: frames.count + 1)
        await engine.setKeepAwake(mode: KeepAwakeMode.on.rawValue)
        await fulfillment(of: [replay], timeout: 5)
        await engine.stop()

        let metered = frames.all.first { !$0.providers.isEmpty }
        let replayed = frames.all.last
        XCTAssertEqual(replayed?.keepAwake.mode, .on, "the replay carries the new setting")
        XCTAssertEqual(replayed?.tokens, metered?.tokens, "the replay moved the token count")
        XCTAssertEqual(replayed?.providers, metered?.providers, "the replay moved the breakdown")
        XCTAssertEqual(
            replayed?.providers.map(\.tokens), [Self.tokensPerTurn],
            "the breakdown is the turn that was written")
    }

    /// With no reading to rebuild, the switch lands on the first real frame
    /// instead of manufacturing one out of an empty aggregator.
    ///
    /// Both providers are off so that state holds still. It is the same state a
    /// cold start is in before its first emit, which cannot be pinned by a test
    /// that races it: a provider reports once its scan ends even when the tree
    /// it scanned was empty.
    func testASettingChangedWithNoReadingToRebuildEmitsNoFrame() async {
        let frames = FrameRecorder()
        let engine = makeEngine(claudeCode: false, codex: false)
        await engine.start { frames.record($0) }

        await engine.setKeepAwake(mode: KeepAwakeMode.on.rawValue)
        await engine.stop()

        XCTAssertEqual(frames.count, 0, "a frame was built with nothing to build it from")
        XCTAssertEqual(try? ServerConfig.load(from: configURL).keepAwake, .on)
    }

    private func heldSystemAssertions() -> Int {
        var assertions: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&assertions) == kIOReturnSuccess,
            let byProcess = assertions?.takeRetainedValue() as? [AnyHashable: [[String: Any]]]
        else { return 0 }
        return byProcess.values.flatMap { $0 }
            .filter { $0["AssertName"] as? String == Self.systemAssertionName }
            .count
    }
}
