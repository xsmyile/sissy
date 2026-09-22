import XCTest

@testable import Sissy

/// The page behind the project section's own row: that it holds the rows the
/// section folded away, that it still reaches the day it prints — which is
/// what its residue line is for, since it is the one surface that carries
/// one — and that it says which CLI each repository's money went through.
final class ProjectsPageTests: XCTestCase {
    func testThePageHoldsEveryRepositoryTheSectionFoldedAway() {
        let many = (1...9).map { project("/Users/smyile/repo\($0)", 100, "1.00") }
        let frame = frame(claude: many)

        XCTAssertEqual(UsagePanelSnapshot.make(frame: frame).projects.count, 3)
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
        XCTAssertEqual(snapshot.projects.count, 3, "the section grew a row that is not a project")
    }

    /// The rows are read against the total in the header, so what named no
    /// repository is still printed here — as the line under them rather than
    /// as one of them.
    func testWhatNamedNoRepositoryStillReachesTheTotal() throws {
        let page = UsagePanelSnapshot.projectsPage(
            frame: frame(
                claude: [project("/Users/smyile/sissy", 750, "7.50")],
                providerTokens: 1_000, providerCost: "10.00"),
            provider: nil)

        XCTAssertEqual(page.rows.map(\.name), ["sissy"])
        let residue = try XCTUnwrap(page.residue)
        XCTAssertEqual(residue.cost, "$2.50")
        XCTAssertEqual(residue.tokens, "250")
        XCTAssertEqual(page.subtitle, "today · 1 project · $10.00")
    }

    /// The rows and the header can be read an instant apart — the split is
    /// republished on every read of a provider's day, the totals beside it
    /// only on an emit — so the two halves of a remainder can disagree about
    /// its sign. That is a reading that disagrees with itself, not money.
    func testAResidueThatCameOutNegativeIsNotDrawn() {
        let page = UsagePanelSnapshot.projectsPage(
            frame: frame(
                claude: [project("/Users/smyile/sissy", 250, "9.00")],
                providerTokens: 1_000, providerCost: "6.00"),
            provider: nil)

        XCTAssertEqual(page.rows.map(\.name), ["sissy"])
        XCTAssertNil(page.residue)
    }

    /// A day every line of which named a repository has nothing left over, and
    /// a line reading zero would be a hole reported where there is none.
    func testADayFullyNamedHasNoResidueLine() {
        let page = UsagePanelSnapshot.projectsPage(
            frame: frame(claude: [project("/Users/smyile/sissy", 750, "7.50")]),
            provider: nil)

        XCTAssertNil(page.residue)
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

    /// A vendor's own page names the vendor, so its residue says the figure
    /// and not who spent it either.
    func testAProvidersOwnPageLeavesTheSplitOffItsResidue() throws {
        let page = UsagePanelSnapshot.projectsPage(
            frame: frame(
                claude: [project("/Users/smyile/legion", 750, "7.50")],
                providerTokens: 1_000, providerCost: "10.00"),
            provider: ProviderID.claudeCode)

        XCTAssertEqual(try XCTUnwrap(page.residue).cost, "$2.50")
        XCTAssertEqual(try XCTUnwrap(page.residue).providers, [])
    }

    /// The residue is the one place the panel can say *which* CLI lost the
    /// attribution: a provider's own page shows its own and nothing there says
    /// how the two compare. Only the CLIs that have one are named — a zero
    /// beside a figure reads as a CLI that spent nothing at all.
    func testTheResidueNamesTheCLIsThatLostTheAttribution() throws {
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

        XCTAssertEqual(page.rows.map(\.name), ["legion"])
        XCTAssertEqual(try XCTUnwrap(page.rows.first).providers.count, 2)
        let residue = try XCTUnwrap(page.residue)
        XCTAssertEqual(residue.cost, "$2.50")
        XCTAssertEqual(residue.providers.map(\.id), [ProviderID.claudeCode])
        XCTAssertEqual(residue.providers.map(\.cost), ["$2.50"])
    }

    /// Two CLIs that each spent outside every repository are two figures, in
    /// the panel's own provider order so the marks read the same way down the
    /// page as they do on the rows.
    func testBothCLIsAreNamedWhenBothLostAttribution() throws {
        let page = UsagePanelSnapshot.projectsPage(
            frame: frame(
                claude: [project("/Users/smyile/legion", 750, "7.50")],
                codex: [project("/Users/smyile/legion", 250, "2.50")],
                providerTokens: 1_000, providerCost: "10.00"),
            provider: nil)

        let residue = try XCTUnwrap(page.residue)
        XCTAssertEqual(residue.providers.map(\.id), [ProviderID.claudeCode, ProviderID.codex])
        XCTAssertEqual(residue.providers.map(\.cost), ["$2.50", "$7.50"])
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
