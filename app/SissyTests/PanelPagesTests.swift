import XCTest

@testable import Sissy

/// What the two panel surfaces read off one frame: the single headroom gauge
/// the Overview leads on, and the account and project split a provider's own
/// page prints.
final class PanelPagesTests: XCTestCase {
    private func frame(_ providers: [ProviderSlice]) -> FrameData {
        FrameData(
            tokens: "26K",
            cost: "0.09",
            burn: "1.5K",
            providers: providers,
            prevTokens: nil,
            prevCost: nil,
            keepAwake: .off,
            history: nil,
            projects: []
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

    /// The whole reason the Overview leads on one bar rather than four: a
    /// session bucket with room left says nothing while the weekly one behind
    /// it is nearly spent, and a headline that led on the roomier of the two
    /// would be reassuring and wrong.
    func testTheHeadroomGaugeIsTheWindowWithTheLeastLeft() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame([
                slice("claude-code", windows: [try window(300, 20), try window(10080, 95)])
            ]))

        let headroom = try XCTUnwrap(snapshot.headroom)
        XCTAssertEqual(headroom.window.percent, 95)
    }

    /// It crosses providers, because the constraint that binds is not
    /// necessarily the one belonging to whichever CLI is listed first.
    func testTheTightestWindowWinsAcrossProviders() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame([
                slice("claude-code", windows: [try window(300, 30)]),
                slice("codex", windows: [try window(300, 80)]),
            ]))

        let headroom = try XCTUnwrap(snapshot.headroom)
        XCTAssertEqual(headroom.providerID, "codex")
    }

    /// A gauge that does not say whose it is cannot be acted on: the two
    /// providers are recovered by different gestures and one of them is a
    /// setting the user may never have flipped.
    func testTheHeadroomGaugeNamesItsProvider() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame([slice("codex", windows: [try window(300, 40)])]))

        XCTAssertEqual(try XCTUnwrap(snapshot.headroom).providerName, "Codex")
    }

    /// Two windows equally spent are not equally urgent — the shorter one
    /// binds first, and it is the one the user meets sooner.
    func testATieGoesToTheShorterWindow() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame([
                slice("claude-code", windows: [try window(10080, 50), try window(300, 50)])
            ]))

        XCTAssertEqual(try XCTUnwrap(snapshot.headroom).window.id, 300)
    }

    func testNoProviderReportingAWindowLeavesNoHeadroomGauge() {
        let snapshot = UsagePanelSnapshot.make(frame: frame([slice("codex")]))

        XCTAssertNil(snapshot.headroom)
    }

    /// The Overview's gauge and the same gauge repeated on that provider's
    /// page are one object, down to the pace: deriving it twice is two
    /// readings that can disagree by a rounding.
    func testTheHeadroomGaugeIsTheProviderRowsOwnWindow() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame([slice("codex", windows: [try window(300, 44)])]))

        let headroom = try XCTUnwrap(snapshot.headroom)
        let row = try XCTUnwrap(snapshot.providers.first { $0.id == headroom.providerID })
        XCTAssertEqual(row.windows.first, headroom.window)
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
    func testAProviderPageCarriesItsOwnProjectSplit() throws {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame([
                slice(
                    "claude-code",
                    cost: "3.00",
                    projects: [
                        ProjectTotals(path: "/src/sissy", tokens: 800, cost: Decimal(2)),
                        ProjectTotals(path: "/src/legion", tokens: 200, cost: Decimal(1)),
                    ])
            ]))

        let projects = try XCTUnwrap(snapshot.providers.first?.projects)
        XCTAssertEqual(projects.map(\.name), ["sissy", "legion"])
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
