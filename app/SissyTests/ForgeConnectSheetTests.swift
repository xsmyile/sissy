import XCTest

@testable import Sissy

/// Which of the tokens `gh` and `glab` hold the connect sheet puts on screen.
///
/// Pure: candidates and connections in, candidates out — no keychain, no
/// subprocess and no window, which is the division the rest of the forge tests
/// are on.
final class ForgeConnectSheetTests: XCTestCase {
    private static let gitHub = ForgeConnection.gitHub()
    private static let gitLab = ForgeConnection(kind: .gitLab, host: "gitlab.example.com")

    private static func candidate(_ connection: ForgeConnection) -> ForgeTokenCandidate {
        ForgeTokenCandidate(
            kind: connection.kind, host: connection.host, configuredAccount: nil,
            token: "token-for-\(connection.id)")
    }

    private func offered(
        _ candidates: [ForgeConnection], for request: ForgeConnectRequest,
        connected: [ForgeConnection]
    ) -> [String] {
        ForgeConnectSheet.offered(
            candidates.map(Self.candidate), for: request, connected: connected
        ).map(\.id)
    }

    /// The whole point: a host the user has already connected is not offered a
    /// second time. Pressing it replaced that row's token and closed the sheet,
    /// so the only visible outcome was a list that had not changed.
    func testAConnectedHostIsNotOfferedAgain() {
        XCTAssertEqual(
            offered([Self.gitHub, Self.gitLab], for: .new, connected: [Self.gitHub]),
            [Self.gitLab.id])
    }

    func testEveryCandidateIsOfferedWhenNothingIsConnected() {
        XCTAssertEqual(
            offered([Self.gitHub, Self.gitLab], for: .new, connected: []),
            [Self.gitHub.id, Self.gitLab.id])
    }

    /// One CLI's host is not the other's. Matching on the bare host would hide
    /// a `glab` token behind a GitHub connection on a machine where a company
    /// runs both under one name.
    func testAHostConnectedForOneForgeDoesNotHideTheOther() {
        let gitLabOnTheSameHost = ForgeConnection(kind: .gitLab, host: Self.gitHub.host)
        XCTAssertEqual(
            offered([gitLabOnTheSameHost], for: .new, connected: [Self.gitHub]),
            [gitLabOnTheSameHost.id])
    }

    /// A sheet opened to replace one connection's token offers that host and
    /// nothing else: every other candidate would be a different connection,
    /// which is not what `Reconnect…` was pressed for.
    func testAReplacementOffersItsOwnHostAlone() {
        XCTAssertEqual(
            offered(
                [Self.gitHub, Self.gitLab], for: ForgeConnectRequest(replacing: Self.gitLab),
                connected: [Self.gitHub, Self.gitLab]),
            [Self.gitLab.id])
    }

    /// A replacement for a host neither CLI holds a token for offers nothing,
    /// and the sheet is then the paste field alone — which is the only road
    /// left for a token minted in a browser.
    func testAReplacementWithNoCandidateOffersNothing() {
        XCTAssertEqual(
            offered(
                [Self.gitHub], for: ForgeConnectRequest(replacing: Self.gitLab),
                connected: [Self.gitHub, Self.gitLab]),
            [])
    }

    /// The two sheets are keyed apart, or opening the addition after a
    /// replacement would present the one SwiftUI already had.
    func testTheAdditionAndAReplacementAreDifferentSheets() {
        XCTAssertNotEqual(ForgeConnectRequest.new.id, ForgeConnectRequest(replacing: Self.gitHub).id)
    }

    // MARK: The fields

    /// The defect: the host stayed on `github.com` when GitLab was picked, and
    /// a GitLab token pasted under it was sent to GitHub on every poll.
    func testPickingGitLabPutsGitLabsHostInTheField() {
        var draft = ForgeConnectDraft()
        draft.pick(.gitLab)
        XCTAssertEqual(draft.host, GitLabActivityFeed.dotComHost)
    }

    func testPickingAForgeReplacesAHostTheUserTyped() {
        var draft = ForgeConnectDraft()
        draft.pick(.gitLab)
        draft.host = "gitlab.corp.example"
        draft.path = "gitlab"
        draft.pick(.gitHub)
        XCTAssertEqual(draft.host, GitHubActivityFeed.dotComHost)
        XCTAssertEqual(draft.path, "")
    }

    /// A click on the segment already picked is not a change of forge, and
    /// must not throw away what was typed.
    func testPickingTheSameForgeKeepsTheTypedHost() {
        var draft = ForgeConnectDraft()
        draft.pick(.gitLab)
        draft.host = "gitlab.corp.example"
        draft.pick(.gitLab)
        XCTAssertEqual(draft.host, "gitlab.corp.example")
    }

    func testAHostThatCannotBeConnectedSaysWhyUnderTheFields() {
        var draft = ForgeConnectDraft()
        draft.pick(.gitLab)
        draft.host = "davide@gitlab.corp.example"
        XCTAssertEqual(draft.problem, .credentials)
    }

    /// An empty field is one the user has not reached yet: Connect is already
    /// disabled, and a red sentence under it would scold an untouched sheet.
    func testAnEmptyHostSaysNothingUnderTheFields() {
        var draft = ForgeConnectDraft()
        draft.host = ""
        XCTAssertNil(draft.problem)
    }

    /// A sheet opened to replace a connection's token holds that connection's
    /// own address, and reads back as that very connection.
    func testAReplacementDraftReadsBackAsItsConnection() throws {
        let offDefault = ForgeConnection(
            kind: .gitLab, host: "gitlab.corp.example", port: 8443, basePath: "/gitlab")
        XCTAssertEqual(try ForgeConnectDraft(replacing: offDefault).connection.get(), offDefault)
    }

    // MARK: What the sheet says

    func testEveryAddressProblemHasItsOwnSentence() {
        let sentences = ForgeAddressProblem.allCases.map(ForgeConnectCopy.addressProblem)
        XCTAssertEqual(Set(sentences).count, ForgeAddressProblem.allCases.count)
    }

    func testAnOrphanedTokenIsTitledByItsForgeAndAddress() {
        XCTAssertEqual(ForgeConnectCopy.orphanTitle(Self.gitLab.id), "GitLab · gitlab.example.com")
    }
}
