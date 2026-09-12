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
        keepAwake: KeepAwakeMode = .off
    ) -> UsageEngine {
        var config = ServerConfig.defaults
        config.claudeDataDir = claudeDir.path
        config.codexDataDir = codexDir.path
        config.remotePricing = false
        config.providers = ProviderToggles(claudeCode: claudeCode, codex: codex)
        config.keepAwake = keepAwake
        return UsageEngine(
            config: config,
            configURL: configURL,
            limitsProbe: ClaudeLimitsProbe { _ in .absent }
        )
    }

    /// One assistant turn, timestamped now so it lands in today's bucket. It is
    /// what gives the engine a reading to replay — a setting changed before the
    /// first one has nothing to rebuild.
    private func writeClaudeTurn() throws {
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let line = """
            {"type":"assistant","timestamp":"\(iso.string(from: Date()))",\
            "requestId":"r1","message":{"model":"claude-sonnet-4-6",\
            "usage":{"input_tokens":\(Self.tokensPerTurn),"output_tokens":0,\
            "cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
            """
        try (line + "\n").write(
            to: claudeDir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
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
