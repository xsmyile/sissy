import XCTest

@testable import Sissy

/// What the panel says about where a day's money went: which rows exist, what
/// they are called, and that every one of them is a repository — the tail of
/// the list folded into a row that is still repositories, and what named none
/// left to the page's own line rather than given a rank among them.
final class UsageProjectRowsTests: XCTestCase {
    func testADayWithNoProjectNamedDrawsNoSection() {
        let snapshot = UsagePanelSnapshot.make(frame: frame(projects: []))

        XCTAssertTrue(snapshot.projects.isEmpty)
    }

    func testARowIsNamedAfterTheRepositoryAndKeepsThePathForTheTooltip() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(projects: [project("/Users/smyile/mdev/legion", 900, "6.00")]))

        XCTAssertEqual(snapshot.projects.map(\.name), ["legion"])
        XCTAssertEqual(snapshot.projects.map(\.tooltip), ["/Users/smyile/mdev/legion"])
    }

    func testTheTailOfALongListIsFoldedIntoOneRowThatStillCounts() {
        let many = (1...9).map { project("/Users/smyile/repo\($0)", 100, "1.00") }
        let snapshot = UsagePanelSnapshot.make(frame: frame(projects: many))

        XCTAssertEqual(snapshot.projects.count, 5, "the popover grew a row per repository")
        XCTAssertEqual(snapshot.projects.last?.name, "5 more projects")
        XCTAssertNil(
            snapshot.projects.last?.tooltip, "the folded row claimed one project's path")
        XCTAssertEqual(
            snapshot.projects.last?.cost, "$5.00",
            "the folded row dropped what it stands for")
    }

    /// One project past the limit still folds two, because folding one would
    /// cost the same row it saves.
    func testTheSmallestFoldStandsForTwoProjects() {
        let many = (1...6).map { project("/Users/smyile/repo\($0)", 100, "1.00") }
        let snapshot = UsagePanelSnapshot.make(frame: frame(projects: many))

        XCTAssertEqual(snapshot.projects.count, 5)
        XCTAssertEqual(snapshot.projects.last?.name, "2 more projects")
    }

    /// The rows are read against the header, so their shares have to be
    /// shares of it — not of each other.
    func testTheSharesAreSharesOfTheDay() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(
                projects: [
                    project("/Users/smyile/a", 750, "7.50"),
                    project("/Users/smyile/b", 250, "2.50"),
                ],
                providerCost: "10.00"))

        XCTAssertEqual(snapshot.projects.map { Int(($0.share * 100).rounded()) }, [75, 25])
    }

    /// The section's label counts repositories, so a day with money outside
    /// every repository must not answer it with a row that is not one. The
    /// figure is not lost — it is the page's own line, asserted there.
    func testWhatNamedNoRepositoryIsNotARowInTheSection() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(
                projects: [project("/Users/smyile/sissy", 750, "7.50")],
                providerTokens: 1_000,
                providerCost: "10.00"))

        XCTAssertEqual(snapshot.projects.map(\.name), ["sissy"])
        XCTAssertEqual(snapshot.projects.count, snapshot.projectCount)
    }

    func testADayEveryLineOfWhichNamedARepositoryHasNoRemainderRow() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(
                projects: [
                    project("/Users/smyile/sissy", 750, "7.50"),
                    project("/Users/smyile/legion", 250, "2.50"),
                ]))

        XCTAssertEqual(snapshot.projects.map(\.name), ["sissy", "legion"])
    }

    /// The row limit bounds the repositories, and a day that spent outside
    /// them does not shorten the list it is not part of.
    func testUnnamedSpendCostsTheSectionNoRow() {
        let many = (1...9).map { project("/Users/smyile/repo\($0)", 100, "1.00") }
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(projects: many, providerTokens: 1_000, providerCost: "10.00"))

        XCTAssertEqual(snapshot.projects.count, 5)
        XCTAssertEqual(snapshot.projects.last?.name, "5 more projects")
    }

    /// A day whose every line named no repository has nothing to list, and the
    /// panel draws no heading over an empty list.
    func testADayThatNamedNothingDrawsNoSectionAtAll() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(projects: [], providerTokens: 1_000, providerCost: "10.00"))

        XCTAssertTrue(snapshot.projects.isEmpty)
    }

    /// The split is per provider, and the same repository worked on through
    /// both CLIs is one row, not two.
    func testOneRepositoryWorkedThroughBothCLIsIsOneRow() {
        let combined = FrameBuilder.combinedProjects([
            ProviderSlice(
                id: ProviderID.claudeCode, tokens: 100, cost: 4,
                projects: [ProjectTotals(path: "/Users/smyile/legion", tokens: 100, cost: 4)]),
            ProviderSlice(
                id: ProviderID.codex, tokens: 50, cost: 1,
                projects: [ProjectTotals(path: "/Users/smyile/legion", tokens: 50, cost: 1)]),
        ])

        XCTAssertEqual(combined.count, 1)
        XCTAssertEqual(combined.first?.tokens, 150)
        XCTAssertEqual(combined.first?.cost, 5)
    }

    func testTheRowsAreOrderedByWhatTheyCost() {
        let combined = FrameBuilder.combinedProjects([
            ProviderSlice(
                id: ProviderID.claudeCode, tokens: 300, cost: 6,
                projects: [
                    ProjectTotals(path: "/Users/smyile/cheap", tokens: 200, cost: 1),
                    ProjectTotals(path: "/Users/smyile/dear", tokens: 100, cost: 5),
                ])
        ])

        XCTAssertEqual(combined.map(\.path), ["/Users/smyile/dear", "/Users/smyile/cheap"])
    }

    private func project(_ path: String, _ tokens: Int, _ cost: String) -> ProjectTotals {
        ProjectTotals(path: path, tokens: tokens, cost: Decimal(string: cost)!)
    }

    /// The provider spends exactly what the projects add up to unless a test
    /// says otherwise — a day every line of which named a repository — so a
    /// test about something else does not grow a remainder row by accident.
    private func frame(
        projects: [ProjectTotals],
        providerTokens: Int? = nil,
        providerCost: String? = nil
    ) -> FrameData {
        let tokens = providerTokens ?? projects.reduce(0) { $0 + $1.tokens }
        let cost =
            providerCost.map { Decimal(string: $0)! }
            ?? projects.reduce(Decimal(0)) { $0 + $1.cost }
        return FrameData(
            tokens: tokens,
            cost: cost,
            burn: 1500,
            providers: [
                ProviderSlice(
                    id: ProviderID.claudeCode,
                    tokens: tokens,
                    cost: cost,
                    projects: projects
                )
            ],
            keepAwake: .off,
            history: [:],
            projects: projects
        )
    }
}
