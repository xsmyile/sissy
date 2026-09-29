import XCTest

@testable import Sissy

/// What a relaunch reads after a crash that left the snapshot behind the logs
/// and behind the day file written after it.
///
/// The snapshot is rewritten on a longer throttle than the day files, so a
/// process that dies between two snapshot saves leaves the archive ahead of
/// the offsets, totals and dedup keys that were saved together. The relaunch
/// re-reads everything after those offsets, and has to arrive at exactly what
/// an uninterrupted run and a clean scan arrive at: nothing counted twice,
/// nothing lost.
final class UsageSnapshotCrashTests: XCTestCase {
    private var logDir: URL!
    private var stateDir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-crash-\(UUID().uuidString)")
        logDir = base.appendingPathComponent("logs")
        stateDir = base.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: logDir.deletingLastPathComponent())
    }

    private static let model = "claude-opus-5"

    func testARelaunchFromASnapshotOlderThanTheLogsCountsLikeACleanScan() async throws {
        try append(id: "m1", output: 40)
        try append(id: "m2", output: 3)
        _ = try await run()
        let staleSnapshot = try Data(contentsOf: snapshotURL)

        try append(id: "m2", output: 900)
        try append(id: "m3", output: 70)
        let uninterrupted = try await run()
        let archivedAhead = try archived()
        XCTAssertEqual(
            uninterrupted.totalTokens, 3 * (100 + 2000) + 40 + 900 + 70,
            "the run the crash loses did not count three turns with the streamed one at its end")

        try staleSnapshot.write(to: snapshotURL, options: [.atomic])
        guard case .ok(let stale) = UsageStatePersistence.load(from: snapshotURL) else {
            return XCTFail("the snapshot put back does not load")
        }
        let logSize = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: logDir.appendingPathComponent("s.jsonl").path)[
                .size] as? NSNumber)
        XCTAssertLessThan(
            try XCTUnwrap(stale.files.first?.offset), logSize.uint64Value,
            "the snapshot put back is not behind the log, so nothing is re-read")
        let relaunched = try await run()

        XCTAssertEqual(
            relaunched, uninterrupted, "the relaunch read the day differently from the run it lost")
        XCTAssertEqual(
            try archived(), archivedAhead,
            "the relaunch rewrote the day file it was behind with something else")

        try FileManager.default.removeItem(at: stateDir)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let clean = try await run()
        XCTAssertEqual(relaunched, clean, "the relaunch and a clean scan disagree")
        XCTAssertEqual(try archived(), archivedAhead, "a clean scan archived a different day")
    }

    private var snapshotURL: URL { UsageStatePersistence.defaultURL(in: stateDir) }

    private func run() async throws -> DayTotals {
        let provider = LocalUsageProvider.claudeCode(
            claudeDir: logDir,
            pollInterval: .seconds(60),
            persistenceURL: snapshotURL,
            historyRoot: stateDir
        )
        await provider.start { _ in }
        let today = await provider.current()
        await provider.stop()
        return today
    }

    private func archived() throws -> UsageHistoryTotals {
        let day = UsageReaderShared.dayFormatter.string(from: Date())
        let record = try XCTUnwrap(
            UsageHistoryStore.load(provider: ProviderID.claudeCode, day: day, in: stateDir),
            "the tail archived nothing for today")
        return record.totals(forModel: Self.model)
    }

    /// One copy of an assistant message. Two copies with one id are one turn
    /// still streaming, the way the CLI writes it.
    private func append(id: String, output: Int) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let line = """
            {"type":"assistant","timestamp":"\(iso.string(from: Date()))","requestId":"r-\(id)",\
            "message":{"id":"\(id)","model":"\(Self.model)",\
            "usage":{"input_tokens":100,"output_tokens":\(output),\
            "cache_read_input_tokens":2000,"cache_creation_input_tokens":0}}}

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
