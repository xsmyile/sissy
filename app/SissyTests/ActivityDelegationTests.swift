import XCTest

@testable import Sissy

/// Which turns count as a sub-agent's, against the line shapes both CLIs
/// actually write.
///
/// The answer rides the event rather than a second pass, so these assert on
/// the `UsageEvent` the line was billed from: reading it any other way would
/// parse the same bytes twice.
final class ActivityDelegationTests: XCTestCase {
    private func line(_ json: String, url: URL) -> SourceLine {
        SourceLine(data: Data(json.utf8), url: url, byteOffset: 0, retainCutoff: .distantPast)
    }

    private func claudeAdapter() -> ClaudeCodeAdapter {
        ClaudeCodeAdapter(
            claudeDir: URL(fileURLWithPath: "/tmp/sissy-activity-tests/claude"),
            pricingOverride: nil,
            limitsProbe: nil,
            webSources: LockedValue([]),
            webLinks: LockedValue([:]),
            profile: ClaudeProfileSource(),
            accounts: .inert(),
            ledger: ProjectLedger())
    }

    private func codexAdapter() -> CodexAdapter {
        CodexAdapter(
            codexDir: URL(fileURLWithPath: "/tmp/sissy-activity-tests/codex"),
            pricingOverride: nil,
            ledger: ProjectLedger())
    }

    private func assistant(sidechain: Bool = false) -> String {
        """
        {"type":"assistant","sessionId":"s-1","requestId":"req-\(UUID().uuidString)",
        "timestamp":"2026-09-18T10:00:00.000Z","cwd":"/tmp"\(sidechain ? ",\"isSidechain\":true" : ""),
        "message":{"id":"m-1","model":"claude-opus-5","content":[],
        "usage":{"input_tokens":10,"output_tokens":5}}}
        """
    }

    private func claudeEvent(_ json: String, file: String) -> UsageEvent? {
        var seen: [String: SeenEvent] = [:]
        var activity: [AgentActivityEvent] = []
        return claudeAdapter().event(
            from: line(json, url: URL(fileURLWithPath: file)), seen: &seen, activity: &activity)
    }

    // MARK: Claude Code

    func testATurnOfTheSessionsOwnIsNotDelegated() {
        let event = claudeEvent(assistant(), file: "/tmp/c/proj/s-1.jsonl")
        XCTAssertEqual(event?.delegated, false)
    }

    /// The versions that write a sub-agent into its parent's own file say so
    /// on the line.
    func testASidechainTurnIsDelegated() {
        let event = claudeEvent(assistant(sidechain: true), file: "/tmp/c/proj/s-1.jsonl")
        XCTAssertEqual(event?.delegated, true)
    }

    /// The versions that file a sub-agent's transcript of its own say so by
    /// where the line came from, which is the only answer available on the
    /// ones that write no flag.
    func testATurnFromASubagentTranscriptIsDelegated() {
        let event = claudeEvent(
            assistant(), file: "/tmp/c/proj/s-1/subagents/agent-a1.jsonl")
        XCTAssertEqual(event?.delegated, true)
    }

    // MARK: Codex

    private func rollout(subagent: Bool) -> String {
        """
        {"timestamp":"2026-09-18T07:31:42.643Z","type":"session_meta","payload":\
        {"session_id":"r-1","id":"r-1","cwd":"/tmp"\
        \(subagent ? ",\"source\":{\"subagent\":\"review\"}" : ",\"thread_source\":\"user\"")}}
        """
    }

    /// `total` advances with every real turn: Codex re-emits the previous
    /// block verbatim when a session ends, and a reading whose running total
    /// has not moved is that repeat rather than a turn.
    private func tokenCount(total: Int = 1) -> String {
        """
        {"timestamp":"2026-09-18T07:32:00.000Z","type":"event_msg","payload":\
        {"type":"token_count","info":{"last_token_usage":\
        {"input_tokens":100,"cached_input_tokens":0,"output_tokens":20,"total_tokens":120},\
        "total_token_usage":\
        {"input_tokens":\(100 * total),"cached_input_tokens":0,\
        "output_tokens":\(20 * total),"total_tokens":\(120 * total)}}}}
        """
    }

    private func codexEvent(subagent: Bool, adapter: CodexAdapter? = nil) -> UsageEvent? {
        let adapter = adapter ?? codexAdapter()
        let url = URL(fileURLWithPath: "/tmp/sissy-activity-tests/codex/rollout-r-1.jsonl")
        var seen: [String: SeenEvent] = [:]
        var activity: [AgentActivityEvent] = []
        _ = adapter.event(
            from: line(rollout(subagent: subagent), url: url), seen: &seen, activity: &activity)
        return adapter.event(from: line(tokenCount(), url: url), seen: &seen, activity: &activity)
    }

    func testATurnOfARolloutSomebodyStartedIsNotDelegated() {
        XCTAssertEqual(codexEvent(subagent: false)?.delegated, false)
    }

    func testEveryTurnOfASpawnedRolloutIsDelegated() {
        XCTAssertEqual(codexEvent(subagent: true)?.delegated, true)
    }

    /// Codex says it once, on the `session_meta` a resumed reader is already
    /// past — so without the resume carrying it, a relaunch would report a
    /// spawned rollout's whole remaining day as the session's own work.
    func testTheAnswerSurvivesAResume() throws {
        let url = URL(fileURLWithPath: "/tmp/sissy-activity-tests/codex/rollout-r-1.jsonl")
        let first = codexAdapter()
        _ = codexEvent(subagent: true, adapter: first)
        let resume = try XCTUnwrap(first.resumeState())
        XCTAssertEqual(resume.fileModels.first { $0.path == url.path }?.subagent, true)

        let second = codexAdapter()
        XCTAssertTrue(
            second.resume(
                from: UsageStateSnapshot(
                    schemaVersion: UsageStateSnapshot.currentSchemaVersion,
                    savedAt: Date(),
                    claudeDataDirHash: "",
                    retainDays: 2,
                    files: [],
                    dailyTotals: [],
                    dedupKeysToday: [],
                    historyResume: nil,
                    codexResume: resume,
                    projectCheckouts: nil),
                offsets: [url: 1]))
        var seen: [String: SeenEvent] = [:]
        var activity: [AgentActivityEvent] = []
        let event = second.event(
            from: line(tokenCount(total: 2), url: url), seen: &seen, activity: &activity)
        XCTAssertEqual(event?.delegated, true)
    }
}

/// The shape reaching the archive and coming back, through the real tail.
final class ActivityArchiveRoundTripTests: XCTestCase {
    private var logDir: URL!
    private var stateDir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-activity-\(UUID().uuidString)")
        logDir = base.appendingPathComponent("sessions")
        stateDir = base.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: logDir.deletingLastPathComponent())
    }

    /// Two turns a few minutes apart, so the day has one block of a known
    /// width whatever hour the test runs at.
    private func writeRollout() throws {
        let now = Date()
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let meta = """
            {"timestamp":"\(stamp.string(from: now))","type":"session_meta","payload":\
            {"session_id":"a-1","id":"a-1","cwd":"/tmp","thread_source":"user"}}
            """
        let turns = (0..<2).map { index in
            let at = now.addingTimeInterval(Double(index) * 120)
            return """
                {"timestamp":"\(stamp.string(from: at))","type":"event_msg","payload":\
                {"type":"token_count","info":{"last_token_usage":\
                {"input_tokens":100,"cached_input_tokens":0,"output_tokens":\(20 + index),\
                "total_tokens":\(120 + index)},"total_token_usage":\
                {"input_tokens":\(100 * (index + 1)),"cached_input_tokens":0,\
                "output_tokens":\(20 + index),"total_tokens":\(120 * (index + 1))}}}}
                """
        }
        try (([meta] + turns).joined(separator: "\n") + "\n").write(
            to: logDir.appendingPathComponent("rollout-a-1.jsonl"),
            atomically: true, encoding: .utf8)
    }

    private func runTail() async {
        let provider = LocalUsageProvider.codex(
            codexDir: logDir,
            persistenceURL: stateDir.appendingPathComponent("usage-state-codex.json"),
            historyRoot: stateDir,
            ledger: ProjectLedger(url: stateDir.appendingPathComponent("ledger.json")))
        await provider.start { _ in }
        _ = await provider.current()
        await provider.stop()
    }

    private func archived() -> AgentActivityDay? {
        let day = UsageReaderShared.dayFormatter.string(from: Date())
        return UsageHistoryStore.load(provider: ProviderID.codex, day: day, in: stateDir)?.activity
    }

    func testTheDaysShapeReachesTheArchive() async throws {
        try writeRollout()
        await runTail()
        let shape = try XCTUnwrap(archived(), "the day was archived without its shape")
        XCTAssertEqual(shape.blocks.count, 1)
        XCTAssertEqual(shape.activeMinutes, 3)
    }

    /// The offsets resume at EOF, so the lines the minutes were read from are
    /// lines nothing will read again: without the snapshot carrying them, the
    /// relaunch would write a stub over a whole day.
    func testTheShapeSurvivesARelaunch() async throws {
        try writeRollout()
        await runTail()
        await runTail()
        XCTAssertEqual(archived()?.activeMinutes, 3)
    }
}
