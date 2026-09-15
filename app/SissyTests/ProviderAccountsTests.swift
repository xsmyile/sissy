import XCTest

@testable import Sissy

/// One vendor, more than one account. The rules that make a row impossible to
/// assemble out of two of them, and the one that keeps the first account's
/// files exactly where they were.
final class ProviderAccountsTests: XCTestCase {
    private func config(_ accounts: [AccountConfig]?) -> ServerConfig {
        var config = ServerConfig.defaults
        config.accounts = accounts
        return config
    }

    func testTheFirstAccountKeepsTheBareVendorID() {
        XCTAssertEqual(ProviderKey(vendor: ProviderID.claudeCode).id, ProviderID.claudeCode)
        XCTAssertEqual(
            ProviderKey(vendor: ProviderID.claudeCode, account: "").id, ProviderID.claudeCode)
    }

    func testAKeyedAccountCarriesItsKeyInTheID() {
        let key = ProviderKey(vendor: ProviderID.claudeCode, account: "work")
        XCTAssertEqual(key.id, "claude-code:work")
        XCTAssertEqual(ProviderKey(id: key.id), key)
    }

    func testAnIDFromBeforeAccountsReadsAsAVendorWithNoAccount() {
        let key = ProviderKey(id: ProviderID.codex)
        XCTAssertEqual(key.vendor, ProviderID.codex)
        XCTAssertNil(key.account)
    }

    /// However many homes the scan finds, the one that predates accounts
    /// leads and keeps the bare id — which is what keeps its snapshot and its
    /// archive directory where they have been since 0.1.0.
    func testTheDefaultHomeLeadsAndKeepsTheBareID() {
        let accounts = config(nil).resolvedAccounts(vendor: ProviderID.claudeCode)

        XCTAssertEqual(accounts.first?.id, ProviderID.claudeCode)
        XCTAssertEqual(accounts.first?.dataDir.lastPathComponent, "projects")
    }

    /// A user who pointed `claudeDataDir` at a tree of their own meant that
    /// tree, and the scan must not add rows beside it.
    func testANamedLogTreeIsTheOnlyAccount() {
        var named = ServerConfig.defaults
        named.claudeDataDir = "/tmp/sissy-tests/elsewhere/projects"

        let accounts = named.resolvedAccounts(vendor: ProviderID.claudeCode)

        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.dataDir.path, "/tmp/sissy-tests/elsewhere/projects")
    }

    func testEachConfiguredAccountResolvesToItsOwnTree() {
        let resolved = config([
            AccountConfig(id: "", vendor: ProviderID.claudeCode, label: nil, home: "/tmp/a"),
            AccountConfig(id: "work", vendor: ProviderID.claudeCode, label: "Work", home: "/tmp/b"),
        ]).resolvedAccounts(vendor: ProviderID.claudeCode)

        XCTAssertEqual(resolved.map(\.id), [ProviderID.claudeCode, "claude-code:work"])
        XCTAssertEqual(resolved.map { $0.dataDir.path }, ["/tmp/a/projects", "/tmp/b/projects"])
    }

    /// Growing the key for one vendor must not take the other's account with
    /// it: the list is authoritative per vendor, not per file.
    func testAVendorWithNoEntryKeepsItsImpliedAccount() {
        let resolved = config([
            AccountConfig(id: "work", vendor: ProviderID.claudeCode, label: nil, home: "/tmp/b")
        ]).resolvedAccounts(vendor: ProviderID.codex)

        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.id, ProviderID.codex)
    }

    /// Found, not configured: a second account is a second config home, and a
    /// home is something the scan can see without anyone adding it.
    func testASecondHomeIsFoundByItsContents() throws {
        let parent = try makeHome(".claude-work", contents: "projects")

        let homes = AccountDiscovery.homes(vendor: ProviderID.claudeCode, in: parent)

        XCTAssertEqual(homes.map(\.lastPathComponent), [".claude-work"])
        XCTAssertEqual(
            AccountDiscovery.key(vendor: ProviderID.claudeCode, home: homes[0]), "work")
    }

    /// A directory that merely starts with the prefix is not an account. The
    /// scan runs unattended, so a backup nobody remembers must not become a
    /// row that cannot be explained.
    func testADirectoryHoldingNothingACLIWroteIsNotAnAccount() throws {
        let parent = try makeHome(".claude-backup", contents: nil)

        XCTAssertTrue(AccountDiscovery.homes(vendor: ProviderID.claudeCode, in: parent).isEmpty)
    }

    /// A home signed into this morning has no logs yet, and it is exactly the
    /// one the user is looking for.
    func testAHomeWithAProfileAndNoLogsIsStillAnAccount() throws {
        let parent = try makeHome(".claude-work", contents: nil)
        let profile = parent.appendingPathComponent(".claude-work/.claude.json")
        try #"{"oauthAccount":{"organizationType":"claude_max"}}"#
            .write(to: profile, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            AccountDiscovery.homes(vendor: ProviderID.claudeCode, in: parent)
                .map(\.lastPathComponent),
            [".claude-work"])
    }

    func testCodexHomesAreFoundByTheirOwnMarkers() throws {
        let parent = try makeHome(".codex-work", contents: "sessions")

        XCTAssertEqual(
            AccountDiscovery.homes(vendor: ProviderID.codex, in: parent).map(\.lastPathComponent),
            [".codex-work"])
        XCTAssertTrue(AccountDiscovery.homes(vendor: ProviderID.claudeCode, in: parent).isEmpty)
    }

    private func makeHome(_ name: String, contents: String?) throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-homes-\(UUID().uuidString)")
        let home = parent.appendingPathComponent(name)
        let leaf = contents.map { home.appendingPathComponent($0) } ?? home
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        return parent
    }

    /// The CLI's own quirk: with `CLAUDE_CONFIG_DIR` unset the profile sits
    /// beside the config home rather than inside it, and a home the variable
    /// names holds its own copy.
    func testTheProfileOfANamedHomeIsInsideThatHome() {
        let account = ResolvedAccount(
            key: ProviderKey(vendor: ProviderID.claudeCode, account: "work"),
            label: nil,
            home: URL(fileURLWithPath: "/tmp/b"),
            dataDir: URL(fileURLWithPath: "/tmp/b/projects")
        )

        XCTAssertEqual(account.claudeProfileURL.path, "/tmp/b/.claude.json")
        XCTAssertEqual(account.claudeCredentialsURL.path, "/tmp/b/.credentials.json")
    }

    func testTheProfileOfTheDefaultHomeSitsBesideIt() {
        let account = ResolvedAccount(
            key: ProviderKey(vendor: ProviderID.claudeCode),
            label: nil,
            home: AccountDefaults.claudeHome,
            dataDir: AccountDefaults.claudeHome.appendingPathComponent("projects")
        )

        XCTAssertEqual(
            account.claudeProfileURL.path,
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json").path)
    }
}

/// The credential an account keeps in its own home, which is the only source
/// that can answer for a second account at all.
final class ClaudeFileCredentialsTests: XCTestCase {
    private func write(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-creds-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAnAccountThatHasNeverSignedInIsAbsent() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-missing-\(UUID().uuidString).json")

        guard case .absent = ClaudeFileCredentials.load(at: url) else {
            return XCTFail("a missing file is an account that has not signed in")
        }
    }

    func testTheTokenAndItsExpiryAreRead() throws {
        let url = try write(
            #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-x","expiresAt":1789487107266}}"#)

        guard case .found(let credentials) = ClaudeFileCredentials.load(at: url) else {
            return XCTFail("a well-formed file names a credential")
        }
        XCTAssertEqual(credentials.accessToken, "sk-ant-oat01-x")
        XCTAssertEqual(
            credentials.expiresAt?.timeIntervalSince1970 ?? 0, 1_789_487_107.266, accuracy: 0.01)
    }

    /// A payload this build cannot read is not a signed-out account: saying so
    /// would take a working row down over a shape that changed.
    func testAPayloadThatWillNotParseIsUnreadableRatherThanAbsent() throws {
        let url = try write(#"{"claudeAiOauth":{}}"#)

        guard case .unreadable = ClaudeFileCredentials.load(at: url) else {
            return XCTFail("a shape with no token is unreadable, not absent")
        }
    }
}
