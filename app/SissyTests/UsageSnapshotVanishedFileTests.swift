import XCTest

@testable import Sissy

/// What a relaunch makes of a snapshot naming a log file that is no longer
/// in the tree.
///
/// Codex moves a rollout it archives into `archived_sessions`, outside the
/// tree the tail reads, and a session archived the same day is one whose
/// turns the snapshot has already counted. Refusing the snapshot over it sent
/// the relaunch into a cold scan that cannot see that file any more.
final class UsageSnapshotVanishedFileTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-vanished-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var sessionsDir: URL { root.appendingPathComponent("sessions") }
    private var archiveDir: URL { root.appendingPathComponent("archived_sessions") }

    func testARelaunchKeepsTheTurnsOfAFileArchivedSinceTheSnapshot() async throws {
        try write("kept.jsonl", tokens: 1000)
        try write("archived.jsonl", tokens: 500)
        let before = await meter()
        XCTAssertEqual(before.totalTokens, 1500, "the fixture was not read as written")

        try FileManager.default.moveItem(
            at: sessionsDir.appendingPathComponent("archived.jsonl"),
            to: archiveDir.appendingPathComponent("archived.jsonl"))
        let after = await meter()

        XCTAssertEqual(after.totalTokens, 1500, "the archived session's turns left today's total")
    }

    private func meter() async -> DayTotals {
        let provider = LocalUsageProvider.codex(
            codexDir: sessionsDir,
            retainDays: 2,
            pollInterval: .seconds(60),
            persistenceURL: UsageStatePersistence.forProvider(ProviderID.codex, in: root),
            ledger: ProjectLedger(url: ProjectLedger.defaultURL(in: root))
        )
        await provider.start { _ in }
        let today = await provider.current()
        await provider.stop()
        return today
    }

    private let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// One rollout holding one turn of `tokens`, stamped now so it lands in
    /// today's bucket whenever the test runs.
    private func write(_ name: String, tokens: Int) throws {
        let at = stamp.string(from: Date())
        let lines: [[String: Any]] = [
            ["type": "session_meta", "timestamp": at, "payload": ["id": name, "cwd": root.path]],
            ["type": "turn_context", "timestamp": at, "payload": ["model": "gpt-5-codex"]],
            [
                "type": "event_msg", "timestamp": at,
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": [
                            "input_tokens": tokens, "cached_input_tokens": 0,
                            "output_tokens": 0, "total_tokens": tokens,
                        ],
                        "total_token_usage": [
                            "input_tokens": tokens, "cached_input_tokens": 0,
                            "output_tokens": 0, "total_tokens": tokens,
                        ],
                    ],
                ],
            ],
        ]
        let text = try lines.map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
        }.joined(separator: "\n")
        try Data((text + "\n").utf8).write(to: sessionsDir.appendingPathComponent(name))
    }
}
