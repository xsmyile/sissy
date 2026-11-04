import XCTest

@testable import Sissy

/// The pass that fills the archive in from days the live tail never reached.
///
/// Driven through a real tree and the real Claude Code adapter, for the reason
/// `UsageHistoryTailTests` is: the whole value of a backfilled day is that it
/// agrees with what the tail would have metered, which a stubbed provider
/// could not show.
final class UsageBackfillTests: XCTestCase {
    private var logDir: URL!
    private var stateDir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-backfill-\(UUID().uuidString)")
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
    private static let unpricedModel = "claude-from-a-future-nobody-shipped"
    private static let retentionDays = 30

    private func day(_ offset: Int) throws -> Date {
        let cal = Calendar.current
        return try XCTUnwrap(
            cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date())))
    }

    private func dayKey(_ offset: Int) throws -> String {
        UsageReaderShared.dayFormatter.string(from: try day(offset))
    }

    /// Places one turn in the tree, stamped at noon of the day `offset` days
    /// from today so it cannot drift across a local midnight.
    @discardableResult
    private func writeTurn(
        _ name: String,
        requestId: String,
        dayOffset: Int,
        model: String = UsageBackfillTests.model
    ) throws -> URL {
        let cal = Calendar.current
        let when = try XCTUnwrap(
            cal.date(byAdding: .hour, value: 12, to: try day(dayOffset)))
        let url = logDir.appendingPathComponent(name)
        try ClaudeLogFixture.writeTurn(
            to: url, requestId: requestId, model: model, input: Self.tokensPerTurn, at: when)
        try FileManager.default.setAttributes(
            [.modificationDate: when], ofItemAtPath: url.path)
        return url
    }

    private func runBackfill() async throws -> Int {
        let window = try XCTUnwrap(
            ArchiveBackfill.window(retentionDays: Self.retentionDays))
        let provider = LocalUsageProvider.claudeCode(
            claudeDir: logDir,
            historyRoot: stateDir,
            backfill: window
        )
        return await provider.backfillArchive().written
    }

    private func archived(_ offset: Int) throws -> UsageHistoryDay? {
        UsageHistoryStore.load(
            provider: ProviderID.claudeCode, day: try dayKey(offset), in: stateDir)
    }

    private func runBackfillForOutcome() async throws -> LocalUsageProvider.BackfillOutcome {
        let provider = LocalUsageProvider.claudeCode(
            claudeDir: logDir,
            historyRoot: stateDir,
            backfill: try XCTUnwrap(ArchiveBackfill.window(retentionDays: Self.retentionDays))
        )
        return await provider.backfillArchive()
    }

    func testAPassThatReadEveryLogIsComplete() async throws {
        try writeTurn("old.jsonl", requestId: "r-old", dayOffset: -10)
        let outcome = try await runBackfillForOutcome()
        XCTAssertEqual(outcome, .init(written: 1, unread: []))
    }

    /// A log that would not open was skipped under `try?` and the pass still
    /// ended complete, so its span was recorded covered and never revisited.
    /// The log beside it is still archived; what is withheld is the record.
    func testAnUnreadableLogLeavesThePassIncomplete() async throws {
        try writeTurn("old.jsonl", requestId: "r-old", dayOffset: -10)
        let locked = try writeTurn("locked.jsonl", requestId: "r-locked", dayOffset: -20)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: locked.path)
        }

        let outcome = try await runBackfillForOutcome()

        XCTAssertEqual(outcome.written, 1)
        XCTAssertEqual(outcome.unread.map { URL(fileURLWithPath: $0).lastPathComponent }, ["locked.jsonl"])
        XCTAssertNotNil(try archived(-10))
        XCTAssertNil(try archived(-20))

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: locked.path)
        let retried = try await runBackfillForOutcome()
        XCTAssertEqual(retried.unread, [])
        XCTAssertNotNil(try archived(-20))
    }

    /// A skipped log breaks "newest first proves the day whole": the day goes
    /// out short of its lines, and it is the pass that can read them that puts
    /// them back.
    func testADayWrittenShortOfAnUnreadableLogIsRepairedByTheRetry() async throws {
        let cal = Calendar.current
        let when = try XCTUnwrap(cal.date(byAdding: .hour, value: 12, to: try day(-10)))
        try writeTurn("readable.jsonl", requestId: "r-readable", dayOffset: -10)
        let locked = logDir.appendingPathComponent("locked.jsonl")
        try ClaudeLogFixture.writeTurn(
            to: locked, requestId: "r-locked", model: Self.model, input: Self.tokensPerTurn, at: when)
        try FileManager.default.setAttributes(
            [.modificationDate: try day(-5), .posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: locked.path)
        }

        _ = try await runBackfillForOutcome()
        XCTAssertEqual(try archived(-10)?.totalTokens, Self.tokensPerTurn)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: locked.path)
        _ = try await runBackfillForOutcome()
        XCTAssertEqual(try archived(-10)?.totalTokens, 2 * Self.tokensPerTurn)
    }

    /// A directory the listing cannot enter used to read as one holding nothing,
    /// so the pass reported whole over logs it never saw.
    func testAnUnsearchableDirectoryLeavesThePassIncomplete() async throws {
        let closed = logDir.appendingPathComponent("closed", isDirectory: true)
        try FileManager.default.createDirectory(at: closed, withIntermediateDirectories: true)
        try writeTurn("closed/inner.jsonl", requestId: "r-inner", dayOffset: -10)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: closed.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: closed.path)
        }

        let outcome = try await runBackfillForOutcome()

        XCTAssertEqual(outcome.unread.map { URL(fileURLWithPath: $0).lastPathComponent }, ["closed"])
    }

    /// A directory that lists its names and will not state them: the file is
    /// there, and its mtime is what the listing could not read.
    func testAFileTheListingCannotStateLeavesThePassIncomplete() async throws {
        let closed = logDir.appendingPathComponent("listable", isDirectory: true)
        try FileManager.default.createDirectory(at: closed, withIntermediateDirectories: true)
        try writeTurn("listable/inner.jsonl", requestId: "r-inner", dayOffset: -10)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: closed.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: closed.path)
        }

        let outcome = try await runBackfillForOutcome()

        XCTAssertFalse(outcome.unread.isEmpty, "the pass reported whole over a file it never read")
    }

    /// No tree at all is a CLI with nothing to read rather than one refused.
    func testAMissingTreeIsNotUnread() async throws {
        try FileManager.default.removeItem(at: logDir)
        let outcome = try await runBackfillForOutcome()
        XCTAssertEqual(outcome.unread, [])
    }

    func testAMissingPathIsToldFromARefusedOne() throws {
        let missing = logDir.appendingPathComponent("missing.jsonl")
        XCTAssertThrowsError(try FileHandle(forReadingFrom: missing)) {
            XCTAssertTrue(LocalUsageProvider.saysGone($0))
        }
        XCTAssertThrowsError(try missing.resourceValues(forKeys: [.fileSizeKey])) {
            XCTAssertTrue(LocalUsageProvider.saysGone($0))
        }
        let locked = try writeTurn("locked.jsonl", requestId: "r-locked", dayOffset: -10)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: locked.path)
        }
        XCTAssertThrowsError(try FileHandle(forReadingFrom: locked)) {
            XCTAssertFalse(LocalUsageProvider.saysGone($0))
        }
    }

    // MARK: What a pass owes

    /// The tail's reach past the window's end answered "nothing to do", so a
    /// span a pass finished short of was lost for good.
    func testAnOwedSpanIsAnsweredPastTheTailsReachOnceItCanBeRead() throws {
        let window = try XCTUnwrap(ArchiveBackfill.window(retentionDays: Self.retentionDays))
        let ledger = ArchiveBackfillLedger()
            .recording(provider: ProviderID.claudeCode, covered: try span(-29, -20))
            .owing(
                provider: ProviderID.claudeCode, span: try span(-20, -6),
                unread: ["/logs/locked.jsonl"])
        let coverage = ledger.coverage[ProviderID.claudeCode]
        let owed = try XCTUnwrap(ledger.owed[ProviderID.claudeCode])

        let answered = ArchiveBackfill.uncovered(
            window, coverage: coverage, owed: owed, meteredThrough: Date(), canRead: { _ in true })

        XCTAssertEqual(answered, try day(-20)..<window.upperBound)
        XCTAssertNil(
            ArchiveBackfill.uncovered(window, coverage: coverage, meteredThrough: Date()),
            "without the span the tail's reach answers nothing, which is the case being held")
    }

    /// One log that stays unreadable must not re-read the whole span on every
    /// launch, a first pass included, where no coverage record exists at all.
    func testALogThatStaysUnreadableAsksForNoPass() throws {
        let window = try XCTUnwrap(ArchiveBackfill.window(retentionDays: Self.retentionDays))
        let owed = try XCTUnwrap(
            ArchiveBackfillLedger()
                .owing(provider: ProviderID.claudeCode, span: window, unread: ["/logs/locked.jsonl"])
                .owed[ProviderID.claudeCode])

        XCTAssertNil(
            ArchiveBackfill.uncovered(
                window, coverage: nil, owed: owed, meteredThrough: Date(), canRead: { _ in false }))
        XCTAssertEqual(
            ArchiveBackfill.uncovered(
                window, coverage: nil, owed: owed, meteredThrough: Date(), canRead: { _ in true }),
            window, "the log can be read now")
    }

    /// A span a log is blocking, on a CLI idle past the tail's 48 h: no snapshot,
    /// and the window's end has moved past what the span reached. The first launch
    /// of each day used to read the whole span again, to meet the same log.
    func testWhileBlockedOnlyTheNewGapIsRead() throws {
        let window = try XCTUnwrap(ArchiveBackfill.window(retentionDays: Self.retentionDays))
        let ledger = ArchiveBackfillLedger()
            .recording(provider: ProviderID.claudeCode, covered: try span(-29, -20))
            .owing(
                provider: ProviderID.claudeCode, span: try span(-20, -6),
                unread: ["/logs/locked.jsonl"])

        let answered = ArchiveBackfill.uncovered(
            window, coverage: ledger.coverage[ProviderID.claudeCode],
            owed: ledger.owed[ProviderID.claudeCode], meteredThrough: nil,
            canRead: { _ in false })

        XCTAssertEqual(answered, try day(-6)..<window.upperBound)
    }

    /// A directory named like a log passes `access` and fails at the read, so it
    /// stayed unread and never blocked, which was a full pass on every launch.
    func testADirectoryNamedLikeALogIsNotALog() async throws {
        try FileManager.default.createDirectory(
            at: logDir.appendingPathComponent("named.jsonl", isDirectory: true),
            withIntermediateDirectories: true)
        try writeTurn("old.jsonl", requestId: "r-old", dayOffset: -10)

        let outcome = try await runBackfillForOutcome()

        XCTAssertEqual(outcome, .init(written: 1, unread: []))
    }

    /// `FileManager` does not follow a link for these keys, and a filter on the
    /// link's own type would drop a log that reads perfectly well through it.
    func testALogReachedThroughALinkIsStillRead() async throws {
        let elsewhere = stateDir.appendingPathComponent("elsewhere.jsonl")
        let when = try XCTUnwrap(Calendar.current.date(byAdding: .hour, value: 12, to: try day(-10)))
        try ClaudeLogFixture.writeTurn(
            to: elsewhere, requestId: "r-linked", model: Self.model, input: Self.tokensPerTurn, at: when)
        try FileManager.default.createSymbolicLink(
            at: logDir.appendingPathComponent("linked.jsonl"), withDestinationURL: elsewhere)

        let outcome = try await runBackfillForOutcome()

        XCTAssertEqual(outcome.unread, [])
        XCTAssertEqual(try archived(-10)?.totalTokens, Self.tokensPerTurn)
    }

    /// What a read of a path answers and what a launch asks of it must agree, or
    /// a path one calls unread and the other calls gone runs a pass on every launch.
    func testAPathBelowAFileIsGoneToBothQuestions() throws {
        let file = try writeTurn("old.jsonl", requestId: "r-old", dayOffset: -10)
        let below = file.appendingPathComponent("below.jsonl")

        XCTAssertTrue(ArchiveBackfill.canReadNow(below.path))
        XCTAssertThrowsError(try FileHandle(forReadingFrom: below)) {
            XCTAssertTrue(LocalUsageProvider.saysGone($0))
        }
    }

    func testALogBehindADirectoryThatRefusesToBeSearchedStaysUnreadable() throws {
        let closed = logDir.appendingPathComponent("listable", isDirectory: true)
        try FileManager.default.createDirectory(at: closed, withIntermediateDirectories: true)
        let inner = try writeTurn("listable/inner.jsonl", requestId: "r-inner", dayOffset: -10)
        XCTAssertTrue(ArchiveBackfill.canReadNow(inner.path))
        XCTAssertTrue(ArchiveBackfill.canReadNow(closed.appendingPathComponent("gone.jsonl").path))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: closed.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: closed.path)
        }

        XCTAssertFalse(ArchiveBackfill.canReadNow(inner.path))
    }

    /// A pass that never finished has no log to wait for: a quit or a crash left
    /// it, and it is asked for again past the tail's reach.
    func testAPassCutShortIsAskedForAgain() throws {
        let window = try XCTUnwrap(ArchiveBackfill.window(retentionDays: Self.retentionDays))
        let gap = try span(-20, -6)
        let ledger = ArchiveBackfillLedger()
            .recording(provider: ProviderID.claudeCode, covered: try span(-29, -20))
            .starting(provider: ProviderID.claudeCode, span: gap, window: window)

        XCTAssertEqual(
            ArchiveBackfill.uncovered(
                window, coverage: ledger.coverage[ProviderID.claudeCode],
                pending: ledger.pending[ProviderID.claudeCode], meteredThrough: Date()),
            gap.lowerBound..<window.upperBound)
    }

    /// Cut short beside a blocked span: the gap is asked for again, and only it.
    func testAGapCutShortBesideABlockedSpanIsAskedForAlone() throws {
        let window = try XCTUnwrap(ArchiveBackfill.window(retentionDays: Self.retentionDays))
        let ledger = ArchiveBackfillLedger()
            .recording(provider: ProviderID.claudeCode, covered: try span(-29, -20))
            .owing(
                provider: ProviderID.claudeCode, span: try span(-20, -6),
                unread: ["/logs/locked.jsonl"]
            )
            .starting(provider: ProviderID.claudeCode, span: try span(-6, -3), window: window)

        XCTAssertEqual(
            ArchiveBackfill.uncovered(
                window, coverage: ledger.coverage[ProviderID.claudeCode],
                owed: ledger.owed[ProviderID.claudeCode],
                pending: ledger.pending[ProviderID.claudeCode], meteredThrough: Date(),
                canRead: { _ in false }),
            try day(-6)..<window.upperBound)
    }

    /// A pass over a new gap finishes without having read the blocked span, so
    /// the span stays owed and its logs stay named.
    func testAGapFinishedBesideABlockedSpanLeavesItOwed() throws {
        let window = try XCTUnwrap(ArchiveBackfill.window(retentionDays: Self.retentionDays))
        let owedSpan = try span(-20, -6)
        let unread = ["/logs/locked.jsonl"]
        let ledger = ArchiveBackfillLedger()
            .owing(provider: ProviderID.claudeCode, span: owedSpan, unread: unread)
            .starting(provider: ProviderID.claudeCode, span: try span(-6, -3), window: window)
            .recording(provider: ProviderID.claudeCode, covered: try span(-6, -3))

        XCTAssertEqual(ledger.owed[ProviderID.claudeCode]?.unread, unread)
        XCTAssertEqual(ledger.pending[ProviderID.claudeCode], nil)
    }

    /// A pass reading back across what was owed takes it over: finished, nothing
    /// is owed; cut short, it is pending; short of logs, those are what is owed.
    func testAPassAcrossAnOwedSpanTakesItOver() throws {
        let window = try XCTUnwrap(ArchiveBackfill.window(retentionDays: Self.retentionDays))
        let owedSpan = try span(-20, -6)
        let started = ArchiveBackfillLedger()
            .owing(provider: ProviderID.claudeCode, span: owedSpan, unread: ["/logs/locked.jsonl"])
            .starting(
                provider: ProviderID.claudeCode, span: owedSpan.lowerBound..<window.upperBound,
                window: window)
        XCTAssertNil(started.owed[ProviderID.claudeCode])
        XCTAssertNotNil(started.pending[ProviderID.claudeCode])

        let finished = started.recording(
            provider: ProviderID.claudeCode, covered: owedSpan.lowerBound..<window.upperBound)
        XCTAssertEqual(finished.owed, [:])
        XCTAssertEqual(finished.pending, [:])

        let short = started.owing(
            provider: ProviderID.claudeCode, span: owedSpan.lowerBound..<window.upperBound,
            unread: ["/logs/other.jsonl"])
        XCTAssertEqual(short.owed[ProviderID.claudeCode]?.unread, ["/logs/other.jsonl"])
        XCTAssertEqual(short.pending, [:])
    }

    /// A span reaching further back than retention still ends: the pass starts at
    /// the window's edge, and that has to count as reading back across it, or the
    /// span stayed owed and every launch went back for it.
    func testAnOwedSpanOlderThanTheWindowIsTakenOverAtItsEdge() throws {
        let window = try XCTUnwrap(ArchiveBackfill.window(retentionDays: Self.retentionDays))
        let ledger = ArchiveBackfillLedger()
            .owing(
                provider: ProviderID.claudeCode, span: try span(-60, -6),
                unread: ["/logs/locked.jsonl"]
            )
            .starting(provider: ProviderID.claudeCode, span: window, window: window)

        XCTAssertNil(ledger.owed[ProviderID.claudeCode])
    }

    func testAProvidersUnfinishedPassesLeaveTheOthersAlone() throws {
        let window = try XCTUnwrap(ArchiveBackfill.window(retentionDays: Self.retentionDays))
        let ledger = ArchiveBackfillLedger()
            .starting(provider: ProviderID.claudeCode, span: try span(-20, -15), window: window)
            .starting(provider: ProviderID.codex, span: try span(-20, -15), window: window)
            .recording(provider: ProviderID.claudeCode, covered: try span(-20, -15))

        XCTAssertNil(ledger.pending[ProviderID.claudeCode])
        XCTAssertNotNil(ledger.pending[ProviderID.codex])
    }

    /// A record from before `owed` keeps its coverage, or every install would
    /// pay for a pass over the whole window for a field with nothing in it.
    func testARecordWrittenBeforeOwedStillDecodes() throws {
        let url = stateDir.appendingPathComponent(ArchiveBackfillLedger.fileName)
        let old = """
            {"schemaVersion":\(ArchiveBackfillLedger.currentSchemaVersion),\
            "coverage":{"claude-code":{"from":"2026-01-01","through":"2026-03-01"}}}
            """
        try Data(old.utf8).write(to: url)

        let ledger = ArchiveBackfillLedger.load(from: url)

        XCTAssertEqual(ledger.coverage[ProviderID.claudeCode]?.through, "2026-03-01")
        XCTAssertEqual(ledger.owed, [:])
        XCTAssertEqual(ledger.pending, [:])
    }

    /// The stream only reports what is written after it is armed, so a line
    /// appended to a file the cold scan has already read used to wait out a
    /// whole poll interval.
    func testALineAppendedDuringTheColdScanIsReadWithoutWaitingOutTheInterval() async throws {
        let url = logDir.appendingPathComponent("live.jsonl")
        try ClaudeLogFixture.writeTurn(to: url, requestId: "r-first", model: Self.model, input: 100)
        let appended = LockedValue(false)
        let seen = LockedValue(0)
        let line = ClaudeLogFixture.turnLine(requestId: "r-second", model: Self.model, input: 100)
        let provider = LocalUsageProvider.claudeCode(
            claudeDir: logDir, retainDays: 2, pollInterval: .seconds(3600))
        await provider.start { today in
            seen.store(today.totalTokens)
            var first = false
            appended.update {
                first = !$0
                $0 = true
            }
            guard first, let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        }
        let deadline = Date().addingTimeInterval(5)
        while seen.load() < 200, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        await provider.stop()
        XCTAssertTrue(appended.load(), "the scan published nothing to append from")
        XCTAssertEqual(seen.load(), 200)
    }

    func testTheWindowEndsWhereTheLiveTailsBegins() throws {
        let cal = Calendar.current
        let window = try XCTUnwrap(
            ArchiveBackfill.window(
                retentionDays: Self.retentionDays, liveRetainDays: 2, now: Date(),
                calendar: cal))
        XCTAssertEqual(window.lowerBound, try day(-(Self.retentionDays - 1)))
        XCTAssertEqual(
            window.upperBound, try day(-1),
            "the newest day a pass writes is the one the tail's rolling window cuts in half")
    }

    func testTheWindowStartsWhereRetentionDoes() throws {
        let window = try XCTUnwrap(ArchiveBackfill.window(retentionDays: Self.retentionDays))
        UsageHistoryStore.prune(keeping: Self.retentionDays, in: stateDir)
        XCTAssertEqual(
            window.lowerBound, try day(-(Self.retentionDays - 1)),
            "a pass that reached further back would write a day the next prune deletes")
    }

    func testAnArchiveThatIsSwitchedOffHasNoWindow() {
        XCTAssertNil(ArchiveBackfill.window(retentionDays: 0))
    }

    func testAPassArchivesTheDaysTheTailNeverReached() async throws {
        try writeTurn("old.jsonl", requestId: "r-old", dayOffset: -10)
        try writeTurn("older.jsonl", requestId: "r-older", dayOffset: -20)

        let written = try await runBackfill()
        XCTAssertEqual(written, 2)
        for offset in [-10, -20] {
            let day = try XCTUnwrap(try archived(offset), "day \(offset) was not archived")
            XCTAssertEqual(day.totalTokens, Self.tokensPerTurn)
        }
    }

    func testAPassLeavesTheDaysTheTailOwnsToTheTail() async throws {
        try writeTurn("today.jsonl", requestId: "r-today", dayOffset: 0)
        try writeTurn("yesterday.jsonl", requestId: "r-yesterday", dayOffset: -1)
        try writeTurn("older.jsonl", requestId: "r-older", dayOffset: -3)

        let written = try await runBackfill()
        XCTAssertEqual(written, 1, "only the day outside the tail's window is the pass's to write")
        XCTAssertNil(try archived(0))
        XCTAssertNil(try archived(-1))
        XCTAssertNotNil(try archived(-3))
    }

    func testAPassWritesNoSnapshot() async throws {
        try writeTurn("old.jsonl", requestId: "r-old", dayOffset: -5)
        _ = try await runBackfill()

        let contents = try FileManager.default.contentsOfDirectory(atPath: stateDir.path)
        XCTAssertEqual(
            contents.filter { $0.hasPrefix("usage-state") }, [],
            "the tail resumes from the byte it left off at whether a pass ran or not")
    }

    func testADayHoldingAModelNoRateCoversIsAbsentRatherThanShort() async throws {
        try writeTurn("priced.jsonl", requestId: "r-priced", dayOffset: -6)
        try writeTurn(
            "unpriced.jsonl", requestId: "r-unpriced", dayOffset: -6,
            model: Self.unpricedModel)
        try writeTurn("clean.jsonl", requestId: "r-clean", dayOffset: -7)

        _ = try await runBackfill()
        XCTAssertNil(
            try archived(-6),
            "a day written short is frozen short, and absence is the recoverable answer")
        XCTAssertNotNil(try archived(-7), "the day beside it is unaffected")
    }

    func testAPassRewritesItsOwnDaysWithTheSameNumbers() async throws {
        try writeTurn("old.jsonl", requestId: "r-old", dayOffset: -8)
        _ = try await runBackfill()
        let first = try XCTUnwrap(try archived(-8))

        _ = try await runBackfill()
        let second = try XCTUnwrap(try archived(-8))
        XCTAssertEqual(first.models, second.models, "a whole-day write replaces, never accumulates")
    }

    private func span(_ from: Int, _ through: Int) throws -> Range<Date> {
        try day(from)..<(try day(through))
    }

    func testAnEmptyRecordLeavesTheWholeWindowUncovered() throws {
        let window = try span(-89, -1)
        XCTAssertEqual(
            ArchiveBackfill.uncovered(window, coverage: nil, meteredThrough: nil), window)
    }

    func testAWindowAlreadyCoveredIsNotPassedOverAgain() throws {
        let window = try span(-89, -1)
        let ledger = ArchiveBackfillLedger()
            .recording(provider: ProviderID.claudeCode, covered: window)
        XCTAssertNil(
            ArchiveBackfill.uncovered(
                window, coverage: ledger.coverage[ProviderID.claudeCode],
                meteredThrough: try day(0)))
    }

    /// The correction this rule exists for. A Mac shut for a fortnight comes
    /// back with days the tail's 48 h cannot reach; asking only "has a pass
    /// run" answered no and left them unarchived for good.
    func testAMacThatWasOffLeavesThoseDaysUncovered() throws {
        let ledger = ArchiveBackfillLedger()
            .recording(provider: ProviderID.claudeCode, covered: try span(-103, -15))
        let uncovered = try XCTUnwrap(
            ArchiveBackfill.uncovered(
                try span(-89, -1),
                coverage: ledger.coverage[ProviderID.claudeCode],
                meteredThrough: try day(-14)))
        XCTAssertEqual(uncovered.lowerBound, try day(-14))
        XCTAssertEqual(uncovered.upperBound, try day(-1))
    }

    /// The tail archives every day it runs across, so a relaunch owes nothing
    /// and must not re-read the tree to prove it.
    func testAPlainRelaunchOwesNothing() throws {
        let ledger = ArchiveBackfillLedger()
            .recording(provider: ProviderID.claudeCode, covered: try span(-89, -2))
        XCTAssertNil(
            ArchiveBackfill.uncovered(
                try span(-88, -1),
                coverage: ledger.coverage[ProviderID.claudeCode],
                meteredThrough: try day(-1)))
    }

    func testWideningRetentionAsksForTheWholeWindowAgain() throws {
        let ledger = ArchiveBackfillLedger()
            .recording(provider: ProviderID.claudeCode, covered: try span(-29, -1))
        let window = try span(-89, -1)
        XCTAssertEqual(
            ArchiveBackfill.uncovered(
                window, coverage: ledger.coverage[ProviderID.claudeCode],
                meteredThrough: try day(0)),
            window)
    }

    func testOneProvidersPassSaysNothingAboutAnothers() throws {
        let window = try span(-89, -1)
        let ledger = ArchiveBackfillLedger()
            .recording(provider: ProviderID.claudeCode, covered: window)
        XCTAssertEqual(
            ArchiveBackfill.uncovered(
                window, coverage: ledger.coverage[ProviderID.codex], meteredThrough: try day(0)),
            window)
    }

    /// A top-up pass covers days, not months. Replacing the record with its
    /// span would throw away the history the first pass indexed.
    func testATopUpPassExtendsTheRecordRatherThanReplacingIt() throws {
        let ledger = ArchiveBackfillLedger()
            .recording(provider: ProviderID.claudeCode, covered: try span(-89, -15))
            .recording(provider: ProviderID.claudeCode, covered: try span(-14, -1))
        let coverage = try XCTUnwrap(ledger.coverage[ProviderID.claudeCode])
        XCTAssertEqual(coverage.fromDay, try day(-89))
        XCTAssertEqual(coverage.throughDay, try day(-1))
    }

    /// The tail's window is rolling seconds and the backfill's is calendar
    /// days; derived apart they disagree about which day they meet in across a
    /// daylight-saving boundary, and a day then belongs to both or to neither.
    func testTheWindowEndsOnTheTailsOwnBoundaryAcrossADaylightShift() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Rome"))
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        let now = try XCTUnwrap(formatter.date(from: "2026-10-26T00:30:00+01:00"))
        let window = try XCTUnwrap(
            ArchiveBackfill.window(
                retentionDays: Self.retentionDays, liveRetainDays: 2, now: now,
                calendar: calendar))
        let tailCuts = calendar.startOfDay(
            for: LocalUsageProvider.liveWindowStart(retainDays: 2, now: now))
        XCTAssertEqual(
            window.upperBound, calendar.date(byAdding: .day, value: 1, to: tailCuts),
            "the newest day a pass writes is the one the tail suppresses, whatever the clock did")
    }

    func testTheLedgerRoundTripsThroughDisk() throws {
        let url = ArchiveBackfillLedger.defaultURL(in: stateDir)
        let ledger = ArchiveBackfillLedger()
            .recording(provider: ProviderID.claudeCode, covered: try span(-89, -1))
        try ArchiveBackfillLedger.save(ledger, to: url)
        XCTAssertEqual(ArchiveBackfillLedger.load(from: url), ledger)
    }

    func testALedgerFileThisBuildCannotReadOwesAPass() throws {
        let url = ArchiveBackfillLedger.defaultURL(in: stateDir)
        try Data("{\"schemaVersion\":99,\"coverage\":{}}".utf8).write(to: url)
        XCTAssertNil(ArchiveBackfillLedger.load(from: url).coverage[ProviderID.claudeCode])
    }
}
