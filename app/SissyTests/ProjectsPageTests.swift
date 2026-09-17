import XCTest

@testable import Sissy

/// The page behind the project section's own row: that it holds the rows the
/// section folded away, that it still reaches the day it prints, and that it
/// says which CLI each repository's money went through.
final class ProjectsPageTests: XCTestCase {
    func testThePageHoldsEveryRepositoryTheSectionFoldedAway() {
        let many = (1...9).map { project("/Users/smyile/repo\($0)", 100, "1.00") }
        let frame = frame(claude: many)

        XCTAssertEqual(UsagePanelSnapshot.make(frame: frame).projects.count, 5)
        XCTAssertEqual(
            UsagePanelSnapshot.projectsPage(frame: frame, provider: nil).rows.count, 9,
            "the page folded the list it exists to unfold")
    }

    /// The section's own row offers the list, so it has to say how long the
    /// list is — the fold below it counts only what is missing.
    func testTheSectionCountsRepositoriesRatherThanRows() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(
                claude: (1...9).map { project("/Users/smyile/repo\($0)", 100, "1.00") },
                providerTokens: 1_000, providerCost: "10.00"))

        XCTAssertEqual(snapshot.projectCount, 9)
        XCTAssertEqual(snapshot.projects.count, 6, "the fold and the remainder are not projects")
    }

    /// The rows are read against the total in the header, so what named no
    /// repository keeps its row here exactly as it does in the section.
    func testWhatNamedNoRepositoryStillReachesTheTotal() {
        let page = UsagePanelSnapshot.projectsPage(
            frame: frame(
                claude: [project("/Users/smyile/sissy", 750, "7.50")],
                providerTokens: 1_000, providerCost: "10.00"),
            provider: nil)

        XCTAssertEqual(page.rows.map(\.name), ["sissy", "Unattributed"])
        XCTAssertEqual(page.subtitle, "today · 1 project · $10.00")
    }

    /// One repository, two CLIs, one row — and the split is what says which of
    /// them spent, since the row's own figures are the two summed.
    func testARepositoryWorkedThroughBothCLIsCarriesBothShares() throws {
        let page = UsagePanelSnapshot.projectsPage(
            frame: frame(
                claude: [project("/Users/smyile/legion", 750, "7.50")],
                codex: [project("/Users/smyile/legion", 250, "2.50")]),
            provider: nil)

        let row = try XCTUnwrap(page.rows.first)
        XCTAssertEqual(row.providers.map(\.id), [ProviderID.claudeCode, ProviderID.codex])
        XCTAssertEqual(row.providers.map { Int(($0.share * 100).rounded()) }, [75, 25])
    }

    /// The shares are of the day, not of the row, so the segments a bar draws
    /// add up to the fill the row's own share gives it.
    func testTheSplitAddsUpToTheRowsOwnShare() throws {
        let page = UsagePanelSnapshot.projectsPage(
            frame: frame(
                claude: [project("/Users/smyile/legion", 300, "3.00")],
                codex: [project("/Users/smyile/legion", 100, "1.00")],
                providerCost: "8.00"),
            provider: nil)

        let row = try XCTUnwrap(page.rows.first)
        XCTAssertEqual(row.providers.reduce(0) { $0 + $1.share }, row.share, accuracy: 0.0001)
    }

    /// A vendor's own page names the vendor in its title, so a mark on every
    /// row would say it again per repository.
    func testAProvidersOwnPageLeavesTheSplitOffItsRows() {
        let page = UsagePanelSnapshot.projectsPage(
            frame: frame(
                claude: [project("/Users/smyile/legion", 750, "7.50")],
                codex: [project("/Users/smyile/legion", 250, "2.50")]),
            provider: ProviderID.codex)

        XCTAssertEqual(page.rows.map(\.name), ["legion"])
        XCTAssertEqual(page.rows.first?.providers, [])
        XCTAssertEqual(page.subtitle, "today · 1 project · $2.50")
    }

    /// The remainder is what the day spent outside every repository, so there
    /// is no project for a provider to have spent it on. It is asserted on the
    /// page rather than in the section because the page is the only surface
    /// that draws a split at all — in the section every row names none, and a
    /// test there would pass with the rule deleted.
    func testTheRemainderNamesNoProviderOnAPageWhereTheOtherRowsDo() throws {
        let claude = ProviderSlice(
            id: ProviderID.claudeCode, tokens: 1_000, cost: 10,
            projects: [project("/Users/smyile/legion", 750, "7.50")])
        let codex = ProviderSlice(
            id: ProviderID.codex, tokens: 250, cost: Decimal(string: "2.50")!,
            projects: [project("/Users/smyile/legion", 250, "2.50")])
        let page = UsagePanelSnapshot.projectsPage(
            frame: FrameData(
                tokens: 1_250, cost: Decimal(string: "12.50")!, burn: 1500,
                providers: [claude, codex], keepAwake: .off, history: [:],
                projects: FrameBuilder.combinedProjects([claude, codex])),
            provider: nil)

        XCTAssertEqual(page.rows.map(\.name), ["legion", "Unattributed"])
        XCTAssertEqual(try XCTUnwrap(page.rows.first).providers.count, 2)
        XCTAssertEqual(page.rows.last?.providers, [])
    }

    private func project(_ path: String, _ tokens: Int, _ cost: String) -> ProjectTotals {
        ProjectTotals(path: path, tokens: tokens, cost: Decimal(string: cost)!)
    }

    /// Built the way the engine builds one, so the combined list is the slices
    /// summed rather than a fixture asserting a split into existence.
    private func frame(
        claude: [ProjectTotals] = [],
        codex: [ProjectTotals] = [],
        providerTokens: Int? = nil,
        providerCost: String? = nil
    ) -> FrameData {
        let slices = [(ProviderID.claudeCode, claude), (ProviderID.codex, codex)]
            .filter { !$0.1.isEmpty }
            .map { id, projects in
                ProviderSlice(
                    id: id,
                    tokens: providerTokens ?? projects.reduce(0) { $0 + $1.tokens },
                    cost: providerCost.map { Decimal(string: $0)! }
                        ?? projects.reduce(Decimal(0)) { $0 + $1.cost },
                    projects: projects
                )
            }
        return FrameData(
            tokens: slices.reduce(0) { $0 + $1.tokens },
            cost: slices.reduce(Decimal(0)) { $0 + $1.cost },
            burn: 1500,
            providers: slices,
            keepAwake: .off,
            history: [:],
            projects: FrameBuilder.combinedProjects(slices)
        )
    }
}
