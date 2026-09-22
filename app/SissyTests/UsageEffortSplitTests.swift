import XCTest

@testable import Sissy

/// At what effort a day's turns ran: what the two adapters read off the lines
/// they already parse, and what the archive keeps of it.
final class UsageEffortSplitTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-effort-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: What the adapters read

    private func line(_ json: String, url: URL) -> SourceLine {
        SourceLine(data: Data(json.utf8), url: url, byteOffset: 0, retainCutoff: .distantPast)
    }

    private func claudeAdapter() -> ClaudeCodeAdapter {
        ClaudeCodeAdapter(
            claudeDir: root.appendingPathComponent("claude"),
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
            codexDir: root.appendingPathComponent("codex"),
            pricingOverride: nil,
            ledger: ProjectLedger())
    }

    private func assistant(effort: String?, output: Int) -> String {
        let field = effort.map { "\"effort\":\"\($0)\"," } ?? ""
        return """
            {"type":"assistant","sessionId":"s-1","requestId":"req-1",\(field)
            "timestamp":"2026-09-22T10:00:00.000Z","cwd":"/tmp",
            "message":{"id":"m-1","model":"claude-opus-5",
            "usage":{"input_tokens":10,"output_tokens":\(output)}}}
            """
    }

    /// The word is on the line the turn is billed from, so reading it costs no
    /// second parse.
    func testAClaudeTurnCarriesTheEffortItsLineNames() throws {
        let adapter = claudeAdapter()
        var seen: [String: SeenEvent] = [:]
        var activity: [AgentActivityEvent] = []
        let event = adapter.event(
            from: line(assistant(effort: "xhigh", output: 5), url: root),
            seen: &seen, activity: &activity)
        XCTAssertEqual(try XCTUnwrap(event).effort, "xhigh")
    }

    /// Claude Code rewrites an assistant line while the answer streams and
    /// each copy is billed for the output it added. A copy is not a new turn,
    /// but the output it carries was spent at the effort the turn was set at
    /// — so it names the effort and starts no turn.
    func testAStreamedCopyNamesItsEffortAndStartsNoTurn() throws {
        let adapter = claudeAdapter()
        var seen: [String: SeenEvent] = [:]
        var activity: [AgentActivityEvent] = []
        let first = adapter.event(
            from: line(assistant(effort: "xhigh", output: 5), url: root),
            seen: &seen, activity: &activity)
        let second = adapter.event(
            from: line(assistant(effort: "xhigh", output: 11), url: root),
            seen: &seen, activity: &activity)
        XCTAssertEqual(try XCTUnwrap(first).effort, "xhigh")
        XCTAssertTrue(try XCTUnwrap(first).startsTurn)
        XCTAssertEqual(try XCTUnwrap(second).outputTokens, 6)
        XCTAssertEqual(try XCTUnwrap(second).effort, "xhigh")
        XCTAssertFalse(try XCTUnwrap(second).startsTurn)
    }

    /// The whole point of the split naming a streamed copy's effort: what the
    /// block adds up to has to reach the model pill above it. Measured
    /// 2026-09-22 before the fix, the copies' spend went missing — 8.6% of
    /// `claude-sonnet-5` over 14 days.
    func testTheSplitsMoneyReachesTheTurnsOwnTotal() throws {
        let adapter = claudeAdapter()
        var seen: [String: SeenEvent] = [:]
        var activity: [AgentActivityEvent] = []
        var split = EffortTotals()
        var whole = UsageHistoryTotals()
        for output in [5, 11, 40] {
            let event = try XCTUnwrap(
                adapter.event(
                    from: line(assistant(effort: "xhigh", output: output), url: root),
                    seen: &seen, activity: &activity))
            whole.add(event)
            split.record(event)
        }
        XCTAssertEqual(split.turns, 1, "three copies of one turn are one turn")
        XCTAssertEqual(split.totals, whole, "the split lost part of the turn's spend")
    }

    /// A local notice carries no effort, and nothing invents one for it.
    func testAClaudeLineWithNoEffortNamesNone() throws {
        let adapter = claudeAdapter()
        var seen: [String: SeenEvent] = [:]
        var activity: [AgentActivityEvent] = []
        let event = adapter.event(
            from: line(assistant(effort: nil, output: 5), url: root),
            seen: &seen, activity: &activity)
        XCTAssertNil(try XCTUnwrap(event).effort)
    }

    private func turnContext(model: String?, effort: String?) -> String {
        let fields = [model.map { "\"model\":\"\($0)\"" }, effort.map { "\"effort\":\"\($0)\"" }]
            .compactMap { $0 }.joined(separator: ",")
        return """
            {"timestamp":"2026-09-22T10:00:00.000Z","type":"turn_context","payload":{\(fields)}}
            """
    }

    private func tokenCount(input: Int, output: Int, offset: UInt64) -> String {
        """
        {"timestamp":"2026-09-22T10:00:0\(offset)Z","type":"event_msg","payload":
        {"type":"token_count","info":{"last_token_usage":{"input_tokens":\(input),
        "cached_input_tokens":0,"output_tokens":\(output),"total_tokens":\(input + output)},
        "total_token_usage":{"input_tokens":\(input),"cached_input_tokens":0,
        "output_tokens":\(output),"total_tokens":\(input + output)}}}}
        """
    }

    private func codexEvents(_ lines: [String], url: URL) -> [UsageEvent] {
        let adapter = codexAdapter()
        var seen: [String: SeenEvent] = [:]
        var activity: [AgentActivityEvent] = []
        return lines.enumerated().compactMap { index, json in
            adapter.event(
                from: SourceLine(
                    data: Data(json.utf8), url: url, byteOffset: UInt64(index),
                    retainCutoff: .distantPast),
                seen: &seen, activity: &activity)
        }
    }

    /// Codex names the effort beside the model on a `turn_context`, and it
    /// holds for every turn after it until another names a different one.
    func testACodexTurnTakesTheEffortItsTurnContextNamed() {
        let url = root.appendingPathComponent("rollout.jsonl")
        let events = codexEvents(
            [
                turnContext(model: "gpt-5-codex", effort: "medium"),
                tokenCount(input: 10, output: 5, offset: 1),
                turnContext(model: "gpt-5-codex", effort: "high"),
                tokenCount(input: 30, output: 9, offset: 2),
            ], url: url)
        XCTAssertEqual(events.map(\.effort), ["medium", "high"])
    }

    /// A payload naming an effort and no model still names an effort: older
    /// Codex versions wrote no `model` at all.
    func testACodexTurnContextWithNoModelStillNamesItsEffort() {
        let url = root.appendingPathComponent("rollout.jsonl")
        let events = codexEvents(
            [
                turnContext(model: nil, effort: "ultra"),
                tokenCount(input: 10, output: 5, offset: 1),
            ], url: url)
        XCTAssertEqual(events.map(\.effort), ["ultra"])
        XCTAssertEqual(events.map(\.model), [CodexAdapter.defaultModel])
    }

    /// Codex writes far fewer `turn_context` lines than turns, and a resumed
    /// reader is past them: without the persisted word every turn after a
    /// relaunch would name no effort at all.
    func testCodexCarriesTheEffortAcrossARelaunch() throws {
        let url = root.appendingPathComponent("rollout.jsonl")
        let writer = codexAdapter()
        var seen: [String: SeenEvent] = [:]
        var activity: [AgentActivityEvent] = []
        _ = writer.event(
            from: line(turnContext(model: "gpt-5-codex", effort: "high"), url: url),
            seen: &seen, activity: &activity)
        let state = try XCTUnwrap(writer.resumeState())

        let resumed = codexAdapter()
        XCTAssertTrue(
            resumed.resume(
                from: UsageStateSnapshot(
                    schemaVersion: UsageStateSnapshot.currentSchemaVersion,
                    savedAt: Date(), claudeDataDirHash: "", retainDays: 2, files: [],
                    dailyTotals: [], dedupKeysToday: [], codexResume: state),
                offsets: [url: 0]))
        let event = resumed.event(
            from: SourceLine(
                data: Data(tokenCount(input: 10, output: 5, offset: 1).utf8), url: url,
                byteOffset: 1, retainCutoff: .distantPast),
            seen: &seen, activity: &activity)
        XCTAssertEqual(try XCTUnwrap(event).effort, "high")
    }

    // MARK: What the archive keeps

    private func archived(
        _ day: String, provider: String, effort: [EffortKey: EffortTotals]
    ) -> UsageHistoryDay {
        UsageHistoryDay(
            day: day, provider: provider, updatedAt: Date(),
            totals: [
                UsageHistoryRow(model: "opus", project: nil): UsageHistoryTotals(inputTokens: 100)
            ],
            effort: effort)
    }

    private func pair(
        _ model: String, _ effort: String, turns: Int, cost: String = "1"
    ) -> (EffortKey, EffortTotals) {
        (
            EffortKey(model: model, effort: effort),
            EffortTotals(
                turns: turns,
                totals: UsageHistoryTotals(inputTokens: turns, cost: Decimal(string: cost) ?? 0))
        )
    }

    private func dayKey(_ offset: Int) -> String {
        let cal = Calendar.current
        let date = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date()))!
        return UsageReaderShared.dayFormatter.string(from: date)
    }

    func testTheArchiveRoundTripsTheSplitByModelAndEffort() throws {
        let written = archived(
            dayKey(-1), provider: ProviderID.claudeCode,
            effort: Dictionary(
                uniqueKeysWithValues: [
                    pair("opus", "xhigh", turns: 46, cost: "8.17"),
                    pair("sonnet", "low", turns: 3, cost: "0.04"),
                ]))
        try UsageHistoryStore.save(written, in: root)
        let reread = try XCTUnwrap(
            UsageHistoryStore.load(provider: ProviderID.claudeCode, day: written.day, in: root))
        XCTAssertEqual(reread.effortByKey, written.effortByKey)
        XCTAssertEqual(
            reread.effortByKey[EffortKey(model: "opus", effort: "xhigh")]?.cost,
            Decimal(string: "8.17"))
    }

    /// A day written before the field decodes without one, and `nil` there is
    /// "not measured" rather than "nothing was set".
    func testADayWrittenBeforeTheFieldReadsAsUnmeasured() {
        XCTAssertNil(archived(dayKey(-1), provider: ProviderID.claudeCode, effort: [:]).effort)
    }

    /// Whichever reading counted more turns wins the pair whole: turns, tokens
    /// and money came off one pass, and taking each counter's maximum apart
    /// would publish a combination no reading made.
    func testMergingAPairTakesTheFullerReadingWhole() throws {
        let afternoon = archived(
            dayKey(-1), provider: ProviderID.claudeCode,
            effort: Dictionary(
                uniqueKeysWithValues: [pair("opus", "xhigh", turns: 4, cost: "0.50")]))
        let wholeDay = archived(
            dayKey(-1), provider: ProviderID.claudeCode,
            effort: Dictionary(
                uniqueKeysWithValues: [
                    pair("opus", "xhigh", turns: 30, cost: "8.17"),
                    pair("opus", "high", turns: 1, cost: "0.02"),
                ]))
        let merged = afternoon.merging(counts: nil, effort: wholeDay.effort)
        XCTAssertEqual(
            merged.effortByKey[EffortKey(model: "opus", effort: "xhigh")]?.turns, 30)
        XCTAssertEqual(
            merged.effortByKey[EffortKey(model: "opus", effort: "xhigh")]?.cost,
            Decimal(string: "8.17"))
        XCTAssertEqual(merged.effortByKey[EffortKey(model: "opus", effort: "high")]?.turns, 1)
    }

    /// A pair the reading on disk never saw is added rather than dropped.
    func testMergingKeepsAPairOnlyOneReadingSaw() throws {
        let mine = archived(
            dayKey(-1), provider: ProviderID.claudeCode,
            effort: Dictionary(uniqueKeysWithValues: [pair("opus", "xhigh", turns: 5)]))
        let theirs = archived(
            dayKey(-1), provider: ProviderID.claudeCode,
            effort: Dictionary(uniqueKeysWithValues: [pair("sonnet", "low", turns: 2)]))
        let merged = mine.merging(counts: nil, effort: theirs.effort)
        XCTAssertEqual(merged.effort?.count, 2)
    }

    /// Re-reading a day's paths must not lose what sits beside its rows.
    func testReattributionKeepsTheEffortSplit() throws {
        let written = archived(
            dayKey(-1), provider: ProviderID.claudeCode,
            effort: Dictionary(uniqueKeysWithValues: [pair("opus", "xhigh", turns: 46)]))
        XCTAssertEqual(written.reattributed { _ in nil }.effortByKey, written.effortByKey)
    }

    /// The strip already decodes every day file it draws, so the split rides
    /// the read the bars are drawn from rather than a second one.
    func testTheDaySeriesCarriesTheSplitTheBarsWereReadFrom() throws {
        try UsageHistoryStore.save(
            archived(
                dayKey(-1), provider: ProviderID.claudeCode,
                effort: Dictionary(
                    uniqueKeysWithValues: [pair("opus", "xhigh", turns: 40, cost: "6.00")])),
            in: root)
        let series = UsageHistoryStore.series(
            provider: ProviderID.claudeCode, days: 7, in: root)
        XCTAssertEqual(series.first?.effort.map(\.effort), ["xhigh"])
        XCTAssertEqual(series.first?.effort.first?.turns, 40)
    }

    /// A day with no file contributes nothing rather than a reading of zero.
    func testADayTheArchiveHasNoFileForContributesNoSplit() {
        let series = UsageHistoryStore.series(
            provider: ProviderID.claudeCode, days: 7, in: root)
        XCTAssertTrue(series.isEmpty)
    }
}
