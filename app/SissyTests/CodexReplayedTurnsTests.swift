import XCTest

@testable import Sissy

/// Which of a rollout's `token_count` events are turns the session actually
/// spent.
///
/// Codex writes more of them than there are turns, in two ways, and billing
/// the difference was measured at 1.8% of a year and 12% of its worst month:
/// it re-emits the previous turn's block when a session ends or is
/// interrupted, and a session opened from another one copies that one's whole
/// history into its own log. Neither is visible in the per-turn block alone —
/// both are told by what surrounds it.
final class CodexReplayedTurnsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-codex-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var sessionsDir: URL { root.appendingPathComponent("sessions") }
    private var stateDir: URL { root }

    /// The shape Codex leaves at the end of a session: one more `token_count`
    /// carrying the previous turn's block verbatim, with its own running total
    /// standing still. Measured on a real rollout — two events 2.5 minutes
    /// apart, both reporting 73 059, the cumulative stuck at 340 542.
    func testATurnReEmittedWithTheTotalStandingStillIsBilledOnce() async throws {
        try write(
            "one.jsonl",
            events: [
                (delta: 1000, cumulative: 1000, at: Self.at(0)),
                (delta: 500, cumulative: 1500, at: Self.at(60)),
                (delta: 500, cumulative: 1500, at: Self.at(210)),
            ])

        let today = await meter()

        XCTAssertEqual(today.totalTokens, 1500)
    }

    /// The other half of that rule, and the reason it reads the total rather
    /// than the block: two turns can legitimately cost exactly the same, and
    /// deduplicating on what a turn reports would bill the second as a copy of
    /// the first.
    func testTwoIdenticalTurnsAreBothBilledWhenTheTotalMoves() async throws {
        try write(
            "one.jsonl",
            events: [
                (delta: 500, cumulative: 500, at: Self.at(0)),
                (delta: 500, cumulative: 1000, at: Self.at(60)),
            ])

        let today = await meter()

        XCTAssertEqual(today.totalTokens, 1000)
    }

    /// A forked conversation opens with its parent's whole history, written in
    /// one burst at creation and stamped at the session's own start. Those are
    /// turns the parent's rollout already billed.
    func testAForkedSessionDoesNotBillTheHistoryItCopied() async throws {
        try write(
            "fork.jsonl",
            startedAt: Self.at(1800),
            parent: ["forked_from_id": "parent-xyz"],
            events: [
                (delta: 1000, cumulative: 1000, at: Self.at(1800.001)),
                (delta: 2000, cumulative: 3000, at: Self.at(1800.001)),
                (delta: 700, cumulative: 3700, at: Self.at(1844)),
            ])

        let today = await meter()

        XCTAssertEqual(today.totalTokens, 700, "the copied history was billed a second time")
    }

    /// Codex's other way of opening a session from another one. Same copy,
    /// different key, and the row has to answer for both.
    func testASpawnedSubagentDoesNotBillItsParentsHistoryEither() async throws {
        try write(
            "subagent.jsonl",
            startedAt: Self.at(1800),
            parent: ["source": ["subagent": ["thread_spawn": ["parent_thread_id": "parent-xyz"]]]],
            events: [
                (delta: 1000, cumulative: 1000, at: Self.at(1800.002)),
                (delta: 900, cumulative: 1900, at: Self.at(1870)),
            ])

        let today = await meter()

        XCTAssertEqual(today.totalTokens, 900)
    }

    /// And the gate that keeps the rule off everything else: a session that
    /// names no parent copied nothing, however fast its first turns came back.
    /// Without the gate this took real turns off two days of the archive.
    func testASessionThatNamesNoParentKeepsItsOpeningTurns() async throws {
        try write(
            "own.jsonl",
            startedAt: Self.at(1800),
            events: [
                (delta: 1000, cumulative: 1000, at: Self.at(1800.001)),
                (delta: 2000, cumulative: 3000, at: Self.at(1800.001)),
            ])

        let today = await meter()

        XCTAssertEqual(today.totalTokens, 3000)
    }

    /// The bookkeeping both rules need has to outlive the process, because the
    /// re-emitted turn lands after the one it repeats and a relaunch can fall
    /// between them. A reader resuming with no memory of the running total
    /// bills the repeat.
    func testARepeatThatStraddlesARelaunchIsStillBilledOnce() async throws {
        try write(
            "one.jsonl",
            events: [
                (delta: 1000, cumulative: 1000, at: Self.at(0)),
                (delta: 500, cumulative: 1500, at: Self.at(60)),
            ])
        let first = await meter()
        XCTAssertEqual(first.totalTokens, 1500)

        try append(
            "one.jsonl", events: [(delta: 500, cumulative: 1500, at: Self.at(210))])
        let second = await meter()

        XCTAssertEqual(second.totalTokens, 1500, "the repeat was billed by the reader that resumed")
    }

    // MARK: Fixtures

    /// One tail over the tree, persisting where a relaunch would look, so a
    /// second call resumes the way the app does rather than starting clean.
    private func meter() async -> DayTotals {
        let provider = LocalUsageProvider.codex(
            codexDir: sessionsDir,
            retainDays: 2,
            pollInterval: .seconds(60),
            persistenceURL: UsageStatePersistence.forProvider(ProviderID.codex, in: stateDir),
            ledger: ProjectLedger(url: ProjectLedger.defaultURL(in: stateDir))
        )
        await provider.start { _ in }
        let today = await provider.current()
        await provider.stop()
        return today
    }

    private typealias Event = (delta: Int, cumulative: Int, at: String)

    /// A fixture stamp, on the day the reader will actually ask about.
    ///
    /// `current()` answers for today, so a rollout stamped with the date these
    /// tests were written passes on that date and on no other — which is what
    /// happened the morning after. The offset is seconds from 10:00 local, so
    /// every interval the rules turn on — the one-second replay window, the two
    /// events a millisecond apart — is preserved exactly.
    private static func at(_ offset: TimeInterval) -> String {
        let base = Calendar.current.startOfDay(for: Date()).addingTimeInterval(10 * 3600)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: base.addingTimeInterval(offset))
    }

    private func write(
        _ name: String,
        startedAt: String = CodexReplayedTurnsTests.at(-60),
        parent: [String: Any] = [:],
        events: [Event]
    ) throws {
        var payload: [String: Any] = ["id": UUID().uuidString, "cwd": root.path]
        payload.merge(parent) { _, new in new }
        let meta: [String: Any] = [
            "type": "session_meta", "timestamp": startedAt, "payload": payload,
        ]
        var lines = [String(decoding: try JSONSerialization.data(withJSONObject: meta), as: UTF8.self)]
        let context: [String: Any] = [
            "type": "turn_context", "timestamp": startedAt,
            "payload": ["model": "gpt-5-codex"],
        ]
        lines.append(
            String(decoding: try JSONSerialization.data(withJSONObject: context), as: UTF8.self))
        lines.append(contentsOf: try events.map(line(for:)))
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: sessionsDir.appendingPathComponent(name))
    }

    private func append(_ name: String, events: [Event]) throws {
        let url = sessionsDir.appendingPathComponent(name)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((try events.map(line(for:)).joined() + "\n").utf8))
    }

    /// A `token_count` as Codex writes one: the turn's own block beside the
    /// running total it left the session at.
    private func line(for event: Event) throws -> String {
        let object: [String: Any] = [
            "type": "event_msg", "timestamp": event.at,
            "payload": [
                "type": "token_count",
                "info": [
                    "last_token_usage": [
                        "input_tokens": event.delta, "cached_input_tokens": 0,
                        "output_tokens": 0, "total_tokens": event.delta,
                    ],
                    "total_token_usage": [
                        "input_tokens": event.cumulative, "cached_input_tokens": 0,
                        "output_tokens": 0, "total_tokens": event.cumulative,
                    ],
                ],
            ],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
