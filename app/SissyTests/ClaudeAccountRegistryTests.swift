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

    /// The seat sits on the organisation here, where claude.ai puts it on the
    /// membership. Measured 2026-09-16: both answer `team_tier_1` for one
    /// account, which is what lets a row badge "Team Premium" whichever source
    /// named it.
    func testParseTakesTheSeatOffTheOrganisation() throws {
        let identity = try ClaudeAccountProfile.parse([
            "account": ["uuid": "u-1"],
            "organization": ["organization_type": "claude_team", "seat_tier": "team_tier_1"],
        ])

        XCTAssertEqual(identity.seat, "team_tier_1")
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

    /// Measured 2026-09-16: the profile carries `full_name` and `display_name`
    /// side by side on the account. The full name leads, because the display
    /// name is what the account chose to be shown as and can be a handle.
    func testParseTakesTheOwnersName() throws {
        let identity = try ClaudeAccountProfile.parse([
            "account": [
                "uuid": "u-1", "full_name": "Davide Tacchini", "display_name": "dtac",
            ]
        ])

        XCTAssertEqual(identity.name, "Davide Tacchini")
    }

    func testTheDisplayNameAnswersForAnAccountWithNoFullName() throws {
        let identity = try ClaudeAccountProfile.parse([
            "account": ["uuid": "u-1", "display_name": "dtac"]
        ])

        XCTAssertEqual(identity.name, "dtac")
    }

    /// An account that filled in neither is named by its address, so the name
    /// has to be absent rather than empty: a blank title would leave the row
    /// with nothing on it.
    func testAnAccountWithNoNameAnswersNone() throws {
        let identity = try ClaudeAccountProfile.parse([
            "account": ["uuid": "u-1", "full_name": "   "]
        ])

        XCTAssertNil(identity.name)
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
                write: { [self] uuid, data in lock.withLock { items[uuid] = data } })
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
    /// The capture is what a `/login` in a terminal Sissy is not watching
    /// reaches, and it produces no token event of its own — so it has to say
    /// whether anything moved, or the switcher waits for an unrelated frame to
    /// carry the new account to the app. The second call must answer false:
    /// re-emitting on every 120 s poll would rebuild the panel for nothing.
    func testCaptureReportsOnlyTheCaptureThatChangedSomething() async {
        let vault = Vault()
        vault.active = credential("tok-a")
        let registry = makeRegistry(vault) { token in
            ClaudeAccountIdentity(
                uuid: "u-\(token)", email: nil, organization: nil,
                organizationType: nil, rateLimitTier: nil)
        }

        let first = await registry.captureActive()
        let unchanged = await registry.captureActive()
        vault.active = credential("tok-b")
        let switched = await registry.captureActive()

        XCTAssertTrue(first)
        XCTAssertFalse(unchanged)
        XCTAssertTrue(switched)
    }

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
}
