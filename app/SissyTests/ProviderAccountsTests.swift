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

    func testAConfigWithNoAccountsMetersTheOneItAlwaysHad() {
        let accounts = config(nil).resolvedAccounts(vendor: ProviderID.claudeCode)

        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.id, ProviderID.claudeCode)
        XCTAssertEqual(accounts.first?.dataDir.lastPathComponent, "projects")
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

    /// The failure this guards is silent and expensive: appending the second
    /// account without writing the first one down would drop the account that
    /// owns `usage-state.json` and the whole archive.
    func testAddingTheSecondAccountWritesDownTheFirst() {
        let updated = config(nil).addingAccount(
            vendor: ProviderID.claudeCode, home: URL(fileURLWithPath: "/tmp/b"), label: "Work")

        let claude = updated.resolvedAccounts(vendor: ProviderID.claudeCode)
        XCTAssertEqual(claude.count, 2)
        XCTAssertEqual(claude.first?.id, ProviderID.claudeCode)
        XCTAssertEqual(claude.last?.id, "claude-code:work")
    }

    func testTwoAccountsNamedTheSameGetDifferentKeys() {
        let once = config(nil).addingAccount(
            vendor: ProviderID.claudeCode, home: URL(fileURLWithPath: "/tmp/b"), label: "Work")
        let twice = once.addingAccount(
            vendor: ProviderID.claudeCode, home: URL(fileURLWithPath: "/tmp/c"), label: "Work")

        let ids = twice.resolvedAccounts(vendor: ProviderID.claudeCode).map(\.id)
        XCTAssertEqual(ids, [ProviderID.claudeCode, "claude-code:work", "claude-code:work-2"])
    }

    func testRemovingAnAccountLeavesTheOthers() {
        let updated = config(nil)
            .addingAccount(
                vendor: ProviderID.claudeCode,
                home: URL(fileURLWithPath: "/tmp/b"),
                label: "Work"
            )
            .removingAccount(id: "work", vendor: ProviderID.claudeCode)

        XCTAssertEqual(
            updated.resolvedAccounts(vendor: ProviderID.claudeCode).map(\.id),
            [ProviderID.claudeCode])
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
