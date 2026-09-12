import XCTest

@testable import Sissy

/// What the tail puts in the archive, driven through a real tree and the real
/// Claude Code adapter — the archive's whole value is that it agrees with what
/// was metered, which a stubbed provider could not show.
///
/// The case each of these pins is a relaunch: the tail resumes from byte
/// offsets, so whatever it does not carry across a restart it never re-reads.
final class UsageHistoryTailTests: XCTestCase {
    private var logDir: URL!
    private var stateDir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-history-tail-\(UUID().uuidString)")
        logDir = base.appendingPathComponent("logs")
        stateDir = base.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: logDir.deletingLastPathComponent())
    }

    private static let tokensPerTurn = 1_000_000
    private static let model = "claude-sonnet-4-6"
    private static let otherModel = "claude-opus-4-1"

    private var today: String {
        UsageReaderShared.dayFormatter.string(from: Date())
    }

    private func writeTurn(
        _ name: String, requestId: String, at when: Date = Date(), in url: URL? = nil,
        model: String = UsageHistoryTailTests.model
    ) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let line = """
            {"type":"assistant","timestamp":"\(iso.string(from: when))",\
            "requestId":"\(requestId)","message":{"model":"\(model)",\
            "usage":{"input_tokens":\(Self.tokensPerTurn),"output_tokens":0,\
            "cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
            """
        try (line + "\n").write(
            to: url ?? logDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Places a turn in the watched tree from a child process. The tail arms
    /// its FSEvents stream with `IgnoreSelf`, so a file this process writes
    /// itself raises no event and the watcher path stays unreachable from a
    /// test — which is the path a straggler turn actually arrives on.
    private func writeTurnFromAnotherProcess(
        _ name: String, requestId: String, at when: Date
    ) throws {
        let staging = logDir.deletingLastPathComponent()
            .appendingPathComponent("staging-\(name)")
        try writeTurn(staging.lastPathComponent, requestId: requestId, at: when, in: staging)
        let copy = Process()
        copy.executableURL = URL(fileURLWithPath: "/bin/cp")
        copy.arguments = [staging.path, logDir.appendingPathComponent(name).path]
        try copy.run()
        copy.waitUntilExit()
        XCTAssertEqual(copy.terminationStatus, 0, "the straggler turn was never placed")
    }

    /// `historyRoot: nil` is a tail that meters without archiving, which is
    /// what every install looked like before the archive shipped.
    private func runTail(archiving: Bool) async throws {
        let provider = LocalUsageProvider.claudeCode(
            claudeDir: logDir,
            retainDays: 2,
            pollInterval: .seconds(60),
            persistenceURL: UsageStatePersistence.defaultURL(in: stateDir),
            historyRoot: archiving ? stateDir : nil
        )
        await provider.start { _, _ in }
        await provider.stop()
    }

    private func archivedToday() -> UsageHistoryDay? { archived(today) }

    func testATailWritesTheDayItMeteredAsARowPerModel() async throws {
        try writeTurn("a.jsonl", requestId: "r1")

        try await runTail(archiving: true)

        let day = try XCTUnwrap(archivedToday())
        XCTAssertEqual(day.models.count, 1)
        XCTAssertEqual(day.models.first?.model, Self.model)
        XCTAssertEqual(day.models.first?.inputTokens, Self.tokensPerTurn)
        XCTAssertGreaterThan(Decimal(string: day.models.first?.cost ?? "0") ?? 0, 0)
    }

    /// A resumed tail re-reads nothing it has already consumed, so a day it
    /// restarts from zero is a day that loses everything before the relaunch.
    func testARelaunchContinuesTheDayInsteadOfRestartingIt() async throws {
        try writeTurn("a.jsonl", requestId: "r1")
        try await runTail(archiving: true)

        try writeTurn("b.jsonl", requestId: "r2")
        try await runTail(archiving: true)

        let day = try XCTUnwrap(archivedToday())
        XCTAssertEqual(
            day.models.first?.inputTokens, Self.tokensPerTurn * 2,
            "the second run wrote the day it could see rather than the day that happened")
    }

    /// The first launch after the archive shipped: offsets resume at the end
    /// of files whose events were never archived, so a day written from there
    /// would count from the upgrade onwards and freeze that as the day. A day
    /// Sissy cannot vouch for is a day it does not write.
    func testADayTheArchiveNeverSawIsLeftUnwrittenRatherThanUndercounted() async throws {
        try writeTurn("a.jsonl", requestId: "r1")
        try await runTail(archiving: false)

        try writeTurn("b.jsonl", requestId: "r2")
        try await runTail(archiving: true)

        XCTAssertNil(
            archivedToday(),
            "a resumed day was archived with only what came after the upgrade")
    }

    /// The delete button is the one place Sissy forgets something on purpose,
    /// and the tail is still holding the days it just deleted. A straggler
    /// event stamped yesterday — the minutes after midnight are full of them —
    /// must not put yesterday back.
    ///
    /// Driven through the FSEvents watcher the tail arms on `start`, because
    /// the rewrite it guards against needs a real ingest after the deletion,
    /// and the only thing that ingests between polls is a file landing in the
    /// tree.
    func testADeletedDayIsNotRewrittenByAnEventThatStillBelongsToIt() async throws {
        let yesterday = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: -1, to: Date()))
        let yesterdayKey = UsageReaderShared.dayFormatter.string(from: yesterday)
        try writeTurn("a.jsonl", requestId: "r1", at: yesterday)
        let provider = LocalUsageProvider.claudeCode(
            claudeDir: logDir,
            retainDays: 2,
            pollInterval: .seconds(60),
            persistenceURL: nil,
            historyRoot: stateDir
        )
        let emits = EmitCounter()
        await provider.start { _, _ in emits.record() }
        XCTAssertNotNil(
            UsageHistoryStore.load(
                provider: ProviderID.claudeCode, day: yesterdayKey, in: stateDir),
            "the day this test deletes was never archived")

        try UsageHistoryStore.removeAll(in: stateDir)
        await provider.forgetArchivedDays()
        let straggler = emits.expectation(forCount: emits.count + 1)
        try writeTurnFromAnotherProcess("b.jsonl", requestId: "r2", at: yesterday)
        await fulfillment(of: [straggler], timeout: 10)
        await provider.stop()

        XCTAssertNil(
            UsageHistoryStore.load(
                provider: ProviderID.claudeCode, day: yesterdayKey, in: stateDir),
            "a deleted day came back")
    }

    /// The retain window is a rolling 48 hours, so the oldest day a cold scan
    /// reaches begins at whatever time of day the scan runs. Freezing that
    /// fraction as the day is the one way this archive can be permanently
    /// wrong about a day that is over.
    func testTheDayAColdScanOnlySeesPartOfIsNotArchived() async throws {
        let cutoff = Date().addingTimeInterval(-2 * 86400)
        let cutoffDay = Calendar.current.startOfDay(for: cutoff)
        let endOfCutoffDay = cutoffDay.addingTimeInterval(86400)
        let insideTheCutOffDay = cutoff.addingTimeInterval(
            endOfCutoffDay.timeIntervalSince(cutoff) / 2)
        try writeTurn("a.jsonl", requestId: "r1", at: insideTheCutOffDay)
        try writeTurn("b.jsonl", requestId: "r2")

        try await runTail(archiving: true)

        XCTAssertNil(
            UsageHistoryStore.load(
                provider: ProviderID.claudeCode,
                day: UsageReaderShared.dayFormatter.string(from: cutoffDay),
                in: stateDir
            ),
            "a day the scan saw only part of was frozen as the whole day")
        XCTAssertNotNil(archivedToday(), "the scan archived nothing at all")
    }

    /// The archive and the snapshot are written under their own throttles and
    /// either can fail on its own, so a relaunch meets a day file that is
    /// behind the offsets beside it — everything between the two is already
    /// consumed and will never be re-read. The day is seeded from the
    /// snapshot, not from the file, so the file is rewritten to the moment the
    /// offsets describe rather than continued from where it was left.
    func testARelaunchRewritesADayFileLeftBehindByTheLastFlush() async throws {
        try writeTurn("a.jsonl", requestId: "r1")
        try await runTail(archiving: true)
        try forgeArchivedToday(inputTokens: 1)

        try await runTail(archiving: true)

        XCTAssertEqual(
            archivedToday()?.models.first?.inputTokens, Self.tokensPerTurn,
            "a day file behind the offsets was accepted instead of rewritten")
    }

    /// The same pair the other way round, which is what a failed snapshot
    /// write leaves: a day file holding events the offsets have not recorded
    /// consuming. Re-reading them has to land on the day that happened rather
    /// than on top of what the file already claimed.
    func testARelaunchDoesNotAddReplayedEventsOnTopOfWhatTheDayFileHolds()
        async throws
    {
        try writeTurn("a.jsonl", requestId: "r1")
        try await runTail(archiving: true)
        try forgeArchivedToday(inputTokens: Self.tokensPerTurn * 2)

        try writeTurn("b.jsonl", requestId: "r2")
        try await runTail(archiving: true)

        XCTAssertEqual(
            archivedToday()?.models.first?.inputTokens, Self.tokensPerTurn * 2,
            "the replayed turn was counted on top of a day file that was ahead")
    }

    /// A cold scan derives a past day from the tree as it stands now, and the
    /// commonest reason a snapshot goes stale is a session log that is no
    /// longer there. What it derives is then short, the day is past, and
    /// nothing will ever grow it back — so the archive keeps what the run that
    /// could still see the whole day wrote.
    func testAColdScanDoesNotReplaceAnArchivedDayWithAShorterReading() async throws {
        let yesterday = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: -1, to: Date()))
        let yesterdayKey = UsageReaderShared.dayFormatter.string(from: yesterday)
        try writeTurn("a.jsonl", requestId: "r1", at: yesterday)
        try writeTurn("b.jsonl", requestId: "r2", at: yesterday)
        try await runTail(archiving: true)
        XCTAssertEqual(
            archived(yesterdayKey)?.models.first?.inputTokens, Self.tokensPerTurn * 2,
            "the day this test re-derives was never archived whole")

        try FileManager.default.removeItem(at: logDir.appendingPathComponent("a.jsonl"))
        try await runTail(archiving: true)

        XCTAssertEqual(
            archived(yesterdayKey)?.models.first?.inputTokens, Self.tokensPerTurn * 2,
            "a scan that could see half of a past day froze that half as the day")
    }

    /// Switching the archive off and back on leaves a file an earlier run
    /// wrote for a day that went on being metered without it. The day cannot
    /// be rebuilt — the rows it would need are exactly what a suppressed day
    /// has none of — and a week that quietly counts a fraction of a day is
    /// worse than one that says the day is missing.
    func testADayLeftShortByATailThatStoppedArchivingIsDropped() async throws {
        try writeTurn("a.jsonl", requestId: "r1")
        try await runTail(archiving: true)
        XCTAssertNotNil(archivedToday(), "the day this test drops was never archived")

        try writeTurn("b.jsonl", requestId: "r2")
        try await runTail(archiving: false)
        try await runTail(archiving: true)

        XCTAssertNil(archivedToday(), "a day known to be short was left in the archive")
    }

    /// The aggregate a day adds up to is not what "at least as complete"
    /// means. A scan that can no longer see one model's session log, on a day
    /// where another model went on spending past what the whole day held, adds
    /// up to more than the file and knows less than it — so the file stays.
    func testAColdScanThatLostAModelDoesNotReplaceTheDayByOutspendingItOnAnother()
        async throws
    {
        let yesterday = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: -1, to: Date()))
        let yesterdayKey = UsageReaderShared.dayFormatter.string(from: yesterday)
        try writeTurn("opus.jsonl", requestId: "r1", at: yesterday, model: Self.otherModel)
        try writeTurn("sonnet.jsonl", requestId: "r2", at: yesterday)
        try await runTail(archiving: true)
        XCTAssertEqual(
            archived(yesterdayKey)?.models.count, 2,
            "the day this test re-derives was never archived with both models")

        try FileManager.default.removeItem(at: logDir.appendingPathComponent("opus.jsonl"))
        try writeTurn("sonnet-more.jsonl", requestId: "r3", at: yesterday)
        try writeTurn("sonnet-yet-more.jsonl", requestId: "r4", at: yesterday)
        try await runTail(archiving: true)

        let day = try XCTUnwrap(archived(yesterdayKey))
        XCTAssertEqual(
            day.models.count, 2,
            "a scan that outspent the day on one model dropped the model it could not see")
        XCTAssertEqual(
            day.totals(forModel: Self.otherModel).inputTokens, Self.tokensPerTurn,
            "the model whose log was gone lost the tokens the archive already held for it")
    }

    /// A day file this build cannot decode — one a later Sissy wrote, or a
    /// corrupted one — is not a day to be replaced: every reading this build
    /// can offer knows less about it than it holds.
    func testADayFileThisBuildCannotReadIsLeftWhereItIs() async throws {
        let url = UsageHistoryStore.url(provider: ProviderID.claudeCode, day: today, in: stateDir)
        try forgeUnreadableArchivedToday(at: url)
        let before = try Data(contentsOf: url)

        try writeTurn("a.jsonl", requestId: "r1")
        try await runTail(archiving: true)

        XCTAssertEqual(
            try Data(contentsOf: url), before,
            "a day file this build cannot read was overwritten")
    }

    private func archived(_ day: String) -> UsageHistoryDay? {
        UsageHistoryStore.load(provider: ProviderID.claudeCode, day: day, in: stateDir)
    }

    /// Stands in for the flush that never landed: whatever a crash left in the
    /// day file, said in one write.
    private func forgeArchivedToday(inputTokens: Int) throws {
        try UsageHistoryStore.save(
            UsageHistoryDay(
                day: today,
                provider: ProviderID.claudeCode,
                updatedAt: Date(),
                totals: [
                    UsageHistoryRow(model: Self.model, project: nil): UsageHistoryTotals(
                        inputTokens: inputTokens,
                        outputTokens: 0,
                        cacheReadTokens: 0,
                        cacheCreationTokens: 0,
                        cost: 0
                    )
                ]
            ),
            in: stateDir
        )
    }

    /// A day written by a schema this build does not know. Raw JSON rather
    /// than an encoded `UsageHistoryDay`, because the type can only ever write
    /// the version this build is.
    private func forgeUnreadableArchivedToday(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let forged = """
            {"schemaVersion":\(UsageHistoryDay.currentSchemaVersion + 1),\
            "day":"\(today)","provider":"\(ProviderID.claudeCode)",\
            "updatedAt":"2026-01-01T00:00:00Z","models":[]}
            """
        try forged.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Counts provider emits and lets a test wait for the nth, the way
/// `FrameRecorder` does for the engine's frames: an emit arrives on whatever
/// task the tail is running, never on the test's own.
private final class EmitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var emitted = 0
    private var pending: [(count: Int, expectation: XCTestExpectation)] = []

    func record() {
        lock.lock()
        emitted += 1
        let ready = pending.filter { $0.count <= emitted }
        pending.removeAll { $0.count <= emitted }
        lock.unlock()
        ready.forEach { $0.expectation.fulfill() }
    }

    func expectation(forCount count: Int) -> XCTestExpectation {
        let waiting = XCTestExpectation(description: "emit \(count)")
        lock.lock()
        if emitted >= count {
            lock.unlock()
            waiting.fulfill()
            return waiting
        }
        pending.append((count, waiting))
        lock.unlock()
        return waiting
    }

    var count: Int { lock.withLock { emitted } }
}
