import XCTest

@testable import Sissy

/// The wiring between the archive and a frame: which directory the engine
/// hands its tails, what the frame carries back out of it, and what the one
/// button that deletes it leaves behind.
///
/// The store's own rules are covered against files in `UsageHistoryStoreTests`
/// and the tail's in `UsageHistoryTailTests`. What is only reachable here is
/// that the engine points all three at the same place.
final class UsageEngineHistoryTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-engine-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var claudeDir: URL { tempDir.appendingPathComponent("claude") }
    private var codexDir: URL { tempDir.appendingPathComponent("codex") }
    private var configURL: URL { tempDir.appendingPathComponent("server.json") }

    private static let tokensPerTurn = 1_000_000
    private static let archivedTokens = 4_242
    /// How long a test waits for windows that must not arrive. The reader
    /// lands a fixture this size in milliseconds, which is what
    /// `firstFrameWithHistory` waits on, so a second is far past it.
    private static let readerLandingWindow: TimeInterval = 1
    /// How long a test waits for a backfill over a small tree to record itself.
    private static let backfillLandingWindow: TimeInterval = 10

    private func makeEngine(retentionDays: Int? = nil) -> UsageEngine {
        var config = ServerConfig.hermetic(claudeDir: claudeDir, codexDir: codexDir)
        config.providers = ProviderToggles(claudeCode: true, codex: false)
        config.historyRetentionDays = retentionDays
        return UsageEngine(
            config: config,
            configURL: configURL,
            limitsProbe: ClaudeLimitsProbe { _ in .absent },
            claudeAccounts: .inert()
        )
    }

    private func writeClaudeTurn() throws {
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try ClaudeLogFixture.writeTurn(
            to: claudeDir.appendingPathComponent("a.jsonl"), requestId: "r1",
            model: "claude-sonnet-4-6", input: Self.tokensPerTurn)
    }

    private func yesterday() throws -> Date {
        let cal = Calendar.current
        return try XCTUnwrap(cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date())))
    }

    /// A day from before this run, so the rollup has something no live reading
    /// could have produced.
    private func archiveYesterday() throws {
        let yesterday = try yesterday()
        try UsageHistoryStore.save(
            UsageHistoryDay(
                day: UsageReaderShared.dayFormatter.string(from: yesterday),
                provider: ProviderID.claudeCode,
                updatedAt: Date(),
                totals: [
                    UsageHistoryRow(model: "claude-sonnet-4-6", project: nil):
                        UsageHistoryTotals(
                            inputTokens: Self.archivedTokens,
                            outputTokens: 0,
                            cacheReadTokens: 0,
                            cacheCreationTokens: 0,
                            cost: Decimal(string: "1.25") ?? 0
                        )
                ]
            ),
            in: tempDir
        )
    }

    private func firstFrame(from engine: UsageEngine) async throws -> FrameData {
        let frames = FrameRecorder()
        let landed = frames.expectation(forFrameCount: 1)
        await engine.start { frames.record($0) }
        await fulfillment(of: [landed], timeout: 5)
        return try XCTUnwrap(frames.all.last)
    }

    /// The first frame carrying the archive's windows. The rollups are read
    /// off the engine's actor and land a frame after the one they were asked
    /// for on, so the first frame of all carries none.
    private func firstFrameWithHistory(from engine: UsageEngine) async throws -> FrameData {
        let frames = FrameRecorder()
        let landed = frames.expectation(
            "a frame carrying the archive", forNextFrameMatching: { !$0.history.isEmpty })
        await engine.start { frames.record($0) }
        await fulfillment(of: [landed], timeout: 5)
        return try XCTUnwrap(frames.all.last { !$0.history.isEmpty })
    }

    private func archive(dayOffset: Int, project: String?, tokens: Int) throws {
        let cal = Calendar.current
        let date = try XCTUnwrap(
            cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: Date())))
        try UsageHistoryStore.save(
            UsageHistoryDay(
                day: UsageReaderShared.dayFormatter.string(from: date),
                provider: ProviderID.claudeCode,
                updatedAt: Date(),
                totals: [
                    UsageHistoryRow(model: "claude-sonnet-4-6", project: project):
                        UsageHistoryTotals(
                            inputTokens: tokens,
                            outputTokens: 0,
                            cacheReadTokens: 0,
                            cacheCreationTokens: 0,
                            cost: Decimal(string: "1.25") ?? 0
                        )
                ]
            ),
            in: tempDir
        )
    }

    /// The export takes no window where the frame's rollups take four: what
    /// bounds it is retention, and a second bound would mean an export carrying
    /// less than the archive Settings names.
    func testTheExportReachesADayOlderThanTheFramesWindow() throws {
        let widest = try XCTUnwrap(UsagePeriod.thirtyDays.days)
        let old = -(widest + 7)
        try archive(dayOffset: old, project: nil, tokens: 11)
        try archive(dayOffset: 0, project: nil, tokens: 22)
        let engine = makeEngine()

        let days = engine.exportableHistory()

        XCTAssertEqual(days.flatMap { $0.models }.map(\.inputTokens).sorted(), [11, 22])
    }

    /// The archive's own rule, end to end: a persisted path is read through the
    /// resolver before it leaves, so a row an older build wrote for a directory
    /// that is no longer a repository stops claiming one — and keeps its money,
    /// which is the half a migration on disk would have thrown away.
    func testAPathThatIsNoLongerARepositoryLosesItsNameAndKeepsItsMoney() throws {
        let gone = tempDir.appendingPathComponent("deleted-worktree").path
        try archive(dayOffset: 0, project: gone, tokens: 33)
        let engine = makeEngine()

        let rows = engine.exportableHistory().flatMap { $0.models }

        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows.first?.project, "the export named a repository nothing verified")
        XCTAssertEqual(rows.first?.inputTokens, 33, "re-reading the day moved its money")
    }

    /// Every window at once rather than the selected one: the panel's choice is
    /// the app's, and a frame carrying only the period it was last told would
    /// make changing it cost a round trip and a frame's wait.
    func testTheFrameCarriesEveryWindowTheArchiveAnswersFor() async throws {
        try writeClaudeTurn()
        try archiveYesterday()
        let engine = makeEngine()
        addTeardownBlock { await engine.stop() }

        let frame = try await firstFrameWithHistory(from: engine)

        XCTAssertEqual(
            Set(frame.history.keys), Set(UsagePeriod.archived),
            "the frame offered a set of windows the archive does not answer for")
        for period in UsagePeriod.archived {
            XCTAssertEqual(
                frame.history[period]?.tokens, Self.archivedTokens,
                "\(period) did not carry yesterday")
        }
    }

    /// A span is answered off the archive on demand, and not at all while the
    /// archive is switched off: no reading is not a window at zero.
    func testASpanIsReadOnlyWhileTheArchiveIsOn() async throws {
        try archiveYesterday()
        let yesterday = try XCTUnwrap(UsageDaySpan(from: try yesterday(), to: try yesterday()))

        let reading = await makeEngine().historyReading(over: yesterday)
        let switchedOff = await makeEngine(retentionDays: 0).historyReading(over: yesterday)

        XCTAssertEqual(reading?.rollup.tokens, Self.archivedTokens)
        XCTAssertEqual(reading?.days.map(\.tokens), [Self.archivedTokens])
        XCTAssertNil(switchedOff)
    }

    /// A span the archive holds no file inside is answered, and the answer is
    /// an absence rather than a window at zero.
    func testASpanWithNoFileInsideItIsAnAnswerThatHoldsNoReading() async throws {
        try archiveYesterday()
        let cal = Calendar.current
        let weekAgo = try XCTUnwrap(cal.date(byAdding: .day, value: -7, to: try yesterday()))
        let empty = try XCTUnwrap(UsageDaySpan(from: weekAgo, to: weekAgo))

        let answered = await makeEngine().historyReading(over: empty)

        let reading = try XCTUnwrap(answered)

        XCTAssertFalse(reading.hasReading)
        XCTAssertEqual(reading.days, [])
        XCTAssertNil(reading.rollup.earliestDay)
        XCTAssertEqual(reading.rollup.tokens, 0)
    }

    /// Today is never a key: the archive's copy of it is written behind the
    /// tail's flush, so the headline stays on the live totals the frame already
    /// carries rather than going slower the moment today is selected.
    func testTheFrameNeverRollsTodayUpFromTheArchive() async throws {
        try writeClaudeTurn()
        try archiveYesterday()
        let engine = makeEngine()
        addTeardownBlock { await engine.stop() }

        let frame = try await firstFrameWithHistory(from: engine)

        XCTAssertNil(frame.history[.today])
    }

    /// The engine hands its tails the directory beside the config that named
    /// the trees, which is the rule the snapshots already follow. Nothing else
    /// proves the two agree on where that is.
    func testTheEngineArchivesTheDayItsTailsMetered() async throws {
        try writeClaudeTurn()
        let engine = makeEngine()

        _ = try await firstFrame(from: engine)
        await engine.stop()

        let today = UsageHistoryStore.load(
            provider: ProviderID.claudeCode,
            day: UsageReaderShared.dayFormatter.string(from: Date()),
            in: tempDir
        )
        XCTAssertEqual(today?.models.first?.inputTokens, Self.tokensPerTurn)
    }

    /// Today is not what the button deletes — it is still being counted, and
    /// the tails put it back on their next flush. Every day before it is gone,
    /// on disk and on the frame that follows.
    func testDeletingTheArchiveTakesTheDaysBeforeTodayOffTheNextFrame() async throws {
        try writeClaudeTurn()
        try archiveYesterday()
        let engine = makeEngine()
        addTeardownBlock { await engine.stop() }
        let frames = FrameRecorder()
        let archived = try yesterday()
        let landed = frames.expectation(
            "a frame carrying yesterday",
            forNextFrameMatching: { $0.history[.all]?.earliestDay == archived })
        await engine.start { frames.record($0) }
        await fulfillment(of: [landed], timeout: 5)
        let replayed = frames.expectation(forFrameCount: frames.count + 1)

        await engine.deleteHistory()

        await fulfillment(of: [replayed], timeout: 5)
        XCTAssertNotEqual(frames.all.last?.history[.all]?.earliestDay, try yesterday())
        XCTAssertNil(
            UsageHistoryStore.load(
                provider: ProviderID.claudeCode,
                day: UsageReaderShared.dayFormatter.string(from: try yesterday()),
                in: tempDir
            )
        )
    }

    /// Written whether or not a pass was running, and before anything is removed,
    /// so nothing can write a past day back from here on. Today is not named: the
    /// dialog promises it keeps counting, and it is back on disk at the next flush.
    func testADeletionNamesYesterdayAndLeavesTodayCounting() async throws {
        try writeClaudeTurn()
        let engine = makeEngine()
        addTeardownBlock { await engine.stop() }
        let frames = FrameRecorder()
        let landed = frames.expectation(forFrameCount: 1)
        await engine.start { frames.record($0) }
        await fulfillment(of: [landed], timeout: 5)

        await engine.deleteHistory()
        await engine.flush()

        XCTAssertEqual(
            ArchiveBackfillLedger.load(from: ArchiveBackfillLedger.defaultURL(in: tempDir))
                .deletedThrough,
            UsageReaderShared.dayFormatter.string(from: try yesterday()))
        XCTAssertNotNil(
            UsageHistoryStore.load(
                provider: ProviderID.claudeCode,
                day: UsageReaderShared.dayFormatter.string(from: Date()),
                in: tempDir))
    }

    /// Someone deleting history to free a full disk has no room for the date until
    /// the files are gone. The removal here is what clears the way for it.
    func testADeletionTriesTheDateAgainOnceTheFilesAreGone() async throws {
        try writeClaudeTurn()
        let engine = makeEngine()
        addTeardownBlock { await engine.stop() }
        let frames = FrameRecorder()
        let landed = frames.expectation(forFrameCount: 1)
        await engine.start { frames.record($0) }
        await fulfillment(of: [landed], timeout: 5)
        let url = ArchiveBackfillLedger.defaultURL(in: tempDir)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

        await engine.deleteHistory { _ in try FileManager.default.removeItem(at: url) }

        XCTAssertEqual(
            ArchiveBackfillLedger.load(from: url).deletedThrough,
            UsageReaderShared.dayFormatter.string(from: try yesterday()))
    }

    /// With no room for the date even then, the files still go: that is what the
    /// user asked for, and only the promise about later passes is at risk.
    func testADeletionStillRemovesTheFilesWhenTheDateCannotBeSaved() async throws {
        try writeClaudeTurn()
        try archiveYesterday()
        let engine = makeEngine()
        addTeardownBlock { await engine.stop() }
        let frames = FrameRecorder()
        let landed = frames.expectation(forFrameCount: 1)
        await engine.start { frames.record($0) }
        await fulfillment(of: [landed], timeout: 5)
        let url = ArchiveBackfillLedger.defaultURL(in: tempDir)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

        await engine.deleteHistory()

        XCTAssertNil(
            UsageHistoryStore.load(
                provider: ProviderID.claudeCode,
                day: UsageReaderShared.dayFormatter.string(from: try yesterday()),
                in: tempDir))
    }

    /// Zero days is the off switch, and it has to reach both halves: nothing
    /// written, and nothing read back out of what an earlier run wrote. What
    /// it deliberately does not do is delete — that is the button's job, and
    /// a config edit must not take a user's record with it.
    func testARetentionOfZeroDaysArchivesNothingAndReportsNothing() async throws {
        try writeClaudeTurn()
        try archiveYesterday()
        let engine = makeEngine(retentionDays: 0)
        addTeardownBlock { await engine.stop() }
        let frames = FrameRecorder()
        let first = frames.expectation(forFrameCount: 1)
        let windows = frames.expectation(
            "a frame carrying the archive", forNextFrameMatching: { !$0.history.isEmpty })
        windows.isInverted = true

        await engine.start { frames.record($0) }
        await fulfillment(of: [first], timeout: 5)
        await fulfillment(of: [windows], timeout: Self.readerLandingWindow)
        await engine.stop()

        XCTAssertTrue(frames.all.allSatisfy { $0.history.isEmpty })
        XCTAssertNil(
            UsageHistoryStore.load(
                provider: ProviderID.claudeCode,
                day: UsageReaderShared.dayFormatter.string(from: Date()),
                in: tempDir
            ),
            "a day was archived with the archive switched off")
        XCTAssertNotNil(
            UsageHistoryStore.load(
                provider: ProviderID.claudeCode,
                day: UsageReaderShared.dayFormatter.string(from: try yesterday()),
                in: tempDir
            ),
            "switching the archive off deleted what an earlier run had recorded")
    }

    /// The dialog behind the button says today keeps counting, and its file
    /// went with the rest of the archive. A day the tail is still holding has
    /// to be back on disk at the next flush.
    func testDeletingTheArchiveLeavesTodayOnDisk() async throws {
        try writeClaudeTurn()
        let engine = makeEngine()
        _ = try await firstFrame(from: engine)

        await engine.deleteHistory()
        await engine.stop()

        XCTAssertEqual(
            UsageHistoryStore.load(
                provider: ProviderID.claudeCode,
                day: UsageReaderShared.dayFormatter.string(from: Date()),
                in: tempDir
            )?.models.first?.inputTokens,
            Self.tokensPerTurn
        )
    }

    /// One provider's unreadable log withholds that provider's record and
    /// nothing else: a pass over it used to end the loop, so a CLI with a log it
    /// could not read kept the one beside it from ever filling its history in.
    func testAnUnreadableLogLeavesTheNextProvidersPassToRun() async throws {
        let cal = Calendar.current
        let old = try XCTUnwrap(
            cal.date(byAdding: .day, value: -10, to: cal.startOfDay(for: Date()))
        )
        .addingTimeInterval(12 * 60 * 60)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let locked = claudeDir.appendingPathComponent("locked.jsonl")
        try ClaudeLogFixture.writeTurn(
            to: locked, requestId: "r-locked", model: "claude-sonnet-4-6", input: 100, at: old)
        try FileManager.default.setAttributes(
            [.modificationDate: old, .posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: locked.path)
        }
        let rollout = codexDir.appendingPathComponent("rollout-old.jsonl")
        try Self.codexTurn(at: old).write(to: rollout, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: rollout.path)

        var config = ServerConfig.hermetic(claudeDir: claudeDir, codexDir: codexDir)
        config.providers = ProviderToggles(claudeCode: true, codex: true)
        let engine = UsageEngine(
            config: config, configURL: configURL,
            limitsProbe: ClaudeLimitsProbe { _ in .absent }, claudeAccounts: .inert())
        await engine.start { _ in }
        addTeardownBlock { await engine.stop() }

        let ledgerURL = ArchiveBackfillLedger.defaultURL(in: tempDir)
        let deadline = Date().addingTimeInterval(Self.backfillLandingWindow)
        while ArchiveBackfillLedger.load(from: ledgerURL).coverage[ProviderID.codex] == nil,
            Date() < deadline
        {
            try await Task.sleep(for: .milliseconds(20))
        }

        let coverage = ArchiveBackfillLedger.load(from: ledgerURL).coverage
        XCTAssertNotNil(coverage[ProviderID.codex], "the second provider's pass never recorded")
        XCTAssertNil(coverage[ProviderID.claudeCode], "a pass with an unread log was recorded")
        XCTAssertNotNil(
            UsageHistoryStore.load(
                provider: ProviderID.codex, day: UsageReaderShared.dayFormatter.string(from: old),
                in: tempDir),
            "the second provider's day was not archived")
    }

    /// A Mac off for a fortnight comes back with a record, a gap, and a log in
    /// that gap it cannot read. The pass writes no record, the tail then rewrites
    /// its snapshot, and on the next launch the tail's reach was past the window's
    /// end, so nothing ever went back for the log.
    func testAGapThatMetAnUnreadableLogIsReadOnceTheLogCanBe() async throws {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let old = try XCTUnwrap(cal.date(byAdding: .day, value: -10, to: today))
            .addingTimeInterval(12 * 60 * 60)
        let covered = try XCTUnwrap(cal.date(byAdding: .day, value: -20, to: today))
        let window = try XCTUnwrap(
            ArchiveBackfill.window(retentionDays: ServerConfig.defaults.resolvedHistoryRetentionDays))
        let ledgerURL = ArchiveBackfillLedger.defaultURL(in: tempDir)
        try ArchiveBackfillLedger.save(
            ArchiveBackfillLedger().recording(
                provider: ProviderID.claudeCode, covered: window.lowerBound..<covered),
            to: ledgerURL)
        try writeClaudeTurn()
        let name = "locked-\(UUID().uuidString).jsonl"
        let locked = claudeDir.appendingPathComponent(name)
        try ClaudeLogFixture.writeTurn(
            to: locked, requestId: "r-locked", model: "claude-sonnet-4-6", input: 100, at: old)
        try FileManager.default.setAttributes(
            [.modificationDate: old, .posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: locked.path)
        }

        let first = makeEngine()
        await first.start { _ in }
        try await waitFor { LoggedLines.contain(name) }
        await first.stop()
        XCTAssertNotNil(
            ArchiveBackfill.lastMetered(snapshotAt: UsageStatePersistence.defaultURL(in: tempDir)),
            "the tail left no snapshot, so this is not the case being held")

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: locked.path)
        let second = makeEngine()
        await second.start { _ in }
        addTeardownBlock { await second.stop() }
        let day = UsageReaderShared.dayFormatter.string(from: old)
        try await waitFor {
            UsageHistoryStore.load(provider: ProviderID.claudeCode, day: day, in: self.tempDir) != nil
        }
        XCTAssertNotNil(
            UsageHistoryStore.load(provider: ProviderID.claudeCode, day: day, in: tempDir),
            "the log was never read")
        try await waitFor {
            let ledger = ArchiveBackfillLedger.load(from: ledgerURL)
            return ledger.owed.isEmpty && ledger.pending.isEmpty
        }
        XCTAssertEqual(ArchiveBackfillLedger.load(from: ledgerURL).owed, [:], "the span stayed owed")
        XCTAssertEqual(ArchiveBackfillLedger.load(from: ledgerURL).pending, [:])
    }

    /// A delete with no pass running: the span was blocked and nothing was due.
    /// It went back for the deleted days the moment the log could be read.
    func testADeleteForgetsAnOwedSpanWithNoPassRunning() async throws {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let old = try XCTUnwrap(cal.date(byAdding: .day, value: -10, to: today))
            .addingTimeInterval(12 * 60 * 60)
        let window = try XCTUnwrap(
            ArchiveBackfill.window(retentionDays: ServerConfig.defaults.resolvedHistoryRetentionDays))
        try writeClaudeTurn()
        let locked = claudeDir.appendingPathComponent("locked.jsonl")
        try ClaudeLogFixture.writeTurn(
            to: locked, requestId: "r-locked", model: "claude-sonnet-4-6", input: 100, at: old)
        try FileManager.default.setAttributes(
            [.modificationDate: old, .posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: locked.path)
        }
        let ledgerURL = ArchiveBackfillLedger.defaultURL(in: tempDir)
        try ArchiveBackfillLedger.save(
            ArchiveBackfillLedger().owing(
                provider: ProviderID.claudeCode, span: window, unread: [locked.path]),
            to: ledgerURL)

        let first = makeEngine()
        await first.start { _ in }
        await first.deleteHistory()
        await first.stop()

        let ledger = ArchiveBackfillLedger.load(from: ledgerURL)
        XCTAssertEqual(ledger.owed, [:], "the span outlived the delete")
        XCTAssertNotNil(ledger.coverage[ProviderID.claudeCode], "the delete did not record the window")

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: locked.path)
        let second = makeEngine()
        await second.start { _ in }
        addTeardownBlock { await second.stop() }
        try await Task.sleep(for: .seconds(Self.readerLandingWindow))
        XCTAssertNil(
            UsageHistoryStore.load(
                provider: ProviderID.claudeCode, day: UsageReaderShared.dayFormatter.string(from: old),
                in: tempDir),
            "the deleted day came back")
    }

    /// Waits out a detached pass, for as long as a small tree could take.
    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(Self.backfillLandingWindow)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A `token_count` line as Codex writes one.
    private static func codexTurn(at when: Date) throws -> String {
        let stamp = ISO8601DateFormatter().string(from: when)
        let usage: [String: Int] = [
            "input_tokens": 100, "cached_input_tokens": 0, "output_tokens": 0, "total_tokens": 100,
        ]
        let line: [String: Any] = [
            "type": "event_msg", "timestamp": stamp,
            "payload": [
                "type": "token_count",
                "info": ["last_token_usage": usage, "total_token_usage": usage],
            ],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: line), as: UTF8.self) + "\n"
    }

    /// The backfill is a second writer to the archive and is not the
    /// aggregator's, so a deletion has to end it rather than only tell the
    /// providers to forget — and has to record it as covered, or the next
    /// launch goes back for the days that were just deleted.
    func testDeletingTheArchiveStopsTheBackfillComingBackForIt() async throws {
        try writeClaudeTurn()
        let engine = makeEngine()
        _ = try await firstFrame(from: engine)

        await engine.deleteHistory()
        await engine.stop()

        let ledger = ArchiveBackfillLedger.load(
            from: ArchiveBackfillLedger.defaultURL(in: tempDir))
        let window = try XCTUnwrap(ArchiveBackfill.window(retentionDays: 90))
        XCTAssertNil(
            ArchiveBackfill.uncovered(
                window, coverage: ledger.coverage[ProviderID.claudeCode],
                meteredThrough: Date()),
            "a deletion the next launch undoes is a deletion that did not happen")
    }

    /// Retention is the engine's to enforce because a provider switched off is
    /// never built, and the days it recorded are still in the archive. Nothing
    /// but the engine walks a directory whose tail is not running.
    func testRetentionReachesTheDaysOfAProviderThatIsNotRunning() async throws {
        try writeClaudeTurn()
        let staleDay = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: -30, to: Date()))
        try UsageHistoryStore.save(
            UsageHistoryDay(
                day: UsageReaderShared.dayFormatter.string(from: staleDay),
                provider: ProviderID.codex,
                updatedAt: Date(),
                totals: [
                    UsageHistoryRow(model: "gpt-5", project: nil):
                        UsageHistoryTotals(inputTokens: 10, cost: 1)
                ]
            ),
            in: tempDir
        )
        let engine = makeEngine(retentionDays: 7)
        addTeardownBlock { await engine.stop() }

        _ = try await firstFrame(from: engine)

        XCTAssertNil(
            UsageHistoryStore.load(
                provider: ProviderID.codex,
                day: UsageReaderShared.dayFormatter.string(from: staleDay),
                in: tempDir
            ),
            "a day past retention survived because its provider was switched off")
    }
}
