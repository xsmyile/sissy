import XCTest

@testable import Sissy

/// What the tail counts besides tokens, against the line shapes both CLIs
/// actually write.
///
/// The fixtures are trimmed copies of real lines rather than minimal ones: the
/// classification turns on fields a hand-written fixture is free to leave out,
/// and the defect these were written for is exactly that — three Codex
/// versions say "another thread opened this" three different ways.
final class AgentCountingTests: XCTestCase {
    private func line(_ json: String, url: URL, cutoff: Date = .distantPast) -> SourceLine {
        SourceLine(data: Data(json.utf8), url: url, byteOffset: 0, retainCutoff: cutoff)
    }

    private func claudeAdapter() -> ClaudeCodeAdapter {
        ClaudeCodeAdapter(
            claudeDir: URL(fileURLWithPath: "/tmp/sissy-agent-tests/claude"),
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
            codexDir: URL(fileURLWithPath: "/tmp/sissy-agent-tests/codex"),
            pricingOverride: nil,
            ledger: ProjectLedger())
    }

    private func assistant(session: String = "s-1", tools: String = "") -> String {
        """
        {"type":"assistant","sessionId":"\(session)","requestId":"req-1",
        "timestamp":"2026-09-18T10:00:00.000Z","cwd":"/tmp",
        "message":{"id":"m-1","model":"claude-opus-5","content":[\(tools)],
        "usage":{"input_tokens":10,"output_tokens":5}}}
        """
    }

    private func toolUse(_ name: String, id: String) -> String {
        #"{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{}}"#
    }

    private func claudeActivity(
        _ json: String, file: String = "/tmp/sissy-agent-tests/claude/proj/s-1.jsonl",
        cutoff: Date = .distantPast, repeats: Int = 1
    ) -> [AgentActivityEvent] {
        let adapter = claudeAdapter()
        var seen: [String: SeenEvent] = [:]
        var activity: [AgentActivityEvent] = []
        for _ in 0..<repeats {
            _ = adapter.event(
                from: line(json, url: URL(fileURLWithPath: file), cutoff: cutoff),
                seen: &seen, activity: &activity)
        }
        return activity
    }

    private func codexActivity(_ lines: [(String, String)]) -> [AgentActivityEvent] {
        let adapter = codexAdapter()
        var seen: [String: SeenEvent] = [:]
        var activity: [AgentActivityEvent] = []
        for (file, json) in lines {
            _ = adapter.event(
                from: line(
                    json, url: URL(fileURLWithPath: "/tmp/sissy-agent-tests/codex/\(file)")),
                seen: &seen, activity: &activity)
        }
        return activity
    }

    private func rollout(_ payload: String) -> String {
        """
        {"timestamp":"2026-09-18T07:31:42.643Z","type":"session_meta","payload":{\(payload)}}
        """
    }

    // MARK: Claude Code

    func testATurnThatSpawnsTwoAgentsCountsTwoAgentsAndOneSession() {
        let activity = claudeActivity(
            assistant(tools: toolUse("Agent", id: "t1") + "," + toolUse("Agent", id: "t2")))
        XCTAssertEqual(activity.filter { $0.kind == .agentSpawned }.count, 2)
        XCTAssertEqual(activity.filter { $0.kind == .sessionStarted }.count, 1)
    }

    /// Every version before the rename wrote `Task`, and a reader that knows
    /// only the current name reports zero for every day it can still see.
    func testTheToolsFormerNameCountsToo() {
        let activity = claudeActivity(assistant(tools: toolUse("Task", id: "t1")))
        XCTAssertEqual(activity.filter { $0.kind == .agentSpawned }.count, 1)
    }

    /// Claude Code rewrites an assistant line two to four times while the
    /// answer streams. The `tool_use` id is what is stable across the copies.
    func testAStreamedTurnRewrittenFourTimesCountsOneAgent() {
        let activity = claudeActivity(
            assistant(tools: toolUse("Agent", id: "t1")), repeats: 4)
        XCTAssertEqual(activity.filter { $0.kind == .agentSpawned }.count, 1)
        XCTAssertEqual(activity.filter { $0.kind == .sessionStarted }.count, 1)
    }

    /// A sub-agent's transcript is the agent already counted on the turn that
    /// asked for it; counting it here would report every delegation twice.
    func testASubagentTranscriptIsNotASecondSession() {
        let activity = claudeActivity(
            assistant(session: "s-2"),
            file: "/tmp/sissy-agent-tests/claude/proj/s-1/subagents/agent-a1.jsonl")
        XCTAssertTrue(activity.isEmpty)
    }

    func testATurnBeforeTheRetainCutoffCountsNothing() {
        let activity = claudeActivity(
            assistant(tools: toolUse("Agent", id: "t1")),
            cutoff: Date(timeIntervalSince1970: 4_000_000_000))
        XCTAssertTrue(activity.isEmpty)
    }

    // MARK: Codex

    /// Measured 2026-09-18 over 468 rollouts on one machine: 26 name a
    /// `thread_spawn`, 119 the `review` subagent, and 58 answer only on
    /// `thread_source`. A reader that knows one shape misses the rest.
    func testEveryShapeOfASpawnedRolloutCountsAsAnAgent() {
        let shapes = [
            #""source":{"subagent":{"thread_spawn":{"parent_thread_id":"p1","depth":1}}}"#,
            #""source":{"subagent":"review"},"thread_source":"subagent""#,
            #""thread_source":"subagent""#,
        ]
        for (index, shape) in shapes.enumerated() {
            let activity = codexActivity([
                ("sub-\(index).jsonl", rollout(#""session_id":"c-\#(index)","cwd":"/tmp",\#(shape)"#))
            ])
            XCTAssertEqual(
                activity.map(\.kind), [.agentSpawned],
                "shape \(index) was not read as a spawned rollout")
        }
    }

    func testARolloutAPersonStartedCountsAsASession() {
        let activity = codexActivity([
            (
                "user.jsonl",
                rollout(#""session_id":"c-3","cwd":"/tmp","source":"exec","thread_source":"user""#)
            )
        ])
        XCTAssertEqual(activity.map(\.kind), [.sessionStarted])
    }

    /// A spawned rollout's `session_id` and `id` both name the thread that
    /// spawned it, so a ledger keyed on either finds the parent's key already
    /// claimed and drops the agent. Measured 2026-09-18, that cost a whole
    /// day's 8 agents while a fixture carrying an id of its own passed.
    func testASpawnedRolloutWearingItsParentsIDStillCounts() {
        let parent = "01a0b4b9-5b2f-7520-9660-b160b379ae16"
        let activity = codexActivity([
            (
                "rollout-2026-09-18T15-34-01-\(parent).jsonl",
                rollout(
                    #""session_id":"\#(parent)","id":"\#(parent)","cwd":"/tmp","source":"exec","thread_source":"user""#
                )
            ),
            (
                "rollout-2026-09-18T15-34-01-01a0b4b9-5b9c-7663-bc66-7ff22e641ba9.jsonl",
                rollout(
                    #""session_id":"\#(parent)","id":"\#(parent)","cwd":"/tmp","source":{"subagent":"review"},"thread_source":"subagent""#
                )
            ),
        ])
        XCTAssertEqual(activity.map(\.kind), [.sessionStarted, .agentSpawned])
    }

    /// The same rollout read twice — a cold scan re-reading a tree the tail
    /// already walked — counts once.
    func testARolloutReadTwiceCountsOnce() {
        let json = rollout(#""session_id":"c-9","cwd":"/tmp","thread_source":"user""#)
        let activity = codexActivity([("r.jsonl", json), ("r.jsonl", json)])
        XCTAssertEqual(activity.map(\.kind), [.sessionStarted])
    }

    // MARK: Turn duration

    private static let claudeTurnDuration = """
        {"parentUuid":"p","isSidechain":false,"type":"system","subtype":"turn_duration",\
        "durationMs":329844,"messageCount":311,"timestamp":"2026-09-22T21:41:19.239Z",\
        "uuid":"u","isMeta":false,"cwd":"/tmp","sessionId":"s-1"}
        """

    private static let codexTaskComplete = """
        {"timestamp":"2026-09-22T21:38:35.939Z","type":"event_msg","payload":{\
        "type":"task_complete","turn_id":"t","last_agent_message":"done",\
        "started_at":1790112985,"completed_at":1790113115,"duration_ms":130047,\
        "time_to_first_token_ms":4075}}
        """

    private func passesPrefilter(
        _ json: String, _ lineMayCount: (UnsafePointer<UInt8>, Int, Int) -> Bool
    ) -> Bool {
        Array(json.utf8).withUnsafeBufferPointer { lineMayCount($0.baseAddress!, 0, $0.count) }
    }

    /// The line bills nothing, so a prefilter that knew only billing lines
    /// would never hand it to the parse.
    func testTheClaudeTurnLineReachesTheParse() {
        XCTAssertTrue(passesPrefilter(Self.claudeTurnDuration, claudeAdapter().lineMayCount))
    }

    func testAClaudeTurnLineReportsHowLongTheTurnRan() {
        XCTAssertEqual(
            claudeActivity(Self.claudeTurnDuration).map(\.kind),
            [.turnCompleted(milliseconds: 329_844)])
    }

    func testTheCodexTaskLineReachesTheParse() {
        XCTAssertTrue(passesPrefilter(Self.codexTaskComplete, codexAdapter().lineMayCount))
    }

    func testACodexTaskLineReportsHowLongTheTurnRan() {
        XCTAssertEqual(
            codexActivity([("r.jsonl", Self.codexTaskComplete)]).map(\.kind),
            [.turnCompleted(milliseconds: 130_047)])
    }

    /// Two turns on one day keep the longer, and a re-read of the shorter one
    /// cannot take it back.
    func testADayKeepsItsLongestTurnWhateverOrderTheyAreReadIn() {
        var day = AgentActivityDay.none
        day.recordTurn(milliseconds: 90_000)
        day.recordTurn(milliseconds: 20_000)
        day.recordTurn(milliseconds: 90_000)
        XCTAssertEqual(day.longestTurnMilliseconds, 90_000)
    }

    /// A window's longest turn is its longest day's, not their sum.
    func testAWindowsLongestTurnIsTheLongestOfItsDays() {
        var window = ActivityTotals(AgentActivityDay(longestTurnMilliseconds: 40_000))
        window.add(ActivityTotals(AgentActivityDay(longestTurnMilliseconds: 70_000)))
        window.add(ActivityTotals(AgentActivityDay()))
        XCTAssertEqual(window.longestTurnMilliseconds, 70_000)
    }

    /// A day written before turns were timed has no reading, and folding it
    /// in must not invent one of zero.
    func testADayWithNoTimedTurnHasNoLongestTurn() {
        let folded = AgentActivityDay.none.union(.none)
        XCTAssertNil(folded.longestTurnMilliseconds)
        XCTAssertTrue(folded.isEmpty)
    }

    /// The field landed after the archive did, so a day written before it
    /// decodes with no reading rather than failing.
    func testADayWrittenBeforeTurnsWereTimedStillDecodes() throws {
        let old = try JSONEncoder().encode(AgentActivityDay(turns: ActivityMinutes(minutes: [3])))
        let decoded = try JSONDecoder().decode(AgentActivityDay.self, from: old)
        XCTAssertNil(decoded.longestTurnMilliseconds)
        XCTAssertTrue(decoded.turns.contains(3))
    }

    /// A fork replays its parent's turns stamped at its own start, so an old
    /// turn would land on the day of the fork. Only the fork's own turns count.
    func testAForkDoesNotTimeTheTurnsItCopied() {
        let meta = """
            {"timestamp":"2026-09-22T10:00:00.000Z","type":"session_meta",\
            "payload":{"session_id":"f","cwd":"/tmp","forked_from_id":"parent-xyz"}}
            """
        let copied = """
            {"timestamp":"2026-09-22T10:00:00.002Z","type":"event_msg",\
            "payload":{"type":"task_complete","duration_ms":900000}}
            """
        let own = """
            {"timestamp":"2026-09-22T10:05:00.000Z","type":"event_msg",\
            "payload":{"type":"task_complete","duration_ms":30000}}
            """
        let turns = codexActivity([("fork.jsonl", meta), ("fork.jsonl", copied), ("fork.jsonl", own)])
            .filter { $0.kind != .sessionStarted && $0.kind != .agentSpawned }
        XCTAssertEqual(turns.map(\.kind), [.turnCompleted(milliseconds: 30_000)])
    }

    /// The export's minutes columns answer for a day's length, so a day that
    /// holds only a timed turn has no row there rather than a row of zeroes.
    func testADayWithOnlyATimedTurnExportsNoMinutes() {
        let day = UsageHistoryDay(
            day: "2026-09-22", provider: ProviderID.claudeCode, updatedAt: Date(), totals: [:],
            activity: AgentActivityDay(longestTurnMilliseconds: 42_000))
        XCTAssertEqual(
            UsageHistoryExport.activityCSV([day]).split(separator: "\n").count, 1,
            "a day with no minutes wrote a row of zeroes")
    }

    /// Counting a `review` rollout as an agent must not also make it a session
    /// that opens by replaying its parent's turns: measured 2026-09-18, its
    /// first `token_count` lands 0.09 s after `session_meta` and is a real
    /// turn, so widening the replay gate to match would take it off the day.
    func testCountingASpawnedRolloutDoesNotSuppressItsFirstTurn() {
        let payload: [String: Any] = ["source": ["subagent": "review"]]
        XCTAssertTrue(CodexAdapter.isSubagent(payload))
        XCTAssertFalse(CodexAdapter.namesAParentSession(payload))
    }
}

/// The archive's side of the count.
final class AgentCountsArchiveTests: XCTestCase {
    private func day(_ counts: AgentCounts?) -> UsageHistoryDay {
        UsageHistoryDay(
            day: "2026-09-18", provider: ProviderID.claudeCode, updatedAt: Date(),
            totals: [:], agents: counts)
    }

    /// A run that started at noon saw the afternoon's agents and not the
    /// morning's, and writing its number over a whole day would lose the
    /// morning for good.
    func testADayKeepsTheHigherCountWhenAPartialRunRewritesIt() {
        let partial = day(AgentCounts(sessions: 3, agents: 1))
        XCTAssertEqual(
            partial.merging(counts: AgentCounts(sessions: 40, agents: 12)).agents,
            AgentCounts(sessions: 40, agents: 12))
    }

    func testADayCountedByNeitherReadingCarriesNoCountAtAll() {
        XCTAssertNil(day(.none).agents)
        XCTAssertNil(day(nil).agents)
    }

    /// The archive re-reads a day's project paths through the resolver on
    /// every use; the count has nothing to do with paths and must survive it.
    func testReAttributionKeepsTheCount() {
        XCTAssertEqual(
            day(AgentCounts(sessions: 2, agents: 5)).reattributed(by: { $0 }).agents,
            AgentCounts(sessions: 2, agents: 5))
    }
}

/// A day the tail counted but never billed.
///
/// Codex writes a rollout's `session_meta` when it opens, so a session
/// somebody started and never asked anything is one session and no tokens at
/// all. Gated on the token rows, such a day left the dirty set unwritten and
/// was never retried, so its count aged out — and the resume path dropped it
/// again on the way back in.
final class AgentCountWithoutSpendTests: XCTestCase {
    private var logDir: URL!
    private var stateDir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-counts-\(UUID().uuidString)")
        logDir = base.appendingPathComponent("sessions")
        stateDir = base.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: logDir.deletingLastPathComponent())
    }

    /// One rollout, opened and never asked anything.
    private func writeIdleRollout() throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = """
            {"timestamp":"\(stamp)","type":"session_meta","payload":\
            {"session_id":"idle-1","cwd":"/tmp","source":"exec","thread_source":"user"}}
            """
        try (line + "\n").write(
            to: logDir.appendingPathComponent("rollout-idle-1.jsonl"),
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

    private func archivedCounts() -> AgentCounts? {
        let day = UsageReaderShared.dayFormatter.string(from: Date())
        return UsageHistoryStore.load(provider: ProviderID.codex, day: day, in: stateDir)?.agents
    }

    func testASessionThatSpentNothingStillReachesTheArchive() async throws {
        try writeIdleRollout()
        await runTail()
        XCTAssertEqual(
            archivedCounts(), AgentCounts(sessions: 1, agents: 0),
            "a day with a session and no tokens was never written")
    }

    /// The count has to survive the relaunch too: the snapshot carries it, and
    /// the resume must not gate it on token totals that day has none of.
    func testTheCountSurvivesARelaunchThatSpentNothing() async throws {
        try writeIdleRollout()
        await runTail()
        await runTail()
        XCTAssertEqual(
            archivedCounts(), AgentCounts(sessions: 1, agents: 0),
            "the relaunch lost the count of a day it had already written")
    }
}
