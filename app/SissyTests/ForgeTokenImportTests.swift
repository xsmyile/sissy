import XCTest

@testable import Sissy

/// Reading what `gh` and `glab` already hold.
///
/// Both fixtures are the real files' shape, recorded 2026-09-17 from this
/// machine: `gh`'s nests a `users:` block under the host and keeps its token in
/// the keychain, `glab`'s puts every host under a `hosts:` key with the token in
/// plaintext beside it and a page of commented defaults above. Neither file is
/// Sissy's, so both are read as a boundary — anything that is not a `key: value`
/// at the depth expected is skipped rather than guessed at.
final class ForgeTokenImportTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ contents: String, to relative: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: glab

    func testGlabsHostsAreReadOutOfItsOwnConfigurationShape() throws {
        try write(
            """
            # What protocol to use when performing Git operations.
            git_protocol: ssh
            editor:
            check_update: true
            host: gitlab.example.com
            hosts:
                gitlab.example.com:
                    token: glpat-example-token
                gitlab.other.com:
                    token: glpat-second-token
            last_seen_version: v1.118.0
            """, to: ".config/glab-cli/config.yml")
        let candidates = ForgeTokenImport.gitLab(home: home)
        XCTAssertEqual(candidates.map(\.host), ["gitlab.example.com", "gitlab.other.com"])
        XCTAssertEqual(candidates.first?.token, "glpat-example-token")
        XCTAssertEqual(candidates.first?.kind, .gitLab)
    }

    /// A key at the document root after the `hosts:` block is not a host. Left
    /// unguarded it becomes one, and the menu offers `last_seen_version` as a
    /// forge to connect.
    func testAKeyAfterTheHostsBlockIsNotAHost() throws {
        try write(
            """
            hosts:
                gitlab.example.com:
                    token: glpat-example-token
            last_seen_version: v1.118.0
            telemetry: true
            """, to: ".config/glab-cli/config.yml")
        XCTAssertEqual(ForgeTokenImport.gitLab(home: home).map(\.host), ["gitlab.example.com"])
    }

    /// A host with no token is not a candidate: offering it would connect a
    /// forge that can only ever answer 401.
    func testAHostWithNoTokenIsNotOffered() throws {
        try write(
            """
            hosts:
                gitlab.example.com:
                    api_protocol: https
            """, to: ".config/glab-cli/config.yml")
        XCTAssertTrue(ForgeTokenImport.gitLab(home: home).isEmpty)
    }

    func testNoConfigurationMeansNoCandidates() {
        XCTAssertTrue(ForgeTokenImport.gitLab(home: home).isEmpty)
        XCTAssertTrue(ForgeTokenImport.gitHub(home: home).isEmpty)
        XCTAssertTrue(ForgeTokenImport.candidates(home: home).isEmpty)
    }

    // MARK: gh

    /// Older `gh` releases kept the token in the file itself. Read as a
    /// fallback so a machine that has never re-authenticated still offers it.
    func testGhsInlineTokenIsReadWhereItIsStillWritten() throws {
        try write(
            """
            github.com:
                git_protocol: ssh
                users:
                    someone:
                oauth_token: gho_inline_example
                user: someone
            """, to: ".config/gh/hosts.yml")
        let candidates = ForgeTokenImport.gitHub(home: home)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.host, "github.com")
        XCTAssertEqual(candidates.first?.token, "gho_inline_example")
        XCTAssertEqual(candidates.first?.configuredAccount, "someone")
    }

    /// The nested `users:` block must not be read as a field of the host, and
    /// the name inside it must not be read as a host of its own.
    func testGhsNestedUsersBlockDoesNotBecomeAHost() throws {
        try write(
            """
            github.com:
                git_protocol: ssh
                users:
                    someone:
                user: someone
            """, to: ".config/gh/hosts.yml")
        XCTAssertTrue(
            ForgeTokenImport.hosts(in: home.appendingPathComponent(".config/gh/hosts.yml"))
                .keys.contains("github.com"))
        XCTAssertFalse(
            ForgeTokenImport.hosts(in: home.appendingPathComponent(".config/gh/hosts.yml"))
                .keys.contains("someone"))
    }

    /// `gh` files each account inside a `users:` block, and a plaintext token
    /// there belongs to that account rather than to the host. Flattened into
    /// the host's own field it would be offered as the host's token — and
    /// preferred over the keychain read that names the right account — so the
    /// wrong account's figures would appear under the row.
    func testANestedAccountsTokenIsNotOfferedAsTheHostsOwn() throws {
        try write(
            """
            github.com:
                git_protocol: ssh
                users:
                    someone:
                        oauth_token: gho_nested_other_account
                    somebody:
                        oauth_token: gho_nested_second_account
                user: someone
            """, to: ".config/gh/hosts.yml")
        let fields = ForgeTokenImport.hosts(
            in: home.appendingPathComponent(".config/gh/hosts.yml"))
        XCTAssertEqual(fields["github.com"]?["user"], "someone")
        XCTAssertNil(fields["github.com"]?["oauth_token"])
    }

    /// The host's own inline token still wins where `gh` writes one, because
    /// that one is the host's.
    func testAHostsOwnInlineTokenIsStillRead() throws {
        try write(
            """
            github.com:
                oauth_token: gho_host_level
                users:
                    someone:
                        oauth_token: gho_nested
                user: someone
            """, to: ".config/gh/hosts.yml")
        XCTAssertEqual(ForgeTokenImport.gitHub(home: home).first?.token, "gho_host_level")
    }

    // MARK: The keychain value

    /// The shape `go-keyring` writes, measured 2026-09-17: a 74-character item
    /// whose body decoded to the 40 bytes of a `gho_` token.
    func testAGoKeyringBase64ValueIsDecoded() throws {
        let token = "gho_0123456789012345678901234567890123456"
        let encoded = "go-keyring-base64:" + Data(token.utf8).base64EncodedString()
        XCTAssertEqual(ForgeTokenImport.decodeKeyringValue(Data(encoded.utf8)), token)
    }

    func testAPlainValueIsTakenAsTheTokenItself() {
        XCTAssertEqual(
            ForgeTokenImport.decodeKeyringValue(Data("gho_plain\n".utf8)), "gho_plain")
    }

    /// A prefix this build does not know names a continuation rather than a
    /// token. Passing it through would connect a forge that answers 401 for
    /// ever, under a row that looks connected.
    func testAnUnknownGoKeyringPrefixIsRefused() {
        XCTAssertNil(
            ForgeTokenImport.decodeKeyringValue(Data("go-keyring-chunked-2:abc".utf8)))
    }

    func testAnEmptyValueIsNoToken() {
        XCTAssertNil(ForgeTokenImport.decodeKeyringValue(Data()))
        XCTAssertNil(ForgeTokenImport.decodeKeyringValue(Data("   \n".utf8)))
    }
}
