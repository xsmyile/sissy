import XCTest

@testable import Sissy

/// The half of the teardown that lives below the engine. `UsageEngine.stop()`
/// cancels the boot task and then stops every provider, so both arrive while a
/// cold scan may still be walking a tree — and until the provider carried a
/// lifecycle of its own, the rest of `start()` resumed straight past them,
/// arming an FSEvents stream and a 60 s loop that the teardown had no handle
/// left to cancel.
final class UsageProviderLifecycleTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-provider-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private static let tokensPerTurn = 1_000_000

    /// One assistant turn of `tokensPerTurn` input tokens, timestamped now so
    /// it lands in today's bucket.
    private func writeTurn(_ name: String, requestId: String) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let line = """
            {"type":"assistant","timestamp":"\(iso.string(from: Date()))",\
            "requestId":"\(requestId)","message":{"model":"claude-sonnet-4-6",\
            "usage":{"input_tokens":\(Self.tokensPerTurn),"output_tokens":0,\
            "cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
            """
        try (line + "\n").write(
            to: tempDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// No persistence URL: the provider reads the temp tree and writes nothing,
    /// so a test never touches the snapshot the real app resumes from.
    private func makeProvider() -> LocalUsageProvider {
        LocalUsageProvider.claudeCode(
            claudeDir: tempDir,
            retainDays: 2,
            pollInterval: .seconds(60),
            persistenceURL: nil
        )
    }

    /// The ordering a boolean flag gets wrong: a `stop()` that arrives first
    /// leaves it false, and `start()` then boots as if nothing had happened —
    /// which is a tail on a tree nobody can stop any more.
    func testAStoppedProviderDoesNotBoot() async throws {
        try writeTurn("a.jsonl", requestId: "r1")
        let provider = makeProvider()

        await provider.stop()
        await provider.start { _, _ in }

        let (today, _) = await provider.current()
        XCTAssertEqual(today.totalTokens, 0, "a stopped provider scanned the tree")
        let warm = await provider.isWarm()
        XCTAssertFalse(warm, "a boot that never ran reported a complete cold scan")
        XCTAssertEqual(provider.filesWatched(), 0, "a stopped provider is watching files")
    }

    /// Which of the two reaches the actor first is deliberately not controlled,
    /// because that is the point: whatever the scan managed to read, a provider
    /// that has been stopped must never read the tree again.
    func testAStopWinsOverAConcurrentStart() async throws {
        try writeTurn("a.jsonl", requestId: "r1")
        let provider = makeProvider()

        let booting = Task { await provider.start { _, _ in } }
        await provider.stop()
        await booting.value

        try writeTurn("b.jsonl", requestId: "r2")
        await provider.start { _, _ in }

        let (today, _) = await provider.current()
        XCTAssertLessThanOrEqual(
            today.totalTokens,
            Self.tokensPerTurn,
            "a stopped provider counted a file that appeared after the teardown"
        )
    }

    /// Termination can reach this more than once, and the flush it forces is a
    /// write: the second one has nothing left to say.
    func testStopIsIdempotent() async throws {
        try writeTurn("a.jsonl", requestId: "r1")
        let snapshot = tempDir.appendingPathComponent("usage-state.json")
        let provider = LocalUsageProvider.claudeCode(
            claudeDir: tempDir,
            retainDays: 2,
            pollInterval: .seconds(60),
            persistenceURL: snapshot
        )
        await provider.start { _, _ in }
        await provider.stop()
        let firstWrite = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: snapshot.path)[.modificationDate] as? Date,
            "the first stop wrote no snapshot"
        )

        await provider.stop()

        let secondWrite =
            try FileManager.default.attributesOfItem(atPath: snapshot.path)[.modificationDate]
            as? Date
        XCTAssertEqual(
            secondWrite?.timeIntervalSince1970,
            firstWrite.timeIntervalSince1970,
            "a second stop rewrote the snapshot"
        )
    }
}
