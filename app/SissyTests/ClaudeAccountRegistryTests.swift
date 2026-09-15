import XCTest

@testable import Sissy

/// The keychain service names Claude Code files its credentials under, which
/// are what lets Sissy address a second sign-in at all.
final class ClaudeKeychainServiceTests: XCTestCase {
    func testScopedServiceHashesTheConfigDirectory() {
        XCTAssertEqual(
            ClaudeKeychainCLI.scopedClaudeService(for: "/Users/davide/.claude-mastersoft"),
            "Claude Code-credentials-a8264a74")
        XCTAssertEqual(
            ClaudeKeychainCLI.scopedClaudeService(for: "/Users/davide/.claude"),
            "Claude Code-credentials-8a380954")
    }

    func testDefaultHomeKeepsTheUnscopedService() {
        XCTAssertEqual(
            ClaudeKeychainCLI.claudeService(for: AccountDefaults.claudeHome),
            ClaudeKeychainCLI.claudeService)
    }

    func testOtherHomeTakesItsOwnService() {
        let home = URL(fileURLWithPath: "/tmp/sissy-tests/.claude-work")
        XCTAssertEqual(
            ClaudeKeychainCLI.claudeService(for: home),
            ClaudeKeychainCLI.scopedClaudeService(for: "/tmp/sissy-tests/.claude-work"))
    }

    func testLoginNameFallsBackWhenTheUserNameIsNotFilable() {
        XCTAssertEqual(
            ClaudeKeychainCLI.claudeLoginName(environment: ["USER": "first@example.com"]),
            "claude-code-user")
        XCTAssertEqual(
            ClaudeKeychainCLI.claudeLoginName(environment: ["USER": "davide"]), "davide")
    }
}

final class ClaudeAccountProfileTests: XCTestCase {
    func testParseTakesTheAccountAndItsOrganisation() throws {
        let identity = try ClaudeAccountProfile.parse([
            "account": ["uuid": "u-1", "email": "a@example.com"],
            "organization": [
                "name": "Master Soft Srl",
                "organization_type": "claude_team",
                "rate_limit_tier": "default_claude_max_5x",
            ],
        ])
        XCTAssertEqual(identity.uuid, "u-1")
        XCTAssertEqual(identity.email, "a@example.com")
        XCTAssertEqual(identity.organization, "Master Soft Srl")
        XCTAssertEqual(identity.organizationType, "claude_team")
        XCTAssertEqual(identity.rateLimitTier, "default_claude_max_5x")
    }

    /// A personal account names no organisation, and that is not a failure.
    func testParseSurvivesAnAccountWithNoOrganisation() throws {
        let identity = try ClaudeAccountProfile.parse(["account": ["uuid": "u-2"]])
        XCTAssertEqual(identity.uuid, "u-2")
        XCTAssertNil(identity.organization)
    }

    func testParseRefusesAPayloadWithNoAccountId() {
        XCTAssertThrowsError(try ClaudeAccountProfile.parse(["organization": ["name": "x"]]))
    }
}

final class ClaudeAccountRegistryTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sissy-accounts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Stands in for the login keychain, so nothing here reads or writes the
    /// real one.
    private final class Vault: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: Data] = [:]
        var active: Data?
        private(set) var writes = 0

        func secrets() -> ClaudeAccountStore.Secrets {
            ClaudeAccountStore.Secrets(
                read: { [self] uuid in lock.withLock { items[uuid] } },
                write: { [self] uuid, data in lock.withLock { items[uuid] = data } },
                delete: { [self] uuid in lock.withLock { _ = items.removeValue(forKey: uuid) } })
        }

        func slot() -> ClaudeAccountRegistry.ActiveSlot {
            ClaudeAccountRegistry.ActiveSlot(
                read: { [self] in lock.withLock { active } },
                write: { [self] data in
                    lock.withLock {
                        active = data
                        writes += 1
                    }
                })
        }
    }

    private func credential(_ token: String) -> Data {
        Data(
            """
            {"claudeAiOauth":{"accessToken":"\(token)","expiresAt":4102444800000}}
            """.utf8)
    }

    private func makeRegistry(
        _ vault: Vault,
        identify: @escaping @Sendable (String) async throws -> ClaudeAccountIdentity
    ) -> ClaudeAccountRegistry {
        var store = ClaudeAccountStore(indexURL: ClaudeAccountStore.defaultURL(in: tempDir))
        store.secrets = vault.secrets()
        return ClaudeAccountRegistry(store: store, slot: vault.slot(), identify: identify)
    }

    func testCaptureArchivesTheActiveAccount() async {
        let vault = Vault()
        vault.active = credential("tok-a")
        let registry = makeRegistry(vault) { _ in
            ClaudeAccountIdentity(
                uuid: "u-a", email: "a@example.com", organization: "A",
                organizationType: "claude_team", rateLimitTier: nil)
        }
        await registry.captureActive()

        let snapshot = registry.currentSnapshot()
        XCTAssertEqual(snapshot.accounts.map(\.uuid), ["u-a"])
        XCTAssertEqual(snapshot.activeUUID, "u-a")
    }

    /// The poll runs every couple of minutes and the token rotates in tens of
    /// minutes, so an unchanged credential must not buy a request.
    func testCaptureIdentifiesAnUnchangedCredentialOnlyOnce() async {
        let vault = Vault()
        vault.active = credential("tok-a")
        let calls = LockedValue(0)
        let registry = makeRegistry(vault) { _ in
            calls.update { $0 += 1 }
            return ClaudeAccountIdentity(
                uuid: "u-a", email: nil, organization: nil, organizationType: nil,
                rateLimitTier: nil)
        }
        await registry.captureActive()
        await registry.captureActive()
        await registry.captureActive()

        XCTAssertEqual(calls.load(), 1)
    }

    /// The whole point: switching to B must leave A recoverable, however many
    /// times the CLI rewrites its own slot afterwards.
    func testSwitchingKeepsThePreviousAccountRecoverable() async {
        let vault = Vault()
        let registry = makeRegistry(vault) { token in
            ClaudeAccountIdentity(
                uuid: token == "tok-a" ? "u-a" : "u-b", email: nil, organization: nil,
                organizationType: nil, rateLimitTier: nil)
        }
        vault.active = credential("tok-a")
        await registry.captureActive()
        vault.active = credential("tok-b")
        await registry.captureActive()

        vault.active = credential("rotated-by-the-cli")

        let outcome = await registry.activate(uuid: "u-a")
        guard case .success = outcome else { return XCTFail("switching back failed") }
        XCTAssertEqual(vault.active, credential("tok-a"))
        XCTAssertEqual(registry.currentSnapshot().activeUUID, "u-a")
    }

    /// A keychain that refuses the delete must reach the caller: a user told
    /// a stored secret is gone while it is still filed was lied to.
    func testARefusedDeleteIsReportedRatherThanSwallowed() async {
        let vault = Vault()
        vault.active = credential("tok-a")
        var store = ClaudeAccountStore(indexURL: ClaudeAccountStore.defaultURL(in: tempDir))
        store.secrets = ClaudeAccountStore.Secrets(
            read: { _ in nil },
            write: { _, _ in },
            delete: { _ in throw ClaudeKeychainCLI.Failure.tool(51) })
        let registry = ClaudeAccountRegistry(store: store, slot: vault.slot()) { _ in
            ClaudeAccountIdentity(
                uuid: "u-a", email: nil, organization: nil, organizationType: nil,
                rateLimitTier: nil)
        }
        await registry.captureActive()

        do {
            try await registry.forget(uuid: "u-a")
            XCTFail("a refused delete was reported as a deletion")
        } catch {}
        XCTAssertEqual(registry.currentSnapshot().accounts.map(\.uuid), ["u-a"])
    }

    func testSwitchingToAnUnknownAccountSaysSoAndWritesNothing() async {
        let vault = Vault()
        let registry = makeRegistry(vault) { _ in
            XCTFail("identifying must not be reached")
            throw ClaudeAccountProfile.Failure.malformedPayload
        }
        let outcome = await registry.activate(uuid: "u-nobody")
        guard case .failure(.notArchived) = outcome else { return XCTFail("expected notArchived") }
        XCTAssertNil(vault.active)
    }

    /// Offline, or a token the vendor will not answer for: the credential is
    /// left alone rather than filed under a guess.
    func testAnUnidentifiableCredentialIsNotArchived() async {
        let vault = Vault()
        vault.active = credential("tok-a")
        let registry = makeRegistry(vault) { _ in
            throw ClaudeAccountProfile.Failure.badStatus(401)
        }
        await registry.captureActive()

        XCTAssertTrue(registry.currentSnapshot().accounts.isEmpty)
        XCTAssertNil(registry.currentSnapshot().activeUUID)
    }

    func testForgettingDropsTheCredentialAndTheEntry() async throws {
        let vault = Vault()
        vault.active = credential("tok-a")
        let registry = makeRegistry(vault) { _ in
            ClaudeAccountIdentity(
                uuid: "u-a", email: nil, organization: nil, organizationType: nil,
                rateLimitTier: nil)
        }
        await registry.captureActive()
        try await registry.forget(uuid: "u-a")

        XCTAssertTrue(registry.currentSnapshot().accounts.isEmpty)
        let outcome = await registry.activate(uuid: "u-a")
        guard case .failure(.notArchived) = outcome else { return XCTFail("expected notArchived") }
    }
}
