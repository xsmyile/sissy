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
        comments: Int? = nil, at when: Date = readAt
    ) -> ForgeActivityReading {
        ForgeActivityReading(
            id: connection.id, kind: connection.kind, host: connection.host, login: login,
            activity: ForgeActivity(
                contributions: [.today: contributions], merged: [.today: merged],
                issues: [.today: issues],
                comments: comments.map { [.today: $0] } ?? [:],
                contributionsBoundedToOneYear: connection.kind == .gitHub),
            readAt: when, failure: nil)
    }

    /// Midday on the same local day as `readAt`, for the tests that need a
    /// reading to be hours old *without* crossing midnight — `readAt` itself
    /// is just after 01:00, so subtracting two hours from it lands on the day
    /// before and the row would lose its figures to the roll-over rule.
    ///
    /// It is also the hour the age wording can be read at all: at 01:00 in this
    /// zone the vendor day `Today` names has not opened, so the row's caption
    /// is `ForgeWindow.opens`' sentence rather than an age. Those tests take
    /// this instant for that reason as well.
    private static let midday =
        Calendar.current.date(
            bySettingHour: 12, minute: 0, second: 0, of: readAt) ?? readAt

    /// A reading taken a day before `readAt`, answering both the day window and
    /// a wider one, so the roll-over can be held against each.
    ///
    /// A calendar day back rather than 24 hours, because the rule is about the
    /// local day and a clock-change day is 23 or 25 hours long — which is also
    /// why nothing here asserts the age to the hour.
    private static func yesterdaysReading() -> ForgeActivityReading {
        let yesterday =
            Calendar.current.date(byAdding: .day, value: -1, to: readAt) ?? readAt
        return ForgeActivityReading(
            id: gitHub.id, kind: .gitHub, host: gitHub.host, login: "xsmyile",
            activity: ForgeActivity(
                contributions: [.today: 128, .sevenDays: 900], merged: [.today: 28],
                issues: [.today: 7], comments: [:], contributionsBoundedToOneYear: true),
            readAt: yesterday, failure: nil)
    }

    /// The rows for a window, with an archive behind it.
    ///
    /// The rollup is not decoration: the snapshot only resolves a period the
    /// archive can answer, so without one every window would fall back to
    /// today and a test naming `.all` would silently assert about `.today`.
    /// That fallback is the forge block's own behaviour on a fresh install and
    /// it is deliberate — the block follows the control, and the control is
    /// about the money.
    private func rows(
        _ readings: [ForgeActivityReading], period: UsagePeriod = .today,
        now: Date = ForgeRowTests.readAt
    ) -> [UsagePanelSnapshot.ForgeRow] {
        let history: [UsagePeriod: UsageHistoryRollup] = Dictionary(
            uniqueKeysWithValues: UsagePeriod.archived.map { period in
                (period, UsageHistoryRollup(period: period, earliestDay: nil, tokens: 1, cost: 1))
            })
        let frame = FrameBuilder.build(
            today: DayTotals(totalTokens: 0, totalCost: 0), hoursElapsed: 1, providers: [], history: history,
            forge: readings)
        return UsagePanelSnapshot.make(frame: frame, period: period, now: now).forge
    }

    /// The caption the row draws, which the view words on its own clock rather
    /// than taking pre-built off the snapshot — so the age advances between
    /// two frames five to thirty minutes apart.
    private func notice(
        _ row: UsagePanelSnapshot.ForgeRow, refreshing: Bool = false,
        now: Date = ForgeRowTests.readAt
    ) -> String? {
        UsageFormat.forgeNotice(
            row.failure, readAt: row.readAt, opensAt: row.opensAt, refreshing: refreshing, now: now)
    }

    /// A window the vendor has not begun counting says so, rather than dating
    /// a reading it does not have. The dash beside it is the absence of a
    /// figure; this is why there is one.
    func testAWindowTheVendorHasNotOpenedSaysWhenItDoes() {
        XCTAssertEqual(
            UsageFormat.forgeNotice(
                nil, readAt: Self.readAt, opensAt: Self.readAt.addingTimeInterval(59 * 60),
                refreshing: false, now: Self.readAt),
            "counted in UTC days · today opens in 59m")
    }

    /// A refused token outranks it: nobody can read a window whose credential
    /// the vendor is turning away, and that one has something to do about it.
    func testARefusalOutranksAWindowThatHasNotOpened() throws {
        let notice = try XCTUnwrap(
            UsageFormat.forgeNotice(
                .unauthorized, readAt: Self.readAt,
                opensAt: Self.readAt.addingTimeInterval(59 * 60), refreshing: false,
                now: Self.readAt))
        XCTAssertFalse(notice.contains("UTC"), notice)
        XCTAssertTrue(notice.contains("last read"), notice)
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
                    Self.gitHub, login: "xsmyile", contributions: 128, merged: 28, issues: 7,
                    comments: 12)
            ]).first)
        XCTAssertEqual(row.login, "xsmyile")
        XCTAssertEqual(row.contributions, "128")
        XCTAssertEqual(row.merged, "28")
        XCTAssertEqual(row.issues, "7")
        XCTAssertEqual(row.comments, "12")
    }

    /// **A row that is fine says how old it is too.** The poll runs every five
    /// to thirty minutes and these counters move the moment the user pushes,
    /// so a figure with no date beside it cannot be told from one taken before
    /// the merge they are looking at.
    func testAHealthyRowIsDatedRatherThanSilent() throws {
        let row = try XCTUnwrap(
            rows(
                [
                    Self.reading(
                        Self.gitHub, login: "xsmyile", contributions: 128, merged: 28, issues: 7,
                        at: Self.midday.addingTimeInterval(-720))
                ], now: Self.midday
            ).first)
        XCTAssertEqual(notice(row, now: Self.midday), "read 12m ago")
    }

    /// While a refresh is in flight the row says that instead of an age it is
    /// about to replace, which is the wording the panel header already uses.
    func testARowBeingRefreshedSaysSoInsteadOfItsAge() throws {
        let row = try XCTUnwrap(
            rows([
                Self.reading(Self.gitHub, login: "xsmyile", contributions: 128, merged: 28, issues: 7)
            ]).first)
        XCTAssertEqual(notice(row, refreshing: true), "refreshing…")
    }

    /// The hover names the right-click, because the row has nowhere to put a
    /// button and a gesture nothing advertises is one nobody finds.
    func testTheHoverNamesTheRightClick() throws {
        let row = try XCTUnwrap(
            rows([
                Self.reading(Self.gitHub, login: "xsmyile", contributions: 128, merged: 28, issues: 7)
            ]).first)
        XCTAssertTrue(row.tooltip.contains("Right-click to refresh now"), row.tooltip)
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
        XCTAssertEqual(
            both.first?.commentsHelp, "Comments you wrote on issues and pull requests")
        XCTAssertEqual(
            both.last?.commentsHelp, "Comments you wrote on issues and merge requests")
    }

    /// A comment count the page could not prove drops off the row on its own,
    /// and the three figures beside it stay.
    ///
    /// This is the one counter that can go missing while the rest answer —
    /// GitHub's page proves its own coverage and a busy month can outrun it —
    /// so the row has to degrade to three figures rather than to a dash.
    func testAMissingCommentCountLeavesTheOtherFiguresStanding() throws {
        let row = try XCTUnwrap(
            rows([
                Self.reading(
                    Self.gitHub, login: "xsmyile", contributions: 128, merged: 28, issues: 7,
                    comments: nil)
            ]).first)
        XCTAssertTrue(row.hasFigures)
        XCTAssertNil(row.comments)
        XCTAssertEqual(row.contributions, "128")
        XCTAssertEqual(row.merged, "28")
        XCTAssertEqual(row.issues, "7")
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
        XCTAssertNil(row.readAt)
        XCTAssertEqual(notice(row), "could not be reached")
    }

    /// Stale figures keep their place and the caption carries both halves: the
    /// reason and the age. The age alone stood for the failure while a healthy
    /// row was silent, and now that one is dated too it would read as an
    /// ordinary reading that happened to be old.
    ///
    /// Stale is within the day. On `Today` a failure carrying figures from
    /// *before* midnight loses them anyway — the roll-over outranks this,
    /// because yesterday's numbers under today's heading are wrong whether or
    /// not the last attempt worked. Hence the midday fixture: `readAt` is just
    /// after 01:00, so two hours before it is the previous day and this would
    /// be asserting the roll-over rather than staleness.
    func testStaleFiguresKeepTheirPlaceAndSayWhyAndHowOld() throws {
        let stale = ForgeActivityReading(
            id: Self.gitHub.id, kind: .gitHub, host: Self.gitHub.host, login: "xsmyile",
            activity: ForgeActivity(
                contributions: [.today: 128], merged: [.today: 28], issues: [.today: 7],
                comments: [.today: 3], contributionsBoundedToOneYear: true),
            readAt: Self.midday.addingTimeInterval(-7200), failure: .unreachable)
        let row = try XCTUnwrap(rows([stale], now: Self.midday).first)
        XCTAssertEqual(row.contributions, "128")
        XCTAssertEqual(
            notice(row, now: Self.midday), "could not be reached · last read 2h ago")
    }

    /// **A reading from before midnight loses `Today`.** Every figure is over a
    /// window worked out from the instant it was asked for, so yesterday's
    /// `Today` is the whole of yesterday under a heading naming this morning.
    /// The dash is the same one a reading that never arrived gets, and the
    /// caption says how long ago the last one was.
    func testAReadingFromAnEarlierDayLosesToday() throws {
        let row = try XCTUnwrap(rows([Self.yesterdaysReading()], now: Self.midday).first)
        XCTAssertFalse(row.hasFigures)
        XCTAssertEqual(row.login, "xsmyile")
        XCTAssertEqual(
            notice(row, now: Self.midday)?.hasPrefix("read "), true,
            notice(row, now: Self.midday) ?? "nil")
    }

    /// The wider windows have only *moved*, so they keep their figures. Seven
    /// days ending yesterday still covers six of the seven and `all` has no
    /// start to move at all; they are stale rather than wrong, and the age on
    /// the row is what says by how much.
    func testAReadingFromAnEarlierDayKeepsTheWiderWindows() throws {
        let row = try XCTUnwrap(
            rows([Self.yesterdaysReading()], period: .sevenDays).first)
        XCTAssertEqual(row.contributions, "900")
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
