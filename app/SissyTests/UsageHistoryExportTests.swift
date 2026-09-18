import XCTest

@testable import Sissy

/// What the export promises a spreadsheet: the archive's own grain and the
/// archive's own numbers, escaped so a repository path cannot move a column.
final class UsageHistoryExportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-export-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func day(
        _ key: String,
        provider: String,
        rows: [UsageHistoryRow: UsageHistoryTotals]
    ) -> UsageHistoryDay {
        UsageHistoryDay(day: key, provider: provider, updatedAt: Date(), totals: rows)
    }

    private func totals(_ input: Int, cost: String) -> UsageHistoryTotals {
        UsageHistoryTotals(
            inputTokens: input,
            outputTokens: 1,
            cacheReadTokens: 2,
            cacheCreationTokens: 3,
            cost: Decimal(string: cost) ?? 0
        )
    }

    private func lines(_ csv: String) -> [String] {
        csv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// The header is the contract every other assertion here reads against, so
    /// it is pinned rather than derived from the same constant it checks.
    func testTheHeaderNamesEveryColumnInOrder() {
        let header = lines(UsageHistoryExport.csv([])).first

        XCTAssertEqual(
            header,
            "day,provider,model,project,project_path,"
                + "input_tokens,output_tokens,cache_read_tokens,cache_creation_tokens,cost"
        )
    }

    /// The whole reason cost is a string all the way from the archive: a
    /// spreadsheet sums the column, and the panel's rounding is for 340 points
    /// of menu bar rather than for a total somebody invoices against.
    func testCostIsTheArchivesOwnDecimalRatherThanARoundedOne() {
        let csv = UsageHistoryExport.csv([
            day(
                "2026-09-14", provider: "claude-code",
                rows: [UsageHistoryRow(model: "opus", project: nil): totals(10, cost: "0.000022")]
            )
        ])

        XCTAssertTrue(lines(csv)[1].hasSuffix(",0.000022"), lines(csv)[1])
    }

    /// A repository path can hold a comma, and a model name a quote. Unescaped,
    /// either one moves every column to its right and the money lands under
    /// the wrong heading.
    func testASeparatorInAPathIsQuotedRatherThanSplittingTheRow() {
        let path = "/Users/smyile/acme, inc/api"
        let csv = UsageHistoryExport.csv([
            day(
                "2026-09-14", provider: "claude-code",
                rows: [UsageHistoryRow(model: "opus", project: path): totals(10, cost: "1")]
            )
        ])

        XCTAssertEqual(
            lines(csv)[1],
            "2026-09-14,claude-code,opus,api,\"/Users/smyile/acme, inc/api\",10,1,2,3,1"
        )
    }

    func testAQuoteInAFieldIsDoubled() {
        XCTAssertEqual(UsageHistoryExport.field("say \"hi\""), "\"say \"\"hi\"\"\"")
    }

    /// The panel renders the last component and the file carries the path, so
    /// two repositories sharing a basename stay tellable apart in a pivot
    /// table. A row that names no repository claims neither.
    func testAnUnattributedRowNamesNoProjectInEitherColumn() {
        let csv = UsageHistoryExport.csv([
            day(
                "2026-09-14", provider: "codex",
                rows: [UsageHistoryRow(model: "gpt-5", project: nil): totals(10, cost: "1")]
            )
        ])

        XCTAssertEqual(lines(csv)[1], "2026-09-14,codex,gpt-5,,,10,1,2,3,1")
    }

    /// `UsageHistoryDay.models` comes out of a dictionary, so without an
    /// explicit order two exports of an unchanged archive differ and a diff
    /// between them says nothing.
    func testTwoExportsOfTheSameArchiveAreIdentical() {
        let rows: [UsageHistoryRow: UsageHistoryTotals] = [
            UsageHistoryRow(model: "sonnet", project: "/b"): totals(1, cost: "1"),
            UsageHistoryRow(model: "opus", project: "/b"): totals(2, cost: "2"),
            UsageHistoryRow(model: "opus", project: "/a"): totals(3, cost: "3"),
        ]
        let days = [day("2026-09-14", provider: "claude-code", rows: rows)]

        let first = UsageHistoryExport.csv(days)

        XCTAssertEqual(first, UsageHistoryExport.csv(days))
        XCTAssertEqual(
            lines(first).dropFirst().compactMap { $0.split(separator: ",").dropFirst(2).first },
            ["opus", "opus", "sonnet"]
        )
    }

    /// One file per provider plus a combined one, which is what lets Numbers
    /// import them as a sheet each and still holds the whole archive in one
    /// place. Every day lands in exactly two of the three files.
    func testEachProviderGetsItsOwnFileBesideTheCombinedOne() throws {
        let days = [
            day(
                "2026-09-13", provider: "claude-code",
                rows: [UsageHistoryRow(model: "opus", project: nil): totals(1, cost: "1")]
            ),
            day(
                "2026-09-14", provider: "codex",
                rows: [UsageHistoryRow(model: "gpt-5", project: nil): totals(2, cost: "2")]
            ),
        ]

        try UsageHistoryExport.write(days, to: root)

        let claude = try String(
            contentsOf: root.appendingPathComponent("sissy-usage-claude-code.csv"),
            encoding: .utf8)
        let codex = try String(
            contentsOf: root.appendingPathComponent("sissy-usage-codex.csv"), encoding: .utf8)
        let all = try String(
            contentsOf: root.appendingPathComponent("sissy-usage-all.csv"), encoding: .utf8)

        XCTAssertEqual(lines(claude).count, 3)
        XCTAssertEqual(lines(codex).count, 3)
        XCTAssertEqual(lines(all).count, 4)
        XCTAssertTrue(claude.contains("opus"))
        XCTAssertFalse(claude.contains("gpt-5"))
    }

    /// An archive with nothing in it still writes the two files that are not
    /// about a particular provider, so the export is never a directory a
    /// reader has to guess the shape of — and writes no per-provider file,
    /// because a provider with no days is not a provider that spent zero.
    func testAnEmptyArchiveWritesOnlyTheProviderlessFiles() throws {
        try UsageHistoryExport.write([], to: root)

        let written = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()

        XCTAssertEqual(written, ["sissy-activity.csv", "sissy-usage-all.csv"])
    }
}
