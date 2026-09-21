import XCTest

@testable import Sissy

/// The keychain service names Claude Code files its credentials under, which
/// are what lets Sissy address a second sign-in at all.
final class ClaudeKeychainServiceTests: XCTestCase {
    func testScopedServiceHashesTheConfigDirectory() {
        XCTAssertEqual(
            ClaudeKeychainCLI.scopedClaudeService(for: "/Users/smyile/.claude-work"),
            "Claude Code-credentials-89c4b9c5")
        XCTAssertEqual(
            ClaudeKeychainCLI.scopedClaudeService(for: "/Users/smyile/.claude"),
            "Claude Code-credentials-1918062b")
    }

    func testDefaultHomeKeepsTheUnscopedService() {
        XCTAssertEqual(
            ClaudeKeychainCLI.claudeService(for: AccountDefaults.claudeHome),
            ClaudeKeychainCLI.claudeService)
    }

    /// Claude Code 2.1.27x keeps a second, scoped item for the default home
    /// and rewrites the pair together — measured 2026-09-21, both carrying the
    /// same modification date to the second — so a switch has to reach both.
    func testTheDefaultHomeAlsoCarriesItsScopedItem() {
        XCTAssertEqual(
            ClaudeKeychainCLI.siblingClaudeServices(for: AccountDefaults.claudeHome),
            [ClaudeKeychainCLI.scopedClaudeService(for: AccountDefaults.claudeHome.path)])
    }

    /// A home of its own is addressed by its own hash and has no second name.
    func testAHomeOfItsOwnHasNoSiblingItem() {
        let home = URL(fileURLWithPath: "/tmp/sissy-tests/.claude-work")
        XCTAssertTrue(ClaudeKeychainCLI.siblingClaudeServices(for: home).isEmpty)
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
            ClaudeKeychainCLI.claudeLoginName(environment: ["USER": "smyile"]), "smyile")
    }
}

final class ClaudeAccountProfileTests: XCTestCase {
    func testParseTakesTheAccountAndItsOrganisation() throws {
        let identity = try ClaudeAccountProfile.parse([
            "account": ["uuid": "u-1", "email": "someone@example.com"],
            "organization": [
                "name": "Acme Srl",
                "organization_type": "claude_team",
                "rate_limit_tier": "default_claude_max_5x",
            ],
        ])
        XCTAssertEqual(identity.uuid, "u-1")
        XCTAssertEqual(identity.email, "someone@example.com")
        XCTAssertEqual(identity.organization, "Acme Srl")
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
                "uuid": "u-1", "full_name": "Davide", "display_name": "smyile",
            ]
        ])

        XCTAssertEqual(identity.name, "Davide")
    }

    func testTheDisplayNameAnswersForAnAccountWithNoFullName() throws {
        let identity = try ClaudeAccountProfile.parse([
            "account": ["uuid": "u-1", "display_name": "smyile"]
        ])

        XCTAssertEqual(identity.name, "smyile")
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
        /// The CLI's other names for the same home, which a switch has to
        /// reach and must not overwrite blind.
        var siblings: [Data] = []
        var siblingFailure: Error?
        private(set) var writes = 0

        func secrets() -> ClaudeAccountStore.Secrets {
            ClaudeAccountStore.Secrets(
                read: { [self] uuid in lock.withLock { items[uuid] } },
                write: { [self] uuid, data in lock.withLock { items[uuid] = data } })
        }

        func slot() -> ClaudeAccountRegistry.ActiveSlot {
            ClaudeAccountRegistry.ActiveSlot(
                read: { [self] in lock.withLock { active } },
                readSiblings: { [self] in
                    if let siblingFailure { throw siblingFailure }
                    return lock.withLock { siblings }
                },
                write: { [self] data in
                    lock.withLock {
                        active = data
                        siblings = siblings.map { _ in data }
                        writes += 1
                    }
                })
        }
    }

    private func credential(_ token: String, expiresAt: Int = 4_102_444_800_000) -> Data {
        Data(
            """
            {"claudeAiOauth":{"accessToken":"\(token)","expiresAt":\(expiresAt)}}
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
                uuid: "u-a", email: "someone@example.com", organization: "A",
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

    /// Re-affirming the account already in use writes what the slot itself
    /// holds, not the copy filed before the CLI last rotated: the capture in
    /// front of the write is what makes the archive those same bytes.
    func testSwitchingToTheAccountAlreadyInUseWritesWhatTheSlotHolds() async {
        let vault = Vault()
        vault.active = credential("tok-a")
        let registry = makeRegistry(vault) { _ in
            ClaudeAccountIdentity(
                uuid: "u-a", email: nil, organization: nil, organizationType: nil,
                rateLimitTier: nil)
        }
        await registry.captureActive()
        vault.active = credential("rotated-by-the-cli")

        let outcome = await registry.activate(uuid: "u-a")

        guard case .success = outcome else { return XCTFail("expected the switch to succeed") }
        XCTAssertEqual(vault.active, credential("rotated-by-the-cli"))
    }

    /// The refusal this exists for: the CLI has rotated, the identify that
    /// would say whose the new token is cannot be made, and the click lands on
    /// the account Sissy last saw there. Writing the frozen archive back would
    /// hand the CLI a refresh token it has already spent.
    func testAnUnidentifiableSlotIsRefusedRatherThanOverwritten() async {
        let vault = Vault()
        vault.active = credential("tok-a")
        let offline = LockedValue(false)
        let registry = makeRegistry(vault) { _ in
            if offline.load() { throw ClaudeAccountProfile.Failure.badStatus(401) }
            return ClaudeAccountIdentity(
                uuid: "u-a", email: nil, organization: nil, organizationType: nil,
                rateLimitTier: nil)
        }
        await registry.captureActive()
        offline.update { $0 = true }
        vault.active = credential("rotated-by-the-cli")

        let outcome = await registry.activate(uuid: "u-a")

        guard case .failure(.activeAccountUnknown) = outcome else {
            return XCTFail("expected the unverifiable slot to be refused")
        }
        XCTAssertEqual(vault.active, credential("rotated-by-the-cli"))
    }

    /// The same refusal protects the account being switched *away* from: its
    /// archive is behind a rotation nobody saw, so overwriting the slot would
    /// spend the last copy of it this Mac has.
    func testAnUnidentifiableSlotAlsoRefusesASwitchToAnotherAccount() async {
        let vault = Vault()
        let offline = LockedValue(false)
        let registry = makeRegistry(vault) { token in
            if offline.load() { throw ClaudeAccountProfile.Failure.badStatus(401) }
            return ClaudeAccountIdentity(
                uuid: token == "tok-a" ? "u-a" : "u-b", email: nil, organization: nil,
                organizationType: nil, rateLimitTier: nil)
        }
        vault.active = credential("tok-a")
        await registry.captureActive()
        vault.active = credential("tok-b")
        await registry.captureActive()
        offline.update { $0 = true }
        vault.active = credential("rotated-by-the-cli")

        let outcome = await registry.activate(uuid: "u-a")

        guard case .failure(.activeAccountUnknown) = outcome else {
            return XCTFail("expected the unverifiable slot to be refused")
        }
        XCTAssertEqual(vault.active, credential("rotated-by-the-cli"))
    }

    /// A CLI that has been signed out holds nothing, so there is no owner to
    /// establish and nothing to strand — the archive goes in.
    func testAnEmptySlotTakesTheArchiveRatherThanBeingRefused() async {
        let vault = Vault()
        vault.active = credential("tok-a")
        let registry = makeRegistry(vault) { _ in
            ClaudeAccountIdentity(
                uuid: "u-a", email: nil, organization: nil, organizationType: nil,
                rateLimitTier: nil)
        }
        await registry.captureActive()
        vault.active = nil

        let outcome = await registry.activate(uuid: "u-a")

        guard case .success = outcome else { return XCTFail("expected the switch to succeed") }
        XCTAssertEqual(vault.active, credential("tok-a"))
    }

    /// A sibling naming another account is what an earlier build left behind,
    /// and the switch may not overwrite it until Sissy holds a copy: that
    /// credential can be the last one this Mac has for it.
    func testASiblingHoldingAnotherAccountIsArchivedBeforeItIsOverwritten() async {
        let vault = Vault()
        vault.active = credential("tok-a")
        vault.siblings = [credential("tok-c")]
        let registry = makeRegistry(vault) { token in
            ClaudeAccountIdentity(
                uuid: "u-\(token)", email: nil, organization: nil, organizationType: nil,
                rateLimitTier: nil)
        }
        await registry.captureActive()
        vault.active = credential("tok-b")
        await registry.captureActive()
        vault.active = credential("tok-a")
        await registry.captureActive()

        let outcome = await registry.activate(uuid: "u-tok-b")

        guard case .success = outcome else { return XCTFail("expected the switch to succeed") }
        XCTAssertTrue(registry.currentSnapshot().accounts.map(\.uuid).contains("u-tok-c"))
        XCTAssertEqual(vault.siblings, [credential("tok-b")])
    }

    /// The same sibling, with nobody to say whose it is: overwriting it would
    /// spend the only copy, so the switch is refused instead.
    func testASiblingThatCannotBeIdentifiedRefusesTheSwitch() async {
        let vault = Vault()
        vault.active = credential("tok-a")
        let registry = makeRegistry(vault) { token in
            guard token != "tok-c" else { throw ClaudeAccountProfile.Failure.badStatus(401) }
            return ClaudeAccountIdentity(
                uuid: "u-\(token)", email: nil, organization: nil, organizationType: nil,
                rateLimitTier: nil)
        }
        await registry.captureActive()
        vault.active = credential("tok-b")
        await registry.captureActive()
        vault.active = credential("tok-a")
        await registry.captureActive()
        vault.siblings = [credential("tok-c")]

        let outcome = await registry.activate(uuid: "u-tok-b")

        guard case .failure(.activeAccountUnknown) = outcome else {
            return XCTFail("expected the unidentifiable sibling to be refused")
        }
        XCTAssertEqual(vault.siblings, [credential("tok-c")])
        XCTAssertEqual(vault.active, credential("tok-a"))
    }

    /// A lookup that failed is not a name with no item behind it. Treating the
    /// two alike leaves that slot on the previous account under a switch that
    /// called itself a success.
    func testASiblingLookupThatFailedStopsTheSwitch() async {
        let vault = Vault()
        vault.active = credential("tok-a")
        let registry = makeRegistry(vault) { token in
            ClaudeAccountIdentity(
                uuid: "u-\(token)", email: nil, organization: nil, organizationType: nil,
                rateLimitTier: nil)
        }
        await registry.captureActive()
        vault.active = credential("tok-b")
        await registry.captureActive()
        vault.active = credential("tok-a")
        await registry.captureActive()
        vault.siblingFailure = ClaudeKeychainCLI.Failure.tool(51)

        let outcome = await registry.activate(uuid: "u-tok-b")

        guard case .failure(.keychain(51)) = outcome else {
            return XCTFail("expected the failed lookup to stop the switch")
        }
        XCTAssertEqual(vault.active, credential("tok-a"))
    }

    /// The two names a home keeps can hold the same account at two ages. The
    /// older one is still worth archiving where nothing is held for it, and it
    /// may never replace the copy the capture has just taken off the live
    /// slot — that copy is the one the next switch writes back.
    func testAnOlderSiblingDoesNotReplaceTheFreshlyCapturedArchive() async {
        let vault = Vault()
        let rotated = credential("tok-a2", expiresAt: 4_102_444_800_000)
        vault.active = rotated
        vault.siblings = [credential("tok-a1", expiresAt: 4_102_444_700_000)]
        let registry = makeRegistry(vault) { _ in
            ClaudeAccountIdentity(
                uuid: "u-a", email: nil, organization: nil, organizationType: nil,
                rateLimitTier: nil)
        }
        await registry.captureActive()

        let outcome = await registry.activate(uuid: "u-a")

        guard case .success = outcome else { return XCTFail("expected the switch to succeed") }
        XCTAssertEqual(vault.active, rotated)
        XCTAssertEqual(vault.siblings, [rotated])
    }

    /// Identifying a sibling is a network turn, and the CLI rotates on its own
    /// schedule. A slot that moved while Sissy was away holds a credential
    /// nothing has archived, so the switch is abandoned rather than written
    /// over it.
    func testASlotThatMovedDuringIdentificationAbandonsTheSwitch() async {
        let vault = Vault()
        vault.active = credential("tok-a")
        let rotating = LockedValue(false)
        let midSwitch = credential("rotated-mid-switch")
        let registry = makeRegistry(vault) { token in
            if rotating.load(), token == "tok-c" {
                vault.active = midSwitch
            }
            return ClaudeAccountIdentity(
                uuid: "u-\(token)", email: nil, organization: nil, organizationType: nil,
                rateLimitTier: nil)
        }
        await registry.captureActive()
        vault.active = credential("tok-b")
        await registry.captureActive()
        vault.active = credential("tok-a")
        await registry.captureActive()
        vault.siblings = [credential("tok-c")]
        rotating.update { $0 = true }

        let outcome = await registry.activate(uuid: "u-tok-b")

        guard case .failure(.activeAccountUnknown) = outcome else {
            return XCTFail("expected the moved slot to abandon the switch")
        }
        XCTAssertEqual(vault.active, credential("rotated-mid-switch"))
    }

    /// A relaunch forgets which token it last saw, and a Mac whose CLI has not
    /// run for hours holds an access token the vendor will no longer answer
    /// for. The archive is the proof that survives both, or an archived
    /// account would stop being switchable until the user went and ran the CLI.
    func testARelaunchSwitchesOnCredentialsTheVendorWillNoLongerIdentify() async {
        let vault = Vault()
        vault.active = credential("tok-a")
        let registry = makeRegistry(vault) { token in
            ClaudeAccountIdentity(
                uuid: "u-\(token)", email: nil, organization: nil, organizationType: nil,
                rateLimitTier: nil)
        }
        await registry.captureActive()
        vault.active = credential("tok-b")
        await registry.captureActive()
        vault.active = credential("tok-a")

        let relaunched = makeRegistry(vault) { _ in
            throw ClaudeAccountProfile.Failure.badStatus(401)
        }
        let outcome = await relaunched.activate(uuid: "u-tok-b")

        guard case .success = outcome else { return XCTFail("expected the switch to succeed") }
        XCTAssertEqual(vault.active, credential("tok-b"))
    }

    /// The same shortcut must not let an unknown credential through: bytes
    /// nothing has archived are still refused.
    func testARelaunchStillRefusesACredentialNothingHasArchived() async {
        let vault = Vault()
        vault.active = credential("tok-a")
        let registry = makeRegistry(vault) { token in
            ClaudeAccountIdentity(
                uuid: "u-\(token)", email: nil, organization: nil, organizationType: nil,
                rateLimitTier: nil)
        }
        await registry.captureActive()
        vault.active = credential("tok-b")
        await registry.captureActive()
        vault.active = credential("rotated-by-the-cli")

        let relaunched = makeRegistry(vault) { _ in
            throw ClaudeAccountProfile.Failure.badStatus(401)
        }
        let outcome = await relaunched.activate(uuid: "u-tok-a")

        guard case .failure(.activeAccountUnknown) = outcome else {
            return XCTFail("expected an unarchived credential to be refused")
        }
        XCTAssertEqual(vault.active, credential("rotated-by-the-cli"))
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
