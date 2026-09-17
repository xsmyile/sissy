import XCTest

@testable import Sissy

/// The forge a repository is pushed to, read off its `origin` remote — the
/// account that keeps two `website` checkouts under different accounts from
/// rendering one label, and the page the project card opens.
final class ProjectOwnerTests: XCTestCase {

    // MARK: The two shapes git writes

    func testAnSCPStyleRemoteNamesItsAccount() {
        XCTAssertEqual(
            ProjectResolver.remote(ofRemoteURL: "git@github.com:radonforge/website.git")?.owner,
            "radonforge")
    }

    func testAnHTTPSRemoteNamesItsAccount() {
        XCTAssertEqual(
            ProjectResolver.remote(ofRemoteURL: "https://github.com/radonforge/website.git")?.owner,
            "radonforge")
    }

    func testARemoteWithoutTheGitSuffixNamesItsAccount() {
        XCTAssertEqual(
            ProjectResolver.remote(ofRemoteURL: "https://github.com/radonforge/website")?.owner,
            "radonforge")
    }

    func testAnSSHURLCarryingAPortNamesItsAccount() {
        XCTAssertEqual(
            ProjectResolver.remote(
                ofRemoteURL: "ssh://git@ssh.github.com:443/radonforge/website.git")?.owner,
            "radonforge")
    }

    /// A self-hosted GitLab is the case this has to get right for work, and
    /// the account is the group the repository sits directly under.
    func testASelfHostedForgeNamesTheGroup() {
        XCTAssertEqual(
            ProjectResolver.remote(ofRemoteURL: "git@gitlab.example.com:radonforge/storefront.git")?.owner,
            "radonforge")
    }

    /// Nested groups answer the one the repository sits directly under, not
    /// the whole hierarchy — that is the label a person says out loud.
    func testANestedGroupNamesTheInnermostOne() {
        XCTAssertEqual(
            ProjectResolver.remote(ofRemoteURL: "https://gitlab.com/group/sub/repo.git")?.owner,
            "sub")
    }

    // MARK: The way to the page

    /// An `ssh` remote names no page, so the card's is composed from the host
    /// it does name.
    func testAnSSHRemoteComposesItsPage() {
        let remote = ProjectResolver.remote(ofRemoteURL: "git@github.com:radonforge/website.git")

        XCTAssertEqual(remote?.page, URL(string: "https://github.com/radonforge/website"))
        XCTAssertEqual(remote?.repository, "website")
        XCTAssertEqual(remote?.host, "github.com")
    }

    /// A remote a browser can already open is kept as it is, port and all: a
    /// self-hosted forge on a port serves its pages there, and composing one
    /// from the bare host would drop it.
    func testAWebRemoteKeepsItsOwnSchemeAndPort() {
        XCTAssertEqual(
            ProjectResolver.remote(ofRemoteURL: "https://git.example.com:8443/team/app.git")?.page,
            URL(string: "https://git.example.com:8443/team/app"))
    }

    /// `ssh.github.com` on 443 is a transport endpoint and serves no page, so
    /// the row keeps the repository and offers no way out to it.
    func testAnSSHRemoteOnAPortOffersNoPage() {
        XCTAssertNil(
            ProjectResolver.remote(
                ofRemoteURL: "ssh://git@ssh.github.com:443/radonforge/website.git")?.page)
    }

    /// The owner is the innermost group, and the page is the whole hierarchy
    /// — the forge needs every segment to answer.
    func testANestedGroupKeepsItsWholeHierarchyInThePage() {
        XCTAssertEqual(
            ProjectResolver.remote(ofRemoteURL: "https://gitlab.com/group/sub/repo.git")?.page,
            URL(string: "https://gitlab.com/group/sub/repo"))
    }

    /// git writes an IPv6 host in brackets, and the colon that separates it
    /// from the path is the one after the bracket — every colon before it
    /// belongs to the address.
    func testABracketedIPv6HostIsNotSplitDownTheMiddle() {
        let remote = ProjectResolver.remote(ofRemoteURL: "git@[2001:db8::1]:radonforge/storefront.git")

        XCTAssertEqual(remote?.host, "[2001:db8::1]")
        XCTAssertEqual(remote?.owner, "radonforge")
        XCTAssertEqual(remote?.page, URL(string: "https://[2001:db8::1]/radonforge/storefront"))
    }

    func testABracketedIPv6HostOnAPortKeepsItsAccountAndOffersNoPage() {
        let remote = ProjectResolver.remote(
            ofRemoteURL: "ssh://git@[2001:db8::1]:2222/radonforge/storefront.git")

        XCTAssertEqual(remote?.host, "[2001:db8::1]")
        XCTAssertEqual(remote?.owner, "radonforge")
        XCTAssertNil(remote?.page)
    }

    /// A `#` in a segment is part of the path, and a page built by pasting
    /// strings together would have the browser read it as a fragment and open
    /// a shorter repository that is not this one.
    func testASegmentCarryingAFragmentMarkerIsEscapedIntoThePage() {
        XCTAssertEqual(
            ProjectResolver.remote(ofRemoteURL: "https://git.example.com/team/we#ird.git")?.page,
            URL(string: "https://git.example.com/team/we%23ird"))
    }

    /// `.git` as the whole segment is the repository's name rather than the
    /// suffix on one, and stripping it would leave the row nothing to say.
    func testARepositoryNamedOnlyForTheSuffixKeepsIt() {
        XCTAssertEqual(
            ProjectResolver.remote(ofRemoteURL: "https://git.example.com/team/.git")?.repository,
            ".git")
    }

    // MARK: What must not be turned into an account

    /// A directory on this Mac is not a forge, so the enclosing folder must
    /// not be dressed up as an account.
    func testAPathRemoteNamesNobody() {
        XCTAssertNil(ProjectResolver.remote(ofRemoteURL: "/Users/smyile/repos/bare.git"))
    }

    /// `file://` is the same path wearing a scheme: its host is empty and its
    /// first segment is a directory.
    func testAFileURLRemoteNamesNobody() {
        XCTAssertNil(ProjectResolver.remote(ofRemoteURL: "file:///Users/smyile/repos/bare.git"))
    }

    func testARelativeRemoteNamesNobody() {
        XCTAssertNil(ProjectResolver.remote(ofRemoteURL: "../sibling"))
    }

    func testARemoteWithNoAccountSegmentNamesNobody() {
        XCTAssertNil(ProjectResolver.remote(ofRemoteURL: "git@github.com:website.git"))
    }

    func testAnEmptyRemoteNamesNobody() {
        XCTAssertNil(ProjectResolver.remote(ofRemoteURL: ""))
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

        XCTAssertEqual(ProjectResolver().repositoryRemote(for: repository)?.owner, "radonforge")
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

        XCTAssertEqual(ProjectResolver().repositoryRemote(for: repository)?.owner, "radonforge")
    }

    func testARepositoryWithNoOriginNamesNobody() throws {
        let repository = try makeRepository(
            config: """
                [core]
                	bare = false
                """)

        XCTAssertNil(ProjectResolver().repositoryRemote(for: repository))
    }

    /// A checkout that has been deleted since its rows were counted has no
    /// config left to read, and the row keeps the plain name it has.
    func testAGoneCheckoutNamesNobody() {
        XCTAssertNil(
            ProjectResolver().repositoryRemote(for: "/nowhere/deleted-\(UUID().uuidString)"))
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
