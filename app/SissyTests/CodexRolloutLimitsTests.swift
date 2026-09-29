import XCTest

@testable import Sissy

/// What the limits a rollout's `token_count` events carry publish.
final class CodexRolloutLimitsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-codex-limits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var sessionsDir: URL { root.appendingPathComponent("sessions") }

    /// An event with no timestamp is billed as if it landed now, and its
    /// limits must not be taken at that stamp: they would outrank the
    /// reading of every event that says when it was written.
    func testAnEventWithNoTimestampDoesNotReplaceTheLimits() async throws {
        try write([
            event(at: Date().addingTimeInterval(-60), used: 10, resetsAt: 4_102_000_000),
            event(at: nil, used: 90, resetsAt: 4_102_000_000),
        ])

        let windows = await windows()

        XCTAssertEqual(windows.map(\.usedPercent), [10])
    }

    /// A bucket nobody has started carries no reset, which is a window at
    /// its reading rather than no window, on the rule the poll of the same
    /// block already follows.
    func testABucketWithNoResetIsKept() async throws {
        try write([event(at: Date().addingTimeInterval(-60), used: 0, resetsAt: nil)])

        let windows = await windows()

        XCTAssertEqual(windows.count, 1)
        XCTAssertNil(windows.first?.resetsAt)
    }

    private func windows() async -> [UsageWindow] {
        let provider = LocalUsageProvider.codex(
            codexDir: sessionsDir,
            retainDays: 2,
            pollInterval: .seconds(60),
            ledger: ProjectLedger(url: ProjectLedger.defaultURL(in: root))
        )
        await provider.start { _ in }
        let windows = provider.currentSignals().windows
        await provider.stop()
        return windows
    }

    private let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func write(_ events: [[String: Any]]) throws {
        let meta: [String: Any] = [
            "type": "session_meta", "timestamp": stamp.string(from: Date().addingTimeInterval(-120)),
            "payload": ["id": UUID().uuidString, "cwd": root.path],
        ]
        let lines = try ([meta] + events).map {
            String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: sessionsDir.appendingPathComponent("one.jsonl"))
    }

    private var turns = 0

    /// A `token_count` carrying one five-hour bucket, each a turn of its own
    /// so the running total moves.
    private func event(at date: Date?, used: Double, resetsAt: Double?) -> [String: Any] {
        turns += 1
        var object: [String: Any] = [
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "last_token_usage": ["input_tokens": 100, "output_tokens": 0, "total_tokens": 100],
                    "total_token_usage": [
                        "input_tokens": 100 * turns, "output_tokens": 0, "total_tokens": 100 * turns,
                    ],
                ],
                "rate_limits": [
                    "primary": [
                        "used_percent": used, "window_minutes": 300,
                        "resets_at": resetsAt.map { $0 as Any } ?? NSNull(),
                    ]
                ],
            ],
        ]
        if let date { object["timestamp"] = stamp.string(from: date) }
        return object
    }
}
