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
        limitsState: ProviderLimitsState = .quiet
    ) -> ProviderSlice {
        ProviderSlice(
            id: id,
            tokens: tokens,
            cost: Decimal(string: cost)!,
            windows: windows,
            plan: plan,
            projects: projects,
            account: account,
            limitsState: limitsState
        )
    }

    private func window(_ minutes: Int, _ usedPercent: Double) throws -> UsageWindow {
        try XCTUnwrap(
            UsageWindow(
                minutes: minutes,
                usedPercent: usedPercent,
                resetsAt: Date(timeIntervalSince1970: 1_789_006_037)
            ))
    }

    // MARK: Headroom

    /// The window a provider leads on is the one it is closest to running out
    /// of, not the shortest it reports: a session bucket nobody has started
    /// sits at 0% with no reset and says nothing while the weekly one behind
    /// it is nearly spent.
    func testTheBindingWindowIsTheOneWithTheLeastLeft() throws {
        let windows = UsagePanelSnapshot.make(
            frame: frame([
                slice("claude-code", windows: [try window(300, 20), try window(10080, 95)])
            ])
        ).providers[0].windows

        XCTAssertEqual(UsagePanelSnapshot.binding(windows)?.percent, 95)
    }

    /// Two windows equally spent are not equally urgent — the shorter one
    /// binds first, and it is the one the user meets sooner.
    func testATieGoesToTheShorterWindow() throws {
        let windows = UsagePanelSnapshot.make(
            frame: frame([
                slice("claude-code", windows: [try window(10080, 50), try window(300, 50)])
            ])
        ).providers[0].windows

        XCTAssertEqual(UsagePanelSnapshot.binding(windows)?.id, "300-")
    }

    func testAProviderReportingNoWindowHasNoneThatBinds() {
        let windows = UsagePanelSnapshot.make(frame: frame([slice("codex")])).providers[0].windows

        XCTAssertNil(UsagePanelSnapshot.binding(windows))
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
