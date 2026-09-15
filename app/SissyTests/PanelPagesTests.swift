import XCTest

@testable import Sissy

/// What the two panel surfaces read off one frame: which window a provider
/// leads on, and the account and project split its own page prints.
final class PanelPagesTests: XCTestCase {
    /// Built the way the engine builds one, so the combined project list is
    /// the slices summed rather than something a fixture asserted into
    /// existence — a frame whose providers spend on projects and whose
    /// `projects` is empty cannot happen outside a test.
    private func frame(_ providers: [ProviderSlice]) -> FrameData {
        FrameData(
            tokens: providers.reduce(0) { $0 + $1.tokens },
            cost: providers.reduce(Decimal(0)) { $0 + $1.cost },
            burn: 1500,
            providers: providers,
            keepAwake: .off,
            history: nil,
            projects: FrameBuilder.combinedProjects(providers)
        )
    }

    private func slice(
        _ id: String,
        tokens: Int = 1000,
        cost: String = "1.00",
        windows: [UsageWindow] = [],
        plan: String? = nil,
        account: ProviderAccount? = nil,
        projects: [ProjectTotals] = [],
        limitsState: ProviderLimitsState = .quiet,
        limitsObservedAt: Date? = nil
    ) -> ProviderSlice {
        ProviderSlice(
            id: id,
            tokens: tokens,
            cost: Decimal(string: cost)!,
            windows: windows,
            plan: plan,
            projects: projects,
            account: account,
            limitsState: limitsState,
            limitsObservedAt: limitsObservedAt
        )
    }

    /// The instant every window fixture is placed against, so a pace the panel
    /// derives is a property of the fixture and not of the day the suite runs
    /// on. The reset that used to be hard-coded here fell into the past, which
    /// left both headroom tests silently exercising the no-projection branch.
    private static let now = Date(timeIntervalSince1970: 1_789_000_000)

    /// A window `elapsed` of the way through its own period. The default sits
    /// exactly on the reset, which is a window with nothing left to project
    /// from — the shape the percentage fallback is for.
    private func window(
        _ minutes: Int, _ usedPercent: Double, elapsed: Double = 1
    ) throws -> UsageWindow {
        try XCTUnwrap(
            UsageWindow(
                minutes: minutes,
                usedPercent: usedPercent,
                resetsAt: Self.now.addingTimeInterval(Double(minutes) * 60 * (1 - elapsed))
            ))
    }

    private func windows(
        _ windows: [UsageWindow], observedAt: Date? = nil
    ) -> [UsagePanelSnapshot.WindowRow] {
        UsagePanelSnapshot.make(
            frame: frame([
                slice("claude-code", windows: windows, limitsObservedAt: observedAt)
            ]),
            now: Self.now
        ).providers[0].windows
    }

    // MARK: Headroom

    /// The window a provider leads on is the one its own rate empties first,
    /// not the fullest it reports. A session at 40% four and a half hours into
    /// five lasts until its reset whatever the bar says; a weekly at 35% two
    /// days in does not, and it is the one the user actually meets.
    func testTheBindingWindowIsTheOneTheRateEmptiesFirst() throws {
        let rows = windows([
            try window(300, 40, elapsed: 0.9),
            try window(10080, 35, elapsed: 0.2),
        ])

        XCTAssertNil(rows.first { $0.minutes == 300 }?.pace?.runsOutAt)
        XCTAssertNotNil(rows.first { $0.minutes == 10080 }?.pace?.runsOutAt)
        XCTAssertEqual(UsagePanelSnapshot.binding(rows)?.minutes, 10080)
    }

    /// Two windows both heading for their cap are ranked by which arrives
    /// first, not by which bar is fuller: the weekly here is the more spent
    /// and the session is the one the user meets this afternoon.
    func testAmongWindowsHeadingForTheirCapTheSoonestLeads() throws {
        let rows = windows([
            try window(300, 60, elapsed: 0.5),
            try window(10080, 80, elapsed: 0.7),
        ])

        let session = try XCTUnwrap(rows.first { $0.minutes == 300 }?.pace?.runsOutAt)
        let weekly = try XCTUnwrap(rows.first { $0.minutes == 10080 }?.pace?.runsOutAt)
        XCTAssertLessThan(session, weekly)
        XCTAssertEqual(UsagePanelSnapshot.binding(rows)?.minutes, 300)
    }

    /// Two windows that run out at the same instant are not equally urgent
    /// either — the shorter period is the one met sooner, and it leads.
    ///
    /// Built row by row rather than from a window fixture: two run-outs land
    /// on the same instant only for one exact pair of rates, and a test that
    /// has to solve for it asserts a date equality that floating point owes it
    /// no answer on.
    func testTwoWindowsRunningOutTogetherGoToTheShorterPeriod() {
        let runsOut = Self.now.addingTimeInterval(3600)
        let rows = [(10080, 90), (300, 40)].map { minutes, percent in
            UsagePanelSnapshot.WindowRow(
                id: "\(minutes)-",
                minutes: minutes,
                label: "",
                percent: percent,
                fraction: Double(percent) / 100,
                resetsAt: Self.now.addingTimeInterval(7200),
                pace: UsagePanelSnapshot.Pace(
                    expectedFraction: 0.5, deltaPercent: 0, runsOutAt: runsOut))
        }

        XCTAssertEqual(UsagePanelSnapshot.binding(rows)?.minutes, 300)
    }

    /// A window that survives its own reset does not bind at all, however full
    /// it is — and when no window projects a run-out, the most spent leads.
    func testWithNoProjectionTheMostSpentWindowLeads() throws {
        let rows = windows([try window(300, 20), try window(10080, 95)])

        XCTAssertTrue(rows.allSatisfy { $0.pace == nil })
        XCTAssertEqual(UsagePanelSnapshot.binding(rows)?.percent, 95)
    }

    /// Two windows equally spent are not equally urgent — the shorter one
    /// binds first, and it is the one the user meets sooner.
    func testATieGoesToTheShorterWindow() throws {
        let rows = windows([try window(10080, 50), try window(300, 50)])

        XCTAssertTrue(rows.allSatisfy { $0.pace == nil })
        XCTAssertEqual(UsagePanelSnapshot.binding(rows)?.id, "300-")
    }

    func testAProviderReportingNoWindowHasNoneThatBinds() {
        let rows = UsagePanelSnapshot.make(frame: frame([slice("codex")])).providers[0].windows

        XCTAssertNil(UsagePanelSnapshot.binding(rows))
    }

    /// The pace is measured from when the vendor's percentage was taken, not
    /// from the clock. Codex publishes its windows only on the CLI's own
    /// turns, so an idle Mac holds a reading for hours — against the clock the
    /// mark walks right while the bar stands still and the row grows a reserve
    /// nothing measured.
    func testPaceIsMeasuredFromTheReadingRatherThanTheClock() throws {
        let sixHours: TimeInterval = 6 * 60 * 60
        let rows = windows(
            [try window(10080, 35, elapsed: 0.2)],
            observedAt: Self.now.addingTimeInterval(-sixHours))

        XCTAssertEqual(rows[0].pace?.deltaPercent, 19)
    }

    func testPaceFallsBackToTheClockWhenTheVendorNamedNoReadingTime() throws {
        let rows = windows([try window(10080, 35, elapsed: 0.2)])

        XCTAssertEqual(rows[0].pace?.deltaPercent, 15)
    }

    // MARK: The open page

    private func row(_ id: String) -> UsagePanelSnapshot.ProviderRow {
        UsagePanelSnapshot.make(frame: frame([slice(id)])).providers[0]
    }

    /// A provider can leave the frame while its page is open — the slices are
    /// today's spenders, and a day rolls over under an open popover. The page
    /// falls back home rather than rendering a row that no longer exists.
    func testAPageWhoseProviderLeftTheFrameFallsBackHome() {
        XCTAssertNil(UsagePanelView.openRow(.provider("codex"), in: [row("claude-code")]))
    }

    func testThePageResolvesToItsOwnProvider() {
        let open = UsagePanelView.openRow(
            .provider("codex"), in: [row("claude-code"), row("codex")])

        XCTAssertEqual(open?.id, "codex")
    }

    func testTheOverviewResolvesToNoProvider() {
        XCTAssertNil(UsagePanelView.openRow(.overview, in: [row("codex")]))
    }

    // MARK: Attention on the Overview

    /// The split must not hide what the notice exists to show. The grant
    /// lapses every time Claude Code refreshes its token, and a mark on the
    /// legend row is what stops a user who never opens that page from being
    /// back to gauges that silently went blank.
    func testALimitsProblemIsVisibleWithoutOpeningTheProvider() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame([slice("claude-code", limitsState: .needsAuthorization)]))

        XCTAssertNotNil(try XCTUnwrap(snapshot.providers.first).notice)
    }

    func testAProviderWithNothingWrongCarriesNoMark() throws {
        let snapshot = UsagePanelSnapshot.make(frame: frame([slice("codex")]))

        XCTAssertNil(try XCTUnwrap(snapshot.providers.first).notice)
    }

    // MARK: Account

    func testAProviderPageCarriesTheAddressItIsSignedInAs() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame([
                slice("claude-code", account: ProviderAccount(email: "me@example.com"))
            ]))

        XCTAssertEqual(try XCTUnwrap(snapshot.providers.first?.account).email, "me@example.com")
    }

    /// The badge above the line already says the seat, so an account that
    /// answers for nothing else carries no line at all rather than a blank
    /// one.
    func testAnAccountThatOnlyNamesASeatCarriesNoLine() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame([
                slice("claude-code", plan: "team", account: ProviderAccount(seat: "team_tier_1"))
            ]))

        XCTAssertNil(snapshot.providers.first?.account)
    }

    func testAProviderWhoseFilesNameNobodyCarriesNoAccount() {
        let snapshot = UsagePanelSnapshot.make(frame: frame([slice("codex")]))

        XCTAssertNil(snapshot.providers.first?.account)
    }

    // MARK: Per-provider projects

    /// The page prints this provider's own split, which the slice already
    /// carries. The Overview's list is the two summed, and repeating it here
    /// would answer a question nobody asked on this page.
    ///
    /// The slice arrives cheapest-first on purpose. A provider folds its day
    /// out of a dictionary, so the order it hands over is arbitrary, and a
    /// fixture that happens to pass them dearest-first asserts nothing.
    func testAProviderPageCarriesItsOwnProjectSplit() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame([
                slice(
                    "claude-code",
                    cost: "3.00",
                    projects: [
                        ProjectTotals(path: "/src/legion", tokens: 200, cost: Decimal(1)),
                        ProjectTotals(path: "/src/sissy", tokens: 800, cost: Decimal(2)),
                    ])
            ]))

        let projects = try XCTUnwrap(snapshot.providers.first?.projects)
        XCTAssertEqual(projects.map(\.name), ["sissy", "legion"])
    }

    /// Both surfaces read one project list through one ordering, so a page
    /// and the Overview behind it never disagree about which project the day
    /// went to.
    func testAPageAndTheOverviewAgreeOnTheOrder() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame([
                slice(
                    "claude-code",
                    cost: "3.00",
                    projects: [
                        ProjectTotals(path: "/src/website", tokens: 200, cost: Decimal(1)),
                        ProjectTotals(path: "/src/sissy", tokens: 800, cost: Decimal(2)),
                    ])
            ]))

        let page = try XCTUnwrap(snapshot.providers.first?.projects)
        XCTAssertEqual(page.map(\.name), snapshot.projects.map(\.name))
    }

    /// Two accounts can hold a repository of the same name, so the row says
    /// whose it is. The name still comes from the directory: the owner is a
    /// prefix, never a replacement.
    func testAProjectRowCarriesTheAccountItsRepositoryBelongsTo() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame([
                slice(
                    "claude-code",
                    tokens: 300,
                    cost: "3.00",
                    projects: [
                        ProjectTotals(
                            path: "/src/website", tokens: 200, cost: Decimal(2),
                            owner: "radonforge"),
                        ProjectTotals(path: "/src/sissy", tokens: 100, cost: Decimal(1)),
                    ])
            ]))

        let page = try XCTUnwrap(snapshot.providers.first?.projects)
        XCTAssertEqual(page.map(\.name), ["website", "sissy"])
        XCTAssertEqual(page.map(\.owner), ["radonforge", nil])
    }

    /// The rows that stand for no single repository never claim an account.
    func testTheFoldedAndUnattributedRowsNameNoAccount() throws {
        let owned = (1...7).map {
            ProjectTotals(
                path: "/src/p\($0)", tokens: 10, cost: Decimal(1), owner: "radonforge")
        }
        let snapshot = UsagePanelSnapshot.make(
            frame: frame([slice("claude-code", tokens: 100, cost: "10.00", projects: owned)]))

        let page = try XCTUnwrap(snapshot.providers.first?.projects)
        XCTAssertEqual(page.count, 6)
        XCTAssertEqual(page[4].name, "3 more projects")
        XCTAssertNil(page[4].owner)
        XCTAssertEqual(page[5].name, UsageFormat.projectsUnattributed)
        XCTAssertNil(page[5].owner)
    }

    /// The fold keeps the dearest projects and pushes the rest into one row.
    /// Folding a prefix of an unordered list would hide the day's largest
    /// spender behind "N more projects" whenever it hashed late.
    func testTheFoldKeepsTheDearestProjectsNotTheFirstToArrive() throws {
        let cheap = (1...6).map {
            ProjectTotals(path: "/src/small-\($0)", tokens: 1, cost: Decimal(1))
        }
        let snapshot = UsagePanelSnapshot.make(
            frame: frame([
                slice(
                    "claude-code",
                    tokens: 806,
                    cost: "56.00",
                    projects: cheap + [
                        ProjectTotals(path: "/src/sissy", tokens: 800, cost: Decimal(50))
                    ])
            ]))

        let page = try XCTUnwrap(snapshot.providers.first?.projects)
        XCTAssertEqual(page.first?.name, "sissy")
    }

    /// Shares on the page are of that provider's own day, not of the
    /// combined one — a project that is all of Codex's spend reads as all of
    /// it, whatever Claude Code did beside it.
    func testAPageShareIsOfThatProvidersOwnDay() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame([
                slice("claude-code", cost: "9.00"),
                slice(
                    "codex", cost: "1.00",
                    projects: [ProjectTotals(path: "/src/sissy", tokens: 10, cost: Decimal(1))]),
            ]))

        let row = try XCTUnwrap(snapshot.providers.first { $0.id == "codex" })
        XCTAssertEqual(try XCTUnwrap(row.projects.first).share, 1.0, accuracy: 0.001)
    }

    func testAProviderWhoseFormatNamesNoDirectoryCarriesNoProjects() {
        let snapshot = UsagePanelSnapshot.make(frame: frame([slice("codex")]))

        XCTAssertEqual(snapshot.providers.first?.projects.count, 0)
    }
}
