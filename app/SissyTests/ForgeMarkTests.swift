import XCTest

@testable import Sissy

/// Which forge mark a repository card draws, which is a reading of the host
/// and nothing else.
final class ForgeMarkTests: XCTestCase {

    func testTheTwoForgesSissyShipsAMarkForAreNamedByTheirOwnDomain() {
        XCTAssertEqual(ForgeMark.assetName(forHost: "github.com"), "ForgeMarkGitHub")
        XCTAssertEqual(ForgeMark.assetName(forHost: "gitlab.com"), "ForgeMarkGitLab")
    }

    /// A self-hosted GitLab is the ordinary case at work, and it is as much
    /// GitLab as gitlab.com is.
    func testASelfHostedForgeIsRecognisedByTheNameInItsHost() {
        XCTAssertEqual(ForgeMark.assetName(forHost: "gitlab.sermix.com"), "ForgeMarkGitLab")
    }

    /// A forge whose host says neither gets the generic glyph rather than a
    /// guess between the two — a GitHub Enterprise on a company domain is not
    /// distinguishable from a Gitea by its name.
    func testAForgeThatNamesNeitherGetsNoMark() {
        XCTAssertNil(ForgeMark.assetName(forHost: "git.company.com"))
    }

    /// A host naming both answers the one the match leads with, so a mirror
    /// cannot make the mark depend on the order two branches happen to run in.
    func testAHostNamingBothForgesAnswersGitHub() {
        XCTAssertEqual(
            ForgeMark.assetName(forHost: "github.gitlab.example.com"), "ForgeMarkGitHub")
    }

    func testTheMatchIgnoresCase() {
        XCTAssertEqual(ForgeMark.assetName(forHost: "GitHub.com"), "ForgeMarkGitHub")
    }
}
