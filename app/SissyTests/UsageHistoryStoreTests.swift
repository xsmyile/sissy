import XCTest

@testable import Sissy

/// The archive's own rules, which are about what a day file means rather than
/// about reading a tree: a day is rewritten whole so a re-derivation replaces
/// it, a window reports how far back it actually reaches, and pruning only
/// ever removes days it can name.
final class UsageHistoryStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func day(_ offset: Int, now: Date = Date()) -> String {
        let cal = Calendar.current
        let date = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now))!
        return UsageReaderShared.dayFormatter.string(from: date)
    }

    private func totals(input: Int, cost: String) -> UsageHistoryTotals {
        UsageHistoryTotals(
            inputTokens: input,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            cost: Decimal(string: cost) ?? 0
        )
    }

    /// The day an older build wrote naming a directory that is no longer a
    /// repository. Re-read, the row answers nothing and the day stops
    /// claiming a project Sissy cannot verify.
    func testADayReattributesAPathThatNamesNoRepositoryAnyMore() {
        let stored = day(rows: [
            UsageHistoryRow(model: "opus", project: "/gone"): 100,
            UsageHistoryRow(model: "opus", project: "/live"): 50,
        ])

        let reread = stored.reattributed { $0 == "/live" ? "/live" : nil }

        XCTAssertEqual(reread.totalsByRow[UsageHistoryRow(model: "opus", project: nil)]?.inputTokens, 100)
        XCTAssertEqual(
            reread.totalsByRow[UsageHistoryRow(model: "opus", project: "/live")]?.inputTokens, 50)
        XCTAssertEqual(reread.totalTokens, stored.totalTokens, "re-reading a day moved its money")
    }

    /// A deleted worktree and a subdirectory of it were two rows and answer
    /// one key. Summed, not replaced — otherwise re-reading loses a row.
    func testTwoRowsThatReattributeToOneKeyAreSummed() {
        let stored = day(rows: [
            UsageHistoryRow(model: "opus", project: "/gone"): 100,
            UsageHistoryRow(model: "opus", project: "/gone/app"): 50,
        ])

        let reread = stored.reattributed { _ in nil }

        XCTAssertEqual(reread.models.count, 1)
        XCTAssertEqual(reread.totalsByRow[UsageHistoryRow(model: "opus", project: nil)]?.inputTokens, 150)
    }

    /// The freeze this unblocks: the day on disk names an invented project,
    /// the corrected reading cannot, and held to the stored key it would
    /// refuse the write for good. Re-read first, it covers.
    func testAReattributedDayIsCoveredByTheReadingThatNoLongerNamesTheProject() {
        let stored = day(rows: [UsageHistoryRow(model: "opus", project: "/gone"): 100])
        let reading = day(rows: [UsageHistoryRow(model: "opus", project: nil): 100])

        XCTAssertFalse(stored.isCoveredBy(reading), "the freeze this exists to lift")
        XCTAssertTrue(stored.reattributed { _ in nil }.isCoveredBy(reading))
    }

    /// A repository on an unmounted disk answers nothing while it is away.
    /// The file is never rewritten, so the attribution comes back with it.
    func testAPathThatResolvesAgainKeepsItsRow() {
        let stored = day(rows: [UsageHistoryRow(model: "opus", project: "/vol/repo"): 100])

        let reread = stored.reattributed { $0 }

        XCTAssertEqual(reread.models.map(\.project), ["/vol/repo"])
    }

    /// A file written before the archive carried projects has to be
    /// replaceable by a reading that splits the same model across projects,
    /// or every day on disk freezes on the upgrade.
    func testADayFromBeforeProjectsIsCoveredByAReadingThatSplitsTheModel() {
        let stored = day(rows: [UsageHistoryRow(model: "opus", project: nil): 100])
        let reading = day(rows: [
            UsageHistoryRow(model: "opus", project: "/a"): 60,
            UsageHistoryRow(model: "opus", project: "/b"): 40,
        ])

        XCTAssertTrue(stored.isCoveredBy(reading))
    }

    /// A no-project row is usage Sissy could not attribute, not usage it
    /// counted twice. A re-scan on a machine whose directories are still
    /// there resolves it, and that reading knows more about the day, not
    /// less — it has to be allowed to replace it.
    func testAReadingThatAttributesWhatTheDayCouldNotCoversIt() {
        let stored = day(rows: [
            UsageHistoryRow(model: "opus", project: nil): 100,
            UsageHistoryRow(model: "opus", project: "/a"): 50,
        ])
        let reading = day(rows: [
            UsageHistoryRow(model: "opus", project: "/a"): 100,
            UsageHistoryRow(model: "opus", project: "/b"): 50,
        ])

        XCTAssertTrue(stored.isCoveredBy(reading))
    }

    /// The decision this rule makes on purpose, pinned so it is not made
    /// again by accident: a reading whose model total is unchanged replaces
    /// the day even though its rows are attributed differently. Nothing in
    /// the rows separates "these tokens were resolved" from "these tokens
    /// went and others arrived", and the total is what says the day is not
    /// written short.
    func testAReattributedDayWithTheSameModelTotalIsAccepted() {
        let stored = day(rows: [UsageHistoryRow(model: "opus", project: nil): 100])
        let reading = day(rows: [UsageHistoryRow(model: "opus", project: "/a"): 100])

        XCTAssertTrue(stored.isCoveredBy(reading))
    }

    /// The model's own total is what says something went missing, whatever
    /// the rows it was spread across.
    func testAReadingThatKnowsLessOfAModelDoesNotCoverTheDay() {
        let stored = day(rows: [
            UsageHistoryRow(model: "opus", project: nil): 100,
            UsageHistoryRow(model: "opus", project: "/a"): 50,
        ])
        let reading = day(rows: [UsageHistoryRow(model: "opus", project: "/a"): 120])

        XCTAssertFalse(
            stored.isCoveredBy(reading),
            "a reading 30 tokens short of the model replaced the day")
    }

    /// And the model total alone is not enough: a scan that lost one
    /// project's log while another went on spending sums higher and still
    /// knows less about the one it lost.
    func testAReadingThatLostANamedProjectDoesNotCoverTheDay() {
        let stored = day(rows: [
            UsageHistoryRow(model: "opus", project: "/a"): 100,
            UsageHistoryRow(model: "opus", project: "/b"): 50,
        ])
        let reading = day(rows: [UsageHistoryRow(model: "opus", project: "/b"): 200])

        XCTAssertFalse(
            stored.isCoveredBy(reading),
            "a reading that outspent the day on one project dropped the other")
    }

    func testADayIsCoveredByAReadingThatGrewEveryRow() {
        let stored = day(rows: [
            UsageHistoryRow(model: "opus", project: nil): 100,
            UsageHistoryRow(model: "opus", project: "/a"): 50,
        ])
        let reading = day(rows: [
            UsageHistoryRow(model: "opus", project: nil): 100,
            UsageHistoryRow(model: "opus", project: "/a"): 70,
        ])

        XCTAssertTrue(stored.isCoveredBy(reading))
    }

    private func day(rows: [UsageHistoryRow: Int]) -> UsageHistoryDay {
        UsageHistoryDay(
            day: "2026-09-11",
            provider: ProviderID.claudeCode,
            updatedAt: Date(),
            totals: rows.mapValues { UsageHistoryTotals(inputTokens: $0) }
        )
    }

    private func writeRows(
        provider: String,
        day dayKey: String,
        rows: [UsageHistoryRow: UsageHistoryTotals]
    ) throws {
        try UsageHistoryStore.save(
            UsageHistoryDay(
                day: dayKey, provider: provider, updatedAt: Date(), totals: rows),
            in: root)
    }

    private func write(
        provider: String,
        day dayKey: String,
        models: [String: UsageHistoryTotals]
    ) throws {
        let rows = Dictionary(
            uniqueKeysWithValues: models.map {
                (UsageHistoryRow(model: $0.key, project: nil), $0.value)
            })
        try UsageHistoryStore.save(
            UsageHistoryDay(
                day: dayKey, provider: provider, updatedAt: Date(), totals: rows),
            in: root
        )
    }

    /// The export reads this rather than `rollup`, so it takes no window: what
    /// bounds it is retention, which has already bounded what is on disk. A
    /// second bound here would mean an export quietly carrying less than the
    /// archive the caption names.
    func testEveryDayOnDiskComesBackOrderedByDayThenProvider() throws {
        let models = ["opus": totals(input: 1, cost: "1")]
        try write(provider: "codex", day: day(-40), models: models)
        try write(provider: "claude-code", day: day(-40), models: models)
        try write(provider: "claude-code", day: day(0), models: models)

        let all = UsageHistoryStore.allDays(in: root)

        XCTAssertEqual(
            all.map { [$0.day, $0.provider] },
            [[day(-40), "claude-code"], [day(-40), "codex"], [day(0), "claude-code"]]
        )
    }

    /// A day this build cannot decode is skipped, the answer `load` already
    /// gives — one unreadable file must not cost the user the whole export.
    func testADayThisBuildCannotReadIsSkippedRatherThanFailingTheRead() throws {
        try write(provider: "claude-code", day: day(0), models: ["opus": totals(input: 1, cost: "1")])
        try Data("not json".utf8).write(
            to: UsageHistoryStore.url(provider: "claude-code", day: day(-1), in: root))

        let all = UsageHistoryStore.allDays(in: root)

        XCTAssertEqual(all.map(\.day), [day(0)])
    }

    func testADayComesBackWithTheRowsItWasWrittenWith() throws {
        try write(
            provider: "claude-code",
            day: day(0),
            models: ["claude-sonnet-4-6": totals(input: 1_200, cost: "0.0375")]
        )

        let loaded = UsageHistoryStore.load(provider: "claude-code", day: day(0), in: root)

        XCTAssertEqual(loaded?.models.count, 1)
        XCTAssertEqual(loaded?.models.first?.model, "claude-sonnet-4-6")
        XCTAssertEqual(loaded?.models.first?.inputTokens, 1_200)
        XCTAssertEqual(
            loaded?.totals(forModel: "claude-sonnet-4-6").cost, Decimal(string: "0.0375"),
            "money went through a Double on its way to disk")
    }

    /// The 1-hour cache writes are what a row needs to be priced again from
    /// its counters, so they have to come back from disk as they went in.
    func testADayKeepsItsOneHourCacheWritesApart() throws {
        let written = UsageHistoryTotals(
            inputTokens: 10, outputTokens: 20, cacheReadTokens: 30, cacheCreationTokens: 40,
            cacheCreation1hTokens: 25, cost: 0)
        try write(provider: "claude-code", day: day(0), models: ["claude-opus-5-5": written])

        let loaded = UsageHistoryStore.load(provider: "claude-code", day: day(0), in: root)

        XCTAssertEqual(loaded?.totals(forModel: "claude-opus-5-5"), written)
    }

    /// A day with no 1-hour writes, which is every Codex day, is written
    /// exactly as it was before the field existed.
    func testADayWithNoOneHourCacheWritesOmitsTheField() {
        let stored = UsageHistoryDay(
            day: day(0), provider: "codex", updatedAt: Date(),
            totals: [UsageHistoryRow(model: "gpt-6-sol", project: nil): totals(input: 5, cost: "0")])

        XCTAssertNil(stored.models.first?.cacheCreation1hTokens)
    }

    /// The property the whole design rests on: a cold scan re-derives a day it
    /// has already written, and the second write has to land on the same
    /// number rather than on twice it.
    func testRewritingADayReplacesItRatherThanAddingToIt() throws {
        let models = ["gpt-5": totals(input: 500, cost: "0.10")]
        try write(provider: "codex", day: day(0), models: models)
        try write(provider: "codex", day: day(0), models: models)

        let rollup = try week(in: root)

        XCTAssertEqual(rollup.tokens, 500)
        XCTAssertEqual(rollup.cost, Decimal(string: "0.10"))
    }

    func testTheWindowSumsEveryProviderAndEveryDayInIt() throws {
        try write(provider: "claude-code", day: day(0), models: ["a": totals(input: 10, cost: "1")])
        try write(provider: "claude-code", day: day(-3), models: ["a": totals(input: 20, cost: "2")])
        try write(provider: "codex", day: day(-3), models: ["b": totals(input: 30, cost: "3")])

        let rollup = try week(in: root)

        XCTAssertEqual(rollup.tokens, 60)
        XCTAssertEqual(rollup.cost, Decimal(6))
    }

    func testADayOlderThanTheWindowIsNotCounted() throws {
        try write(provider: "claude-code", day: day(0), models: ["a": totals(input: 10, cost: "1")])
        try write(provider: "claude-code", day: day(-7), models: ["a": totals(input: 99, cost: "9")])

        let rollup = try week(in: root)

        XCTAssertEqual(rollup.tokens, 10, "a day outside the window was rolled up")
    }

    /// The series is one provider's, oldest first, and it stops short of
    /// today: the day file is written on the tail's throttle while the frame
    /// is emitted as events land, so the surface drawing it pairs this with
    /// the slice it already has rather than with a figure that lags.
    func testTheSeriesIsOneProvidersOwnDaysBeforeToday() throws {
        try write(provider: "claude-code", day: day(0), models: ["a": totals(input: 99, cost: "9")])
        try write(provider: "claude-code", day: day(-1), models: ["a": totals(input: 10, cost: "1")])
        try write(provider: "claude-code", day: day(-3), models: ["a": totals(input: 20, cost: "2")])
        try write(provider: "codex", day: day(-1), models: ["b": totals(input: 50, cost: "5")])

        let series = UsageHistoryStore.series(provider: "claude-code", days: 7, in: root)

        XCTAssertEqual(series.map(\.tokens), [20, 10], "today or another provider leaked in")
        XCTAssertEqual(series.map(\.cost), [Decimal(2), Decimal(1)])
    }

    /// The archive keeps a row per model per project; a strip of bars answers
    /// at the day. So the series folds the projects away and one model worked
    /// on in two repositories is one entry, at the sum of both.
    func testTheSeriesFoldsOneModelsProjectsIntoOneEntry() throws {
        try writeRows(
            provider: "claude-code", day: day(-1),
            rows: [
                UsageHistoryRow(model: "claude-opus-5", project: "/a"): totals(input: 300, cost: "3"),
                UsageHistoryRow(model: "claude-opus-5", project: "/b"): totals(input: 100, cost: "1"),
                UsageHistoryRow(model: "claude-sonnet-5", project: "/a"): totals(input: 50, cost: "0.5"),
            ])

        let series = UsageHistoryStore.series(provider: "claude-code", days: 7, in: root)
        let models = try XCTUnwrap(series.first?.models).sorted { $0.cost > $1.cost }

        XCTAssertEqual(models.map(\.model), ["claude-opus-5", "claude-sonnet-5"])
        XCTAssertEqual(models.first?.tokens, 400)
        XCTAssertEqual(models.first?.cost, Decimal(4))
    }

    /// A day outside the window is not the reader's to draw, and a day Sissy
    /// was not running for has no element at all — the gap is what tells a
    /// bar chart it is not looking at a day that cost nothing.
    func testTheSeriesSkipsTheWindowsEdgeAndTheDaysWithNoFile() throws {
        try write(provider: "codex", day: day(-1), models: ["a": totals(input: 10, cost: "1")])
        try write(provider: "codex", day: day(-7), models: ["a": totals(input: 99, cost: "9")])

        let series = UsageHistoryStore.series(provider: "codex", days: 7, in: root)

        XCTAssertEqual(series.count, 1, "a day outside the window was returned")
        XCTAssertEqual(series.first?.tokens, 10)
    }

    /// What stops a two-day-old install from presenting itself as a week.
    func testTheWindowReportsTheEarliestDayItActuallyHolds() throws {
        try write(provider: "codex", day: day(-2), models: ["a": totals(input: 10, cost: "1")])
        try write(provider: "codex", day: day(0), models: ["a": totals(input: 10, cost: "1")])

        let rollup = try week(in: root)

        let expected = Calendar.current.date(
            byAdding: .day, value: -2, to: Calendar.current.startOfDay(for: Date()))
        XCTAssertEqual(rollup.earliestDay, expected)
    }

    /// Every provider directory, not only the ones a running tail owns: a
    /// provider switched off in Settings is never built, and the days it
    /// recorded are still bound by what the setting promises.
    func testPruningDropsTheDaysPastRetentionForEveryProvider() throws {
        try write(provider: "codex", day: day(-1), models: ["a": totals(input: 10, cost: "1")])
        try write(provider: "codex", day: day(-9), models: ["a": totals(input: 10, cost: "1")])
        try write(
            provider: "claude-code", day: day(-9), models: ["a": totals(input: 10, cost: "1")])

        UsageHistoryStore.prune(keeping: 3, in: root)

        XCTAssertNotNil(UsageHistoryStore.load(provider: "codex", day: day(-1), in: root))
        XCTAssertNil(UsageHistoryStore.load(provider: "codex", day: day(-9), in: root))
        XCTAssertNil(UsageHistoryStore.load(provider: "claude-code", day: day(-9), in: root))
    }

    /// The archive is a directory in the user's Application Support, and the
    /// pruner walks it with a wildcard. Anything it cannot read as a day is
    /// something it did not write.
    func testPruningLeavesAFileItCannotNameADayAlone() throws {
        try write(provider: "codex", day: day(-9), models: ["a": totals(input: 10, cost: "1")])
        let stranger = UsageHistoryStore.providerDirectory("codex", in: root)
            .appendingPathComponent("notes.json")
        try Data("{}".utf8).write(to: stranger)

        UsageHistoryStore.prune(keeping: 1, in: root)

        XCTAssertTrue(FileManager.default.fileExists(atPath: stranger.path))
    }

    /// Claude Code writes a `<synthetic>` assistant turn with all-zero usage
    /// for its own local notices. A row of zeroes is a model in the export
    /// that never ran.
    func testAModelThatSpentNothingIsNotGivenARow() throws {
        try write(
            provider: "claude-code",
            day: day(0),
            models: [
                "<synthetic>": totals(input: 0, cost: "0"),
                "claude-sonnet-4-6": totals(input: 10, cost: "1"),
            ]
        )

        let loaded = UsageHistoryStore.load(provider: "claude-code", day: day(0), in: root)

        XCTAssertEqual(loaded?.models.map(\.model), ["claude-sonnet-4-6"])
    }

    func testDeletingTheArchiveLeavesNothingToRollUp() throws {
        try write(provider: "codex", day: day(0), models: ["a": totals(input: 10, cost: "1")])

        try UsageHistoryStore.removeAll(in: root)

        XCTAssertEqual(try week(in: root).tokens, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: UsageHistoryStore.directory(in: root).path))
    }

    /// A build that does not know a file's schema leaves it where it is. An
    /// archive that deletes what it cannot read is not an archive.
    func testAFileFromAnUnknownSchemaIsSkippedRatherThanRead() throws {
        let url = UsageHistoryStore.url(provider: "codex", day: day(0), in: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let future = """
            {"schemaVersion":99,"day":"\(day(0))","provider":"codex",\
            "updatedAt":"2026-09-12T00:00:00Z","models":[]}
            """
        try Data(future.utf8).write(to: url)

        XCTAssertNil(UsageHistoryStore.load(provider: "codex", day: day(0), in: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Periods

    /// The windows nest, so the only thing the single pass can get wrong is
    /// adding a day into a window that does not hold it. Three days apart
    /// enough to fall on different sides of every cutoff.
    func testEachWindowHoldsExactlyTheDaysInsideIt() throws {
        try write(provider: "codex", day: day(0), models: ["a": totals(input: 1, cost: "1")])
        try write(provider: "codex", day: day(-8), models: ["a": totals(input: 10, cost: "10")])
        try write(provider: "codex", day: day(-40), models: ["a": totals(input: 100, cost: "100")])

        let rollups = UsageHistoryStore.rollups(for: Set(UsagePeriod.archived), in: root)

        XCTAssertEqual(rollups[.sevenDays]?.tokens, 1)
        XCTAssertEqual(rollups[.thirtyDays]?.tokens, 11)
        XCTAssertEqual(rollups[.all]?.tokens, 111)
        XCTAssertEqual(rollups[.all]?.cost, Decimal(111))
    }

    /// The pass is an optimisation over a walk per window, so it has to answer
    /// what a walk per window would have.
    func testOnePassAgreesWithAWindowRolledUpOnItsOwn() throws {
        try write(provider: "codex", day: day(-1), models: ["a": totals(input: 7, cost: "2")])
        try write(provider: "claude-code", day: day(-9), models: ["b": totals(input: 9, cost: "3")])

        let together = UsageHistoryStore.rollups(for: Set(UsagePeriod.archived), in: root)

        for period in UsagePeriod.archived {
            let alone = UsageHistoryStore.rollups(for: [period], in: root)[period]
            XCTAssertEqual(together[period], alone, "\(period) disagreed with its own walk")
        }
    }

    /// A rollup through a cache is an optimisation over one without, so a
    /// warm cache has to answer what a fresh read of the same files would.
    func testACachedRollupAgreesWithAFreshOne() throws {
        try write(provider: "codex", day: day(-1), models: ["a": totals(input: 7, cost: "2")])
        try write(provider: "claude-code", day: day(-9), models: ["b": totals(input: 9, cost: "3")])
        var cache = UsageHistoryDayCache()
        _ = UsageHistoryStore.rollups(for: Set(UsagePeriod.archived), in: root, cache: &cache)

        let warm = UsageHistoryStore.rollups(
            for: Set(UsagePeriod.archived), in: root, cache: &cache)

        XCTAssertEqual(warm, UsageHistoryStore.rollups(for: Set(UsagePeriod.archived), in: root))
    }

    func testARewrittenDayIsReadAgainThroughTheCache() throws {
        try write(provider: "codex", day: day(-1), models: ["a": totals(input: 1, cost: "1")])
        var cache = UsageHistoryDayCache()
        _ = UsageHistoryStore.rollups(for: [.all], in: root, cache: &cache)

        try write(provider: "codex", day: day(-1), models: ["a": totals(input: 5, cost: "1")])
        let rollup = UsageHistoryStore.rollups(for: [.all], in: root, cache: &cache)[.all]

        XCTAssertEqual(rollup?.tokens, 5, "the cache answered for a file that had been rewritten")
    }

    func testADeletedDayLeavesTheCachedRollup() throws {
        try write(provider: "codex", day: day(-1), models: ["a": totals(input: 1, cost: "1")])
        try write(provider: "codex", day: day(-2), models: ["a": totals(input: 10, cost: "1")])
        var cache = UsageHistoryDayCache()
        _ = UsageHistoryStore.rollups(for: [.all], in: root, cache: &cache)

        try FileManager.default.removeItem(
            at: UsageHistoryStore.url(provider: "codex", day: day(-2), in: root))
        let rollup = UsageHistoryStore.rollups(for: [.all], in: root, cache: &cache)[.all]

        XCTAssertEqual(rollup?.tokens, 1, "the cache still counted a day file that was deleted")
    }

    /// A cached day's key is a midnight in the zone it was read in, so a zone
    /// change has to start the cache over rather than keep naming days by
    /// the zone the Mac left.
    func testAZoneChangeStartsTheCacheOver() throws {
        let launchZone = NSTimeZone.default
        defer { NSTimeZone.default = launchZone }
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "Europe/Rome"))
        try write(provider: "codex", day: day(-3), models: ["a": totals(input: 1, cost: "1")])
        var cache = UsageHistoryDayCache()
        _ = UsageHistoryStore.rollups(for: [.all], in: root, cache: &cache)

        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let warm = UsageHistoryStore.rollups(for: [.all], in: root, cache: &cache)[.all]

        XCTAssertEqual(
            warm?.earliestDay, UsageHistoryStore.rollups(for: [.all], in: root)[.all]?.earliestDay,
            "the cache named a day by the zone the Mac had left")
    }

    /// A file that does not decode is not a reading, so the cache must not
    /// hold its absence: the next call reads it again even when nothing about
    /// it that the file system reports has moved.
    func testADayThatFailedToDecodeIsReadAgain() throws {
        try write(provider: "codex", day: day(-1), models: ["a": totals(input: 4, cost: "1")])
        let url = UsageHistoryStore.url(provider: "codex", day: day(-1), in: root)
        let good = try Data(contentsOf: url)
        var broken = good
        broken[broken.startIndex] = UInt8(ascii: "x")
        try broken.write(to: url)
        let stamp = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        var cache = UsageHistoryDayCache()
        XCTAssertEqual(
            UsageHistoryStore.rollups(for: [.all], in: root, cache: &cache)[.all]?.tokens, 0,
            "a file that does not decode was counted")

        try good.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        let rollup = UsageHistoryStore.rollups(for: [.all], in: root, cache: &cache)[.all]

        XCTAssertEqual(rollup?.tokens, 4, "the cache held on to a file it could not decode")
    }

    /// A day after today is left out, and it must not be left out for good:
    /// once the calendar reaches it, the same cache reads it.
    func testADayAfterTodayIsReadOnceTheCalendarReachesIt() throws {
        let now = Date()
        try write(provider: "codex", day: day(1, now: now), models: ["a": totals(input: 6, cost: "1")])
        var cache = UsageHistoryDayCache()
        XCTAssertEqual(
            UsageHistoryStore.rollups(for: [.all], in: root, now: now, cache: &cache)[.all]?.tokens,
            0, "a day after today was counted")

        let tomorrow = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: now))
        let rollup = UsageHistoryStore.rollups(for: [.all], in: root, now: tomorrow, cache: &cache)[.all]

        XCTAssertEqual(rollup?.tokens, 6, "the cache kept a future day out after it arrived")
    }

    /// `all` is everything kept, so it takes no cutoff — and the day it names
    /// is the whole of what the word means.
    func testTheWidestWindowTakesEveryDayAndNamesItsFirst() throws {
        try write(provider: "codex", day: day(-300), models: ["a": totals(input: 5, cost: "1")])
        try write(provider: "codex", day: day(0), models: ["a": totals(input: 5, cost: "1")])

        let rollup = try XCTUnwrap(UsageHistoryStore.rollups(for: [.all], in: root)[.all])

        XCTAssertEqual(rollup.tokens, 10)
        XCTAssertEqual(
            rollup.earliestDay,
            Calendar.current.date(
                byAdding: .day, value: -300, to: Calendar.current.startOfDay(for: Date())))
    }

    /// A window holding none of the archive's days is a reading of zero, not an
    /// absence: a week nothing was spent in is true, and it has no first day to
    /// name because it holds none.
    func testAWindowWithNoDaysInItComesBackAtZeroWithNoFirstDay() throws {
        try write(provider: "codex", day: day(-40), models: ["a": totals(input: 5, cost: "1")])

        let rollups = UsageHistoryStore.rollups(for: Set(UsagePeriod.archived), in: root)

        XCTAssertEqual(rollups[.sevenDays]?.tokens, 0)
        XCTAssertNil(rollups[.sevenDays]?.earliestDay)
        XCTAssertEqual(rollups[.all]?.tokens, 5)
    }

    /// The archive keeps counters and no saving, so a window is priced when
    /// it is read, model by model, at the rates it is handed.
    func testAWindowPricesItsCacheReadsAtTheRatesItIsHanded() throws {
        let pricing = ProviderPricing(
            override: [
                "a": ModelPricing(
                    inputPerMTok: 3, outputPerMTok: 15, cacheReadPerMTok: 0.3,
                    cacheCreationPerMTok: 3.75)
            ],
            catalog: nil)
        try write(
            provider: "claude-code", day: day(-1),
            models: [
                "a": UsageHistoryTotals(
                    inputTokens: 250_000, outputTokens: 0, cacheReadTokens: 1_000_000,
                    cacheCreationTokens: 0, cost: 0)
            ])

        let cache = try XCTUnwrap(
            UsageHistoryStore.rollups(for: [.sevenDays], in: root, pricing: pricing)[.sevenDays]
        ).cache

        XCTAssertEqual(cache.saved, Decimal(string: "2.7"))
        XCTAssertEqual(try XCTUnwrap(cache.share), 0.8, accuracy: 1e-9)
    }

    /// Asking for nothing walks nothing: the archive is a directory tree, and
    /// an empty request that still enumerated and decoded it would be paid for
    /// on every frame that wanted no window.
    func testAskingForNoWindowReadsNothing() throws {
        try write(provider: "codex", day: day(0), models: ["a": totals(input: 5, cost: "1")])

        XCTAssertTrue(UsageHistoryStore.rollups(for: [], in: root).isEmpty)
    }

    // MARK: Splits and spans

    private func span(_ from: Int, _ to: Int) throws -> UsageDaySpan {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return try XCTUnwrap(
            UsageDaySpan(
                from: try XCTUnwrap(cal.date(byAdding: .day, value: from, to: today)),
                to: try XCTUnwrap(cal.date(byAdding: .day, value: to, to: today))))
    }

    private func dayDate(_ offset: Int) throws -> Date {
        let cal = Calendar.current
        return try XCTUnwrap(cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date())))
    }

    /// A directory holding a `.git`, so the resolver names it a repository.
    private func repository(_ name: String) throws -> URL {
        let repo = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        return repo
    }

    func testASpanAddsUpToTheDayFilesInsideIt() throws {
        try write(provider: "claude-code", day: day(-5), models: ["a": totals(input: 1, cost: "1")])
        try write(provider: "codex", day: day(-5), models: ["b": totals(input: 2, cost: "2")])
        try write(provider: "claude-code", day: day(-2), models: ["a": totals(input: 4, cost: "4")])
        try write(provider: "codex", day: day(-6), models: ["b": totals(input: 50, cost: "50")])
        try write(provider: "codex", day: day(0), models: ["b": totals(input: 70, cost: "70")])

        let reading = UsageHistoryStore.reading(over: try span(-5, -1), in: root)

        XCTAssertEqual(reading.rollup.tokens, 7, "a day outside the span was counted")
        XCTAssertEqual(reading.rollup.cost, Decimal(7))
        XCTAssertEqual(reading.rollup.earliestDay, try dayDate(-5))
        XCTAssertEqual(reading.rollup.period, .days(try span(-5, -1)))
        XCTAssertEqual(
            reading.rollup.spendByProvider,
            ["claude-code": UsageSpend(tokens: 5, cost: 5), "codex": UsageSpend(tokens: 2, cost: 2)])
    }

    /// One element per day holding a file, summed across providers: a day
    /// Sissy has no file for is no reading, and a bar at zero would be one.
    func testADayWithNoFileIsAbsentFromTheSpansSeries() throws {
        try write(provider: "claude-code", day: day(-5), models: ["a": totals(input: 1, cost: "1")])
        try write(provider: "codex", day: day(-5), models: ["b": totals(input: 2, cost: "2")])
        try write(provider: "claude-code", day: day(-2), models: ["a": totals(input: 4, cost: "4")])

        let days = UsageHistoryStore.reading(over: try span(-5, -1), in: root).days

        XCTAssertEqual(
            days,
            [
                UsageHistoryDayTotal(day: try dayDate(-5), tokens: 3, cost: 3),
                UsageHistoryDayTotal(day: try dayDate(-2), tokens: 4, cost: 4),
            ])
    }

    /// What names no repository, or a path that is not one, is the residue,
    /// and it is what brings the projects up to the headline.
    func testTheProjectSplitAndItsResidueAddUpToTheSpan() throws {
        let repo = try repository("repo")
        let scratch = root.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try writeRows(
            provider: "claude-code", day: day(-3),
            rows: [
                UsageHistoryRow(model: "a", project: repo.appendingPathComponent("app").path):
                    totals(input: 10, cost: "1"),
                UsageHistoryRow(model: "b", project: repo.path): totals(input: 20, cost: "2"),
                UsageHistoryRow(model: "a", project: scratch.path): totals(input: 40, cost: "4"),
                UsageHistoryRow(model: "a", project: nil): totals(input: 80, cost: "8"),
            ])

        let rollup = UsageHistoryStore.reading(over: try span(-3, -3), in: root).rollup

        XCTAssertEqual(rollup.projects.map(\.path), [ProjectResolver().project(for: repo.path)])
        XCTAssertEqual(rollup.projects.first?.tokens, 30)
        XCTAssertEqual(rollup.unattributed, UsageSpend(tokens: 120, cost: 12))
        XCTAssertEqual(
            rollup.projects.reduce(0) { $0 + $1.tokens } + rollup.unattributed.tokens, rollup.tokens)
        XCTAssertEqual(
            rollup.projects.reduce(Decimal(0)) { $0 + $1.cost } + rollup.unattributed.cost, rollup.cost)
    }

    /// The presets carry the same splits, today's file included the way the
    /// headline includes it.
    func testAPresetCarriesItsProjectsAndProviders() throws {
        let repo = try repository("repo")
        try writeRows(
            provider: "claude-code", day: day(0),
            rows: [UsageHistoryRow(model: "a", project: repo.path): totals(input: 10, cost: "1")])
        try writeRows(
            provider: "codex", day: day(-3),
            rows: [
                UsageHistoryRow(model: "b", project: repo.path): totals(input: 20, cost: "2"),
                UsageHistoryRow(model: "b", project: nil): totals(input: 5, cost: "1"),
            ])

        let rollup = try week(in: root)

        XCTAssertEqual(rollup.projects.map(\.tokens), [30])
        XCTAssertEqual(rollup.unattributed, UsageSpend(tokens: 5, cost: 1))
        XCTAssertEqual(
            rollup.spendByProvider,
            ["claude-code": UsageSpend(tokens: 10, cost: 1), "codex": UsageSpend(tokens: 25, cost: 3)])
    }

    /// A cached day keeps its attribution, so a warm rollup splits as a cold
    /// one does.
    func testACachedRollupKeepsItsProjectSplit() throws {
        let repo = try repository("repo")
        try writeRows(
            provider: "codex", day: day(-1),
            rows: [UsageHistoryRow(model: "b", project: repo.path): totals(input: 20, cost: "2")])
        let resolver = ProjectResolver()
        var cache = UsageHistoryDayCache()
        let cold = UsageHistoryStore.rollups(for: [.all], in: root, cache: &cache, projects: resolver)

        let warm = UsageHistoryStore.rollups(for: [.all], in: root, cache: &cache, projects: resolver)

        XCTAssertEqual(warm, cold)
        XCTAssertEqual(warm[.all]?.projects.count, 1)
    }

    /// A calendar month is one call, through today for the month in course.
    func testAMonthIsOneSpanEndingNoLaterThanToday() throws {
        let cal = Calendar.current
        let now = Date()
        let current = try XCTUnwrap(UsageDaySpan.month(containing: now, now: now))
        let lastMonth = try XCTUnwrap(
            UsageDaySpan.month(
                containing: try XCTUnwrap(cal.date(byAdding: .month, value: -1, to: now)), now: now))

        XCTAssertTrue(current.includesToday(now: now))
        XCTAssertEqual(cal.component(.day, from: current.from), 1)
        XCTAssertTrue((28...31).contains(lastMonth.dayCount()))
        XCTAssertFalse(lastMonth.includesToday(now: now))
        XCTAssertNil(
            UsageDaySpan.month(
                containing: try XCTUnwrap(cal.date(byAdding: .month, value: 1, to: now)), now: now))
    }

    func testASpanReachingPastTodayOrRunningBackwardsIsRefused() throws {
        XCTAssertNil(UsageDaySpan(from: try dayDate(0), to: try dayDate(1)))
        XCTAssertNil(UsageDaySpan(from: try dayDate(-1), to: try dayDate(-2)))
    }

    /// A preference written before a window could be picked is a bare
    /// `UsagePeriod`, and it has to come back as the same choice.
    func testAStoredPeriodDecodesAsThePresetItNamed() throws {
        for period in UsagePeriod.allCases {
            let stored = try JSONEncoder().encode(period)

            let decoded = try JSONDecoder().decode(UsageRange.self, from: stored)

            XCTAssertEqual(decoded, .preset(period))
            XCTAssertEqual(try JSONEncoder().encode(decoded), stored)
        }
    }

    /// A span is kept as the two days it names, so it reads back as them.
    func testASpanRoundTripsAsItsTwoDays() throws {
        let picked = UsageRange.days(try span(-9, -2))

        let encoded = try JSONEncoder().encode(picked)

        XCTAssertEqual(try JSONDecoder().decode(UsageRange.self, from: encoded), picked)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: String])
        XCTAssertEqual(keys, ["from": day(-9), "to": day(-2)])
    }

    /// A stored span is held to today as the clock reads it when it is read
    /// back, not as it read when it was picked, so a window that has come to
    /// name a day after today is refused rather than read.
    func testAStoredSpanEndingAfterTodayIsRefused() throws {
        let future = try JSONEncoder().encode(["from": day(-1), "to": day(1)])
        let past = try JSONEncoder().encode(["from": day(-3), "to": day(-1)])

        XCTAssertThrowsError(try JSONDecoder().decode(UsageRange.self, from: future))
        XCTAssertEqual(
            try JSONDecoder().decode(UsageRange.self, from: past), .days(try span(-3, -1)))
    }

    /// The two dates a span was picked as are what it names after the Mac
    /// changes zone: its midnights, what it contains and whether it reaches
    /// today all follow the zone in force, as the archive's keys do.
    func testASpanNamesTheSameDatesAfterTheZoneMoves() throws {
        let launchZone = NSTimeZone.default
        defer { NSTimeZone.default = launchZone }
        let rome = try XCTUnwrap(TimeZone(identifier: "Europe/Rome"))
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        NSTimeZone.default = rome
        let picked = try XCTUnwrap(
            UsageDaySpan(
                from: try instant(2026, 9, 10, hour: 0, in: rome),
                to: try instant(2026, 9, 12, hour: 0, in: rome),
                now: try instant(2026, 9, 20, hour: 12, in: rome)))

        NSTimeZone.default = newYork

        XCTAssertEqual(picked.dayKeys, ["2026-09-10", "2026-09-11", "2026-09-12"])
        XCTAssertEqual(picked.from, try instant(2026, 9, 10, hour: 0, in: newYork))
        XCTAssertEqual(picked.to, try instant(2026, 9, 12, hour: 0, in: newYork))
        XCTAssertTrue(picked.contains(try instant(2026, 9, 12, hour: 23, in: newYork)))
        XCTAssertFalse(picked.contains(try instant(2026, 9, 13, hour: 0, in: newYork)))
        XCTAssertTrue(picked.includesToday(now: try instant(2026, 9, 12, hour: 20, in: newYork)))
        XCTAssertEqual(picked.dayCount(), 3)
    }

    /// The zones furthest from UTC on either side, and Auckland on the day
    /// its clocks go forward, each name the date the instant falls on and
    /// start it at that date's own first instant.
    func testASpanFindsItsMidnightInTheZonesFurthestFromUTC() throws {
        let launchZone = NSTimeZone.default
        defer { NSTimeZone.default = launchZone }
        for (identifier, day) in [
            ("Pacific/Kiritimati", 27), ("Etc/GMT+12", 27), ("Pacific/Auckland", 27),
        ] {
            let zone = try XCTUnwrap(TimeZone(identifier: identifier))
            NSTimeZone.default = zone
            let noon = try instant(2026, 9, day, hour: 12, in: zone)

            let picked = try XCTUnwrap(UsageDaySpan(from: noon, to: noon, now: noon))

            XCTAssertEqual(picked.dayKeys, ["2026-09-\(day)"], identifier)
            XCTAssertEqual(picked.from, Calendar.current.startOfDay(for: noon), identifier)
            XCTAssertTrue(picked.contains(picked.from), identifier)
        }
    }

    /// Santiago's clocks skip from Saturday 23:59 to Sunday 01:00 on 6
    /// September 2026, so that day has no midnight. A span across it keys
    /// every day as the preset of the same days does, and contains each.
    func testASpanAcrossAMidnightThatDoesNotExistKeysItsDaysAsThePresetDoes() throws {
        let launchZone = NSTimeZone.default
        defer { NSTimeZone.default = launchZone }
        let santiago = try XCTUnwrap(TimeZone(identifier: "America/Santiago"))
        NSTimeZone.default = santiago
        for name in ["2026-09-05", "2026-09-06", "2026-09-07"] {
            try write(provider: "codex", day: name, models: ["a": totals(input: 1, cost: "1")])
        }
        let now = try instant(2026, 9, 7, hour: 12, in: santiago)
        let picked = try XCTUnwrap(
            UsageDaySpan(from: try instant(2026, 9, 1, hour: 12, in: santiago), to: now, now: now))

        let reading = UsageHistoryStore.reading(over: picked, in: root)
        let week = try XCTUnwrap(
            UsageHistoryStore.rollups(for: [.sevenDays], in: root, now: now)[.sevenDays])

        let cal = Calendar.current
        XCTAssertEqual(
            reading.days.map(\.day),
            try [5, 6, 7].map { cal.startOfDay(for: try instant(2026, 9, $0, hour: 12, in: santiago)) })
        XCTAssertTrue(reading.days.allSatisfy { picked.contains($0.day) })
        XCTAssertEqual(reading.rollup.tokens, week.tokens)
        XCTAssertEqual(reading.rollup.earliestDay, week.earliestDay)
    }

    private func instant(_ year: Int, _ month: Int, _ day: Int, hour: Int, in zone: TimeZone)
        throws -> Date
    {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return try XCTUnwrap(
            cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
    }

    private func week(in root: URL) throws -> UsageHistoryRollup {
        try XCTUnwrap(UsageHistoryStore.rollups(for: [.sevenDays], in: root)[.sevenDays])
    }
}
