import XCTest

@testable import Sissy

/// What the panel says about where a day's money went: which rows exist, what
/// they are called, and that they still add up to the day after the tail of
/// them has been folded away and whatever named no repository has been given
/// the row it is owed.
final class UsageProjectRowsTests: XCTestCase {
    func testADayWithNoProjectNamedDrawsNoSection() {
        let snapshot = UsagePanelSnapshot.make(frame: frame(projects: []))

        XCTAssertTrue(snapshot.projects.isEmpty)
    }

    func testARowIsNamedAfterTheRepositoryAndKeepsThePathForTheTooltip() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(projects: [project("/Users/d/mdev/legion", 900, "6.00")]))

        XCTAssertEqual(snapshot.projects.map(\.name), ["legion"])
        XCTAssertEqual(snapshot.projects.map(\.tooltip), ["/Users/d/mdev/legion"])
    }

    func testTheTailOfALongListIsFoldedIntoOneRowThatStillCounts() {
        let many = (1...9).map { project("/Users/d/repo\($0)", 100, "1.00") }
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

    /// The gap between the header and the rows is the question a user asks
    /// out loud, so the panel answers it in a row instead of leaving it to
    /// arithmetic nobody should have to do.
    func testWhatNamedNoRepositoryGetsTheRestOfTheDayRatherThanSilence() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(
                projects: [project("/Users/d/sissy", 750, "7.50")],
                providerTokens: 1_000,
                providerCost: "10.00"))

        XCTAssertEqual(snapshot.projects.map(\.name), ["sissy", "Unattributed"])
        XCTAssertEqual(snapshot.projects.last?.cost, "$2.50")
        XCTAssertEqual(snapshot.projects.last?.tokens, "250")
        XCTAssertEqual(Int((snapshot.projects.last?.share ?? 0) * 100), 25)
    }

    /// The rows and the header can be read an instant apart — the split is
    /// republished on every read of a provider's day, the totals beside it
    /// only on an emit — so the two halves of a remainder can disagree about
    /// its sign. That is a reading that disagrees with itself, not money.
    func testARemainderThatCameOutNegativeIsNotDrawn() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(
                projects: [project("/Users/d/sissy", 250, "9.00")],
                providerTokens: 1_000,
                providerCost: "6.00"))

        XCTAssertEqual(snapshot.projects.map(\.name), ["sissy"])
    }

    /// It is not a project, so it never wears a project's name or a path it
    /// could be mistaken for.
    func testTheRemainderHoversTheReasonRatherThanAPath() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(
                projects: [project("/Users/d/sissy", 750, "7.50")],
                providerTokens: 1_000,
                providerCost: "10.00"))

        let reason = try XCTUnwrap(snapshot.projects.last?.tooltip)
        XCTAssertEqual(reason, UsageFormat.projectsUnattributedReason)
        XCTAssertFalse(reason.hasPrefix("/"), "the remainder hovered something that reads as a path")
    }

    func testADayEveryLineOfWhichNamedARepositoryHasNoRemainderRow() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(
                projects: [
                    project("/Users/d/sissy", 750, "7.50"),
                    project("/Users/d/legion", 250, "2.50"),
                ]))

        XCTAssertEqual(snapshot.projects.map(\.name), ["sissy", "legion"])
    }

    /// The row limit bounds the repositories. The remainder is the rest of the
    /// day, not a repository competing for a slot, so folding never swallows
    /// it and it never costs a project its row.
    func testTheRemainderDoesNotSpendAProjectsRow() {
        let many = (1...9).map { project("/Users/d/repo\($0)", 100, "1.00") }
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(projects: many, providerTokens: 1_000, providerCost: "10.00"))

        XCTAssertEqual(snapshot.projects.count, 6)
        XCTAssertEqual(snapshot.projects[4].name, "5 more projects")
        XCTAssertEqual(snapshot.projects[5].name, "Unattributed")
        XCTAssertEqual(snapshot.projects[5].cost, "$1.00")
    }

    /// A section whose only row says "unattributed" is the header total with a
    /// second caption under it.
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
            tokens: "1M",
            cost: FrameBuilder.fmtCost(cost),
            burn: "1.5K",
            providers: [
                ProviderSlice(
                    id: ProviderID.claudeCode,
                    tokens: tokens,
                    cost: cost,
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
