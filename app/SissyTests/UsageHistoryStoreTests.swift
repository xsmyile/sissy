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

        let rollups = UsageHistoryStore.rollups(for: UsagePeriod.archived, in: root)

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

        let together = UsageHistoryStore.rollups(for: UsagePeriod.archived, in: root)

        for period in UsagePeriod.archived {
            let alone = UsageHistoryStore.rollups(for: [period], in: root)[period]
            XCTAssertEqual(together[period], alone, "\(period) disagreed with its own walk")
        }
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

        let rollups = UsageHistoryStore.rollups(for: UsagePeriod.archived, in: root)

        XCTAssertEqual(rollups[.sevenDays]?.tokens, 0)
        XCTAssertNil(rollups[.sevenDays]?.earliestDay)
        XCTAssertEqual(rollups[.all]?.tokens, 5)
    }

    private func week(in root: URL) throws -> UsageHistoryRollup {
        try XCTUnwrap(UsageHistoryStore.rollups(for: [.sevenDays], in: root)[.sevenDays])
    }
}
