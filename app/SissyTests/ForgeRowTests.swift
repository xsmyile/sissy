import XCTest

@testable import Sissy

/// The forge rows the Overview draws, built from a frame.
///
/// Pure: a frame in, rows out, no engine and no network — the same division
/// every other panel-row test in here is on, so the wording and the
/// never-summed rule can be held without a poll.
final class ForgeRowTests: XCTestCase {
    private static let gitHub = ForgeConnection.gitHub()
    private static let gitLab = ForgeConnection(kind: .gitLab, host: "gitlab.example.com")
    private static let readAt = Date(timeIntervalSince1970: 1_789_600_000)

    private static func reading(
        _ connection: ForgeConnection, login: String, contributions: Int, merged: Int, issues: Int,
        at when: Date = readAt
    ) -> ForgeActivityReading {
        ForgeActivityReading(
            id: connection.id, kind: connection.kind, host: connection.host, login: login,
            activity: ForgeActivity(
                contributions: [.today: contributions], merged: [.today: merged],
                issues: [.today: issues],
                contributionsBoundedToOneYear: connection.kind == .gitHub),
            readAt: when, failure: nil)
    }

    /// The rows for a window, with an archive behind it.
    ///
    /// The rollup is not decoration: the snapshot only resolves a period the
    /// archive can answer, so without one every window would fall back to
    /// today and a test naming `.all` would silently assert about `.today`.
    /// That fallback is the forge block's own behaviour on a fresh install and
    /// it is deliberate — the block follows the control, and the control is
    /// about the money.
    private func rows(_ readings: [ForgeActivityReading], period: UsagePeriod = .today)
        -> [UsagePanelSnapshot.ForgeRow]
    {
        let history: [UsagePeriod: UsageHistoryRollup] = Dictionary(
            uniqueKeysWithValues: UsagePeriod.archived.map { period in
                (period, UsageHistoryRollup(period: period, earliestDay: nil, tokens: 1, cost: 1))
            })
        let frame = FrameBuilder.build(
            today: DayTotals(totalTokens: 0, totalCost: 0), hoursElapsed: 1, providers: [], history: history,
            forge: readings)
        return UsagePanelSnapshot.make(frame: frame, period: period, now: Self.readAt).forge
    }

    /// With no archive the control does not appear and every window is today,
    /// which is what the forge rows then answer too.
    func testWithNoArchiveTheRowsAnswerToday() {
        let frame = FrameBuilder.build(
            today: DayTotals(totalTokens: 0, totalCost: 0), hoursElapsed: 1, providers: [],
            forge: [
                Self.reading(
                    Self.gitHub, login: "xsmyile", contributions: 128, merged: 28, issues: 7)
            ])
        let snapshot = UsagePanelSnapshot.make(frame: frame, period: .all, now: Self.readAt)
        XCTAssertEqual(snapshot.period, .today)
        XCTAssertEqual(snapshot.forge.first?.contributions, "128")
    }

    func testTheRowPrintsEveryFigureAndTheAccountThatAnswered() throws {
        let row = try XCTUnwrap(
            rows([
                Self.reading(
                    Self.gitHub, login: "xsmyile", contributions: 128, merged: 28, issues: 7)
            ]).first)
        XCTAssertEqual(row.login, "xsmyile")
        XCTAssertEqual(row.contributions, "128")
        XCTAssertEqual(row.merged, "28")
        XCTAssertEqual(row.issues, "7")
        XCTAssertNil(row.notice)
    }

    /// The word left the row when the mark arrived, so the mark has to be able
    /// to introduce itself — and in the vendor's own noun, since a GitLab row
    /// saying "pull requests" is naming something that forge does not have.
    func testEachMarkCarriesItsOwnMeaningInTheVendorsNoun() throws {
        let both = rows([
            Self.reading(Self.gitHub, login: "xsmyile", contributions: 128, merged: 28, issues: 7),
            Self.reading(Self.gitLab, login: "davide", contributions: 123, merged: 15, issues: 17),
        ])
        XCTAssertEqual(both.first?.mergedHelp, "Pull requests you opened and had merged")
        XCTAssertEqual(both.last?.mergedHelp, "Merge requests you opened and had merged")
        XCTAssertEqual(both.first?.issuesHelp, "Issues you opened on GitHub")
        XCTAssertEqual(both.last?.issuesHelp, "Issues you opened on GitLab")
    }

    /// Never summed: two vendors counting two different things are two
    /// readings, and a total across them would belong to neither.
    func testTwoConnectionsStayTwoRows() {
        let both = rows([
            Self.reading(Self.gitHub, login: "xsmyile", contributions: 128, merged: 28, issues: 7),
            Self.reading(Self.gitLab, login: "davide", contributions: 123, merged: 15, issues: 17),
        ])
        XCTAssertEqual(both.count, 2)
        XCTAssertEqual(both.map(\.contributions), ["128", "123"])
        XCTAssertEqual(both.map(\.merged), ["28", "15"])
    }

    /// A reading that never arrived gets a dash and the reason, never a zero.
    /// This user's own GitLab is reached over a tunnel, so a laptop off the VPN
    /// would otherwise report a day with no work in it.
    func testAConnectionThatNeverAnsweredGetsNoFiguresAndAReason() throws {
        let row = try XCTUnwrap(
            rows([.unavailable(Self.gitLab, failure: .unreachable, at: Self.readAt)]).first)
        XCTAssertFalse(row.hasFigures)
        XCTAssertEqual(row.notice, "could not be reached")
    }

    /// Stale figures keep their place and grow a caption with their age.
    func testStaleFiguresKeepTheirPlaceAndSayHowOldTheyAre() throws {
        let stale = ForgeActivityReading(
            id: Self.gitHub.id, kind: .gitHub, host: Self.gitHub.host, login: "xsmyile",
            activity: ForgeActivity(
                contributions: [.today: 128], merged: [.today: 28], issues: [.today: 7],
                contributionsBoundedToOneYear: true),
            readAt: Self.readAt.addingTimeInterval(-7200), failure: .unreachable)
        let row = try XCTUnwrap(rows([stale]).first)
        XCTAssertEqual(row.contributions, "128")
        XCTAssertEqual(row.notice, "last read 2h ago")
    }

    /// A window the vendor answered nothing for is absent rather than zero, so
    /// the row falls back to the dash rather than claiming a quiet month.
    func testAWindowWithNoAnswerGetsNoFigure() throws {
        let row = try XCTUnwrap(
            rows(
                [
                    Self.reading(
                        Self.gitHub, login: "xsmyile", contributions: 128, merged: 28, issues: 7)
                ],
                period: .thirtyDays
            ).first)
        XCTAssertFalse(row.hasFigures)
    }

    /// The widest window is the one place `All` means two things on GitHub, so
    /// the hover says which half reaches how far back.
    func testTheWidestWindowSaysTheContributionsReachBackAYear() throws {
        let row = try XCTUnwrap(
            rows(
                [
                    Self.reading(
                        Self.gitHub, login: "xsmyile", contributions: 4138, merged: 403, issues: 188)
                ],
                period: .all
            ).first)
        XCTAssertTrue(row.tooltip.contains("one year"), row.tooltip)
    }
}
