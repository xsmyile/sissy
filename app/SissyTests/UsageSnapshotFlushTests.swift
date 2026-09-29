import XCTest

@testable import Sissy

/// The snapshot is written on a throttle, and what the throttle holds back
/// has to reach the disk when the Mac sleeps without waiting for it.
///
/// Driven through a real tree and the tail's own poll, because writes from
/// this process are the ones FSEvents is told to ignore.
final class UsageSnapshotFlushTests: XCTestCase {
    private var logDir: URL!
    private var stateDir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-flush-\(UUID().uuidString)")
        logDir = base.appendingPathComponent("logs")
        stateDir = base.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: logDir.deletingLastPathComponent())
    }

    private static let pollInterval: Duration = .milliseconds(50)
    private static let tokensPerTurn = 15

    func testAFlushWritesWhatTheThrottleHeldBack() async throws {
        try append(turn: "m1")
        let provider = tail()
        let (readings, onChange) = TailReadings.stream()
        await provider.start(onChange: onChange)
        let snapshot = UsageStatePersistence.defaultURL(in: stateDir)
        try FileManager.default.removeItem(at: snapshot)

        try append(turn: "m2")
        try await TailReadings.waitUntil(readings, reach: 2 * Self.tokensPerTurn)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: snapshot.path),
            "the snapshot was rewritten inside its throttle")

        await provider.flush()
        guard case .ok(let written) = UsageStatePersistence.load(from: snapshot) else {
            await provider.stop()
            return XCTFail("the flush wrote no readable snapshot")
        }
        await provider.stop()
        XCTAssertEqual(
            written.dedupKeysToday.count, 2, "the flush left the second turn out of the snapshot")
    }

    func testAFlushWithNothingPendingLeavesTheSnapshotAlone() async throws {
        try append(turn: "m1")
        let provider = tail()
        await provider.start { _ in }
        let snapshot = UsageStatePersistence.defaultURL(in: stateDir)
        try FileManager.default.removeItem(at: snapshot)

        await provider.flush()
        let rewritten = FileManager.default.fileExists(atPath: snapshot.path)
        await provider.stop()
        XCTAssertFalse(rewritten, "a flush rewrote a snapshot nothing had changed")
    }

    /// A sleep can land while the cold scan is still reading. The scan's first
    /// emit is made from inside it, so a flush issued from that callback runs
    /// with the scan part-way through, and must leave the archive to the
    /// scan's own end.
    func testAFlushDuringTheColdScanWritesNoArchivedDay() async throws {
        try append(turn: "m1")
        let provider = tail()
        let midScan = LockedValue<(warm: Bool, days: [String])?>(nil)
        let historyRoot = stateDir!
        await provider.start { _ in
            guard midScan.load() == nil else { return }
            let warm = await provider.isWarm()
            await provider.flush()
            midScan.store(
                (warm, UsageHistoryStore.storedDays(provider: ProviderID.claudeCode, in: historyRoot)))
        }
        await provider.stop()

        let observed = try XCTUnwrap(midScan.load(), "the cold scan emitted nothing")
        XCTAssertFalse(observed.warm, "the first emit came after the scan, so nothing was tested")
        XCTAssertEqual(observed.days, [], "a flush during the cold scan wrote a day it had half read")
    }

    private func tail() -> LocalUsageProvider {
        LocalUsageProvider.claudeCode(
            claudeDir: logDir,
            pollInterval: Self.pollInterval,
            persistenceURL: UsageStatePersistence.defaultURL(in: stateDir),
            historyRoot: stateDir
        )
    }

    private func append(turn id: String) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let line = """
            {"type":"assistant","timestamp":"\(iso.string(from: Date()))","requestId":"r-\(id)",\
            "message":{"id":"\(id)","model":"claude-opus-5",\
            "usage":{"input_tokens":10,"output_tokens":5,\
            "cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}

            """
        let url = logDir.appendingPathComponent("s.jsonl")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } else {
            try line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
