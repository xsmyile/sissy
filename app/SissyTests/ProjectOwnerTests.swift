import XCTest

@testable import Sissy

/// The account a repository is pushed to, read off its `origin` remote — what
/// keeps two `website` checkouts under different accounts from rendering one
/// label.
final class ProjectOwnerTests: XCTestCase {

    // MARK: The two shapes git writes

    func testAnSCPStyleRemoteNamesItsAccount() {
        XCTAssertEqual(
            ProjectResolver.owner(ofRemoteURL: "git@github.com:radonforge/website.git"),
            "radonforge")
    }

    func testAnHTTPSRemoteNamesItsAccount() {
        XCTAssertEqual(
            ProjectResolver.owner(ofRemoteURL: "https://github.com/radonforge/website.git"),
            "radonforge")
    }

    func testARemoteWithoutTheGitSuffixNamesItsAccount() {
        XCTAssertEqual(
            ProjectResolver.owner(ofRemoteURL: "https://github.com/radonforge/website"),
            "radonforge")
    }

    func testAnSSHURLCarryingAPortNamesItsAccount() {
        XCTAssertEqual(
            ProjectResolver.owner(
                ofRemoteURL: "ssh://git@ssh.github.com:443/radonforge/website.git"),
            "radonforge")
    }

    /// A self-hosted GitLab is the case this has to get right for work, and
    /// the account is the group the repository sits directly under.
    func testASelfHostedForgeNamesTheGroup() {
        XCTAssertEqual(
            ProjectResolver.owner(ofRemoteURL: "git@gitlab.sermix.com:mastersoft/cbdesign.git"),
            "mastersoft")
    }

    /// Nested groups answer the one the repository sits directly under, not
    /// the whole hierarchy — that is the label a person says out loud.
    func testANestedGroupNamesTheInnermostOne() {
        XCTAssertEqual(
            ProjectResolver.owner(ofRemoteURL: "https://gitlab.com/group/sub/repo.git"), "sub")
    }

    // MARK: What must not be turned into an account

    /// A directory on this Mac is not a forge, so the enclosing folder must
    /// not be dressed up as an account.
    func testAPathRemoteNamesNobody() {
        XCTAssertNil(ProjectResolver.owner(ofRemoteURL: "/Users/d/repos/bare.git"))
    }

    /// `file://` is the same path wearing a scheme: its host is empty and its
    /// first segment is a directory.
    func testAFileURLRemoteNamesNobody() {
        XCTAssertNil(ProjectResolver.owner(ofRemoteURL: "file:///Users/d/repos/bare.git"))
    }

    func testARelativeRemoteNamesNobody() {
        XCTAssertNil(ProjectResolver.owner(ofRemoteURL: "../sibling"))
    }

    func testARemoteWithNoAccountSegmentNamesNobody() {
        XCTAssertNil(ProjectResolver.owner(ofRemoteURL: "git@github.com:website.git"))
    }

    func testAnEmptyRemoteNamesNobody() {
        XCTAssertNil(ProjectResolver.owner(ofRemoteURL: ""))
    }

    // MARK: Reading it off a repository

    func testARepositoryAnswersTheAccountItsOriginNames() throws {
        let repository = try makeRepository(
            config: """
                [core]
                	bare = false
                [remote "origin"]
                	url = git@github.com:radonforge/website.git
                	fetch = +refs/heads/*:refs/remotes/origin/*
                """)

        XCTAssertEqual(ProjectResolver().repositoryOwner(for: repository), "radonforge")
    }

    /// Only `origin` answers. A fork's `upstream` names somebody else's
    /// account, and labelling the row with it would attribute the work to
    /// them.
    func testARepositoryIgnoresEveryRemoteButOrigin() throws {
        let repository = try makeRepository(
            config: """
                [remote "upstream"]
                	url = git@github.com:someone-else/website.git
                [remote "origin"]
                	url = git@github.com:radonforge/website.git
                """)

        XCTAssertEqual(ProjectResolver().repositoryOwner(for: repository), "radonforge")
    }

    func testARepositoryWithNoOriginNamesNobody() throws {
        let repository = try makeRepository(
            config: """
                [core]
                	bare = false
                """)

        XCTAssertNil(ProjectResolver().repositoryOwner(for: repository))
    }

    /// A checkout that has been deleted since its rows were counted has no
    /// config left to read, and the row keeps the plain name it has.
    func testAGoneCheckoutNamesNobody() {
        XCTAssertNil(
            ProjectResolver().repositoryOwner(for: "/nowhere/deleted-\(UUID().uuidString)"))
    }

    // MARK: -

    private func makeRepository(config: String) throws -> String {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sissy-owner-\(UUID().uuidString)")
        let git = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try config.write(
            to: git.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        return root.path
    }
}
