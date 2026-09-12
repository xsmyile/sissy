import XCTest

@testable import Sissy

/// What the panel says about where a day's money went: which rows exist, what
/// they are called, and that they still add up to the day after the tail of
/// them has been folded away.
final class UsageProjectRowsTests: XCTestCase {
    func testADayWithNoProjectNamedDrawsNoSection() {
        let snapshot = UsagePanelSnapshot.make(frame: frame(projects: []))

        XCTAssertTrue(snapshot.projects.isEmpty)
    }

    func testARowIsNamedAfterTheRepositoryAndKeepsThePathForTheTooltip() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(projects: [project("/Users/d/mdev/legion", 900, "6.00")]))

        XCTAssertEqual(snapshot.projects.map(\.name), ["legion"])
        XCTAssertEqual(snapshot.projects.map(\.path), ["/Users/d/mdev/legion"])
    }

    func testTheTailOfALongListIsFoldedIntoOneRowThatStillCounts() {
        let many = (1...9).map { project("/Users/d/repo\($0)", 100, "1.00") }
        let snapshot = UsagePanelSnapshot.make(frame: frame(projects: many))

        XCTAssertEqual(snapshot.projects.count, 5, "the popover grew a row per repository")
        XCTAssertEqual(snapshot.projects.last?.name, "5 more projects")
        XCTAssertNil(snapshot.projects.last?.path, "the folded row claimed one project's path")
        XCTAssertEqual(
            snapshot.projects.last?.cost, "$5.00",
            "the folded row dropped what it stands for")
    }

    /// One project past the limit still folds two, because folding one would
    /// cost the same row it saves.
    func testTheSmallestFoldStandsForTwoProjects() {
        let many = (1...6).map { project("/Users/d/repo\($0)", 100, "1.00") }
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
                    project("/Users/d/a", 750, "7.50"),
                    project("/Users/d/b", 250, "2.50"),
                ],
                providerCost: "10.00"))

        XCTAssertEqual(snapshot.projects.map { Int(($0.share * 100).rounded()) }, [75, 25])
    }

    /// The split is per provider, and the same repository worked on through
    /// both CLIs is one row, not two.
    func testOneRepositoryWorkedThroughBothCLIsIsOneRow() {
        let combined = FrameBuilder.combinedProjects([
            ProviderSlice(
                id: ProviderID.claudeCode, tokens: 100, cost: 4,
                projects: [ProjectTotals(path: "/Users/d/legion", tokens: 100, cost: 4)]),
            ProviderSlice(
                id: ProviderID.codex, tokens: 50, cost: 1,
                projects: [ProjectTotals(path: "/Users/d/legion", tokens: 50, cost: 1)]),
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
                    ProjectTotals(path: "/Users/d/cheap", tokens: 200, cost: 1),
                    ProjectTotals(path: "/Users/d/dear", tokens: 100, cost: 5),
                ])
        ])

        XCTAssertEqual(combined.map(\.path), ["/Users/d/dear", "/Users/d/cheap"])
    }

    private func project(_ path: String, _ tokens: Int, _ cost: String) -> ProjectTotals {
        ProjectTotals(path: path, tokens: tokens, cost: Decimal(string: cost)!)
    }

    private func frame(
        projects: [ProjectTotals],
        providerCost: String = "10.00"
    ) -> FrameData {
        FrameData(
            tokens: "1M",
            cost: providerCost,
            burn: "1.5K",
            providers: [
                ProviderSlice(
                    id: ProviderID.claudeCode,
                    tokens: 1_000,
                    cost: Decimal(string: providerCost)!,
                    projects: projects
                )
            ],
            prevTokens: nil,
            prevCost: nil,
            keepAwake: .off,
            history: nil,
            projects: projects
        )
    }
}
