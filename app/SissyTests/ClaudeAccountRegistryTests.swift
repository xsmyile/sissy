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

    /// A URL built while `~/.claude` did not exist has no trailing slash, and
    /// one built after it was created has one. Both are the default home.
    func testTheDefaultHomeIsRecognisedWhetherOrNotItExistedAtLaunch() {
        let path = AccountDefaults.claudeHome.standardizedFileURL.path
        let before = URL(fileURLWithPath: path, isDirectory: false)
        let after = URL(fileURLWithPath: path + "/", isDirectory: true)

        XCTAssertEqual(ClaudeKeychainCLI.claudeService(for: before), ClaudeKeychainCLI.claudeService)
        XCTAssertEqual(ClaudeKeychainCLI.claudeService(for: after), ClaudeKeychainCLI.claudeService)
        XCTAssertEqual(ClaudeKeychainCLI.siblingClaudeServices(for: after).count, 1)
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

    /// Stands in for the login keychain and the CLI's mirror file, so nothing
    /// here reads or writes the real ones.
    private final class Vault: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: Data] = [:]
        /// The unscoped item the CLI reads first.
        var active: Data?
        /// The CLI's other names for the same home, which a switch has to
        /// reach and must not overwrite blind. The default home always has
        /// one such name, holding an item or not, and a name set to nil is
        /// one whose item was removed.
        var siblings: [Data?] = []
        var siblingFailure: Error?
        /// `.credentials.json` beside the config.
        var file: Data?
        var fileReadFailure: Error?
        /// Writes that throw, by name, and whether a put-back throws too.
        var writeFailures: [ClaudeCLISlot.Name: Error] = [:]
        /// Writes that land and then throw, once each, the way a `security`
        /// process that commits and then outlives its budget does.
        var landThenFail: [ClaudeCLISlot.Name: Error] = [:]
        var containsFailure: Error?
        var restoreFails = false
        var secretReadFailure: Error?
        var primaryReadFailure: Error?
        private(set) var writes = 0
        /// Every name a write or a removal reached, in order.
        private(set) var touched: [ClaudeCLISlot.Name] = []
        private(set) var removed: [ClaudeCLISlot.Name] = []
        private var failed = false

        static let primary = ClaudeCLISlot.Name.keychain("primary")

        static func sibling(_ index: Int) -> ClaudeCLISlot.Name { .keychain("sibling-\(index)") }

        func secret(_ uuid: String) -> Data? { lock.withLock { items[uuid] } }

        func dropSecret(_ uuid: String) { lock.withLock { items[uuid] = nil } }

        func secrets() -> ClaudeAccountStore.Secrets {
            ClaudeAccountStore.Secrets(
                read: { [self] uuid in
                    if let secretReadFailure { throw secretReadFailure }
                    return lock.withLock { items[uuid] }
                },
                write: { [self] uuid, data in lock.withLock { items[uuid] = data } },
                contains: { [self] uuid in
                    if let containsFailure { throw containsFailure }
                    return lock.withLock { items[uuid] != nil }
                })
        }

        private func value(_ name: ClaudeCLISlot.Name) -> Data? {
            switch name {
            case Self.primary: return active
            case .file: return file
            case .keychain(let service):
                guard let index = Int(service.dropFirst("sibling-".count)),
                    siblings.indices.contains(index)
                else { return nil }
                return siblings[index]
            }
        }

        private func store(_ data: Data?, at name: ClaudeCLISlot.Name) {
            switch name {
            case Self.primary: active = data
            case .file: file = data
            case .keychain(let service):
                guard let index = Int(service.dropFirst("sibling-".count)) else { return }
                if siblings.count <= index {
                    siblings += Array(repeating: nil, count: index + 1 - siblings.count)
                }
                siblings[index] = data
            }
        }

        func slot() -> ClaudeCLISlot {
            ClaudeCLISlot(
                names: { [self] in
                    [Self.primary] + (0..<max(siblings.count, 1)).map(Self.sibling) + [.file]
                },
                read: { [self] name in
                    switch name {
                    case Self.primary: if let primaryReadFailure { throw primaryReadFailure }
                    case .file: if let fileReadFailure { throw fileReadFailure }
                    case .keychain: if let siblingFailure { throw siblingFailure }
                    }
                    return lock.withLock { value(name) }
                },
                write: { [self] name, data in
                    try lock.withLock {
                        if let failure = writeFailures[name] {
                            failed = true
                            throw failure
                        }
                        if restoreFails, failed { throw ClaudeKeychainCLI.Failure.tool(1) }
                        store(data, at: name)
                        writes += 1
                        touched.append(name)
                        if let failure = landThenFail.removeValue(forKey: name) {
                            failed = true
                            throw failure
                        }
                    }
                },
                remove: { [self] name in
                    try lock.withLock {
                        if restoreFails, failed { throw ClaudeKeychainCLI.Failure.tool(1) }
                        store(nil, at: name)
                        touched.append(name)
                        removed.append(name)
                    }
                })
        }
    }

    private func credential(
        _ token: String, expiresAt: Int = 4_102_444_800_000, inner: String = "",
        extra: String = ""
    ) -> Data {
        Data(
            """
            {"claudeAiOauth":{"accessToken":"\(token)","expiresAt":\(expiresAt)\(inner)}\(extra)}
            """.utf8)
    }

    private func token(_ data: Data?) -> String? {
        data.flatMap { ClaudeCredentialBlob.credentials(in: $0)?.accessToken }
    }

    private func makeRegistry(
        _ vault: Vault,
        now: @escaping @Sendable () -> Date = { Date() },
        identify: @escaping @Sendable (String) async throws -> ClaudeAccountIdentity
    ) -> ClaudeAccountRegistry {
        var store = ClaudeAccountStore(indexURL: ClaudeAccountStore.defaultURL(in: tempDir))
        store.secrets = vault.secrets()
        return ClaudeAccountRegistry(
            store: store, slot: vault.slot(), identify: identify, now: now)
    }

    private static func byToken(_ token: String) -> ClaudeAccountIdentity {
        ClaudeAccountIdentity(
            uuid: "u-\(token)", email: nil, organization: nil, organizationType: nil,
            rateLimitTier: nil)
    }

    /// Archives A and B, leaving the CLI on A.
    private func archiveTwo(_ vault: Vault, _ registry: ClaudeAccountRegistry) async {
        vault.active = credential("tok-a")
        await registry.captureActive()
        vault.active = credential("tok-b")
        await registry.captureActive()
        vault.active = credential("tok-a")
        await registry.captureActive()
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
    /// called itself a success. Exit 51 is a keychain that cannot be used right
    /// now, which is its own sentence rather than a bare status.
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

        guard case .failure(.keychainUnavailable) = outcome else {
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

        guard case .failure(.slotChanged) = outcome else {
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
    // MARK: What is offered

    /// An archived secret removed while Sissy runs is noticed by the poll
    /// that follows, not only by a relaunch.
    func testASecretRemovedWhileRunningStopsBeingSwitchableOnTheNextPoll() async {
        let vault = Vault()
        let registry = makeRegistry(vault, identify: Self.byToken)
        await archiveTwo(vault, registry)
        XCTAssertTrue(registry.currentSnapshot().switchable.contains("u-tok-b"))
        vault.dropSecret("u-tok-b")

        let moved = await registry.captureActive()

        XCTAssertTrue(moved)
        XCTAssertEqual(registry.currentSnapshot().switchable, ["u-tok-a"])
    }

    /// A keychain that would not answer at the first poll is asked again at
    /// the next, rather than leaving an archived account unoffered all run.
    func testAPresenceLookupThatFailedOnceIsAskedAgain() async {
        let vault = Vault()
        let registry = makeRegistry(vault, identify: Self.byToken)
        await archiveTwo(vault, registry)
        vault.containsFailure = ClaudeKeychainCLI.Failure.unavailable
        let relaunched = makeRegistry(vault, identify: Self.byToken)
        await relaunched.captureActive()
        XCTAssertTrue(relaunched.currentSnapshot().switchable.isEmpty)
        vault.containsFailure = nil

        await relaunched.captureActive()

        XCTAssertEqual(relaunched.currentSnapshot().switchable, ["u-tok-a", "u-tok-b"])
    }

    /// An index entry is a name Sissy has seen. Without the secret behind it
    /// the click can only fail, so the account is listed and not offered.
    func testAnIndexEntryWithNoArchivedSecretIsNotSwitchable() async {
        let vault = Vault()
        let registry = makeRegistry(vault, identify: Self.byToken)
        await archiveTwo(vault, registry)
        vault.dropSecret("u-tok-b")

        let relaunched = makeRegistry(vault, identify: Self.byToken)
        await relaunched.captureActive()

        let snapshot = relaunched.currentSnapshot()
        XCTAssertEqual(Set(snapshot.accounts.map(\.uuid)), ["u-tok-a", "u-tok-b"])
        XCTAssertEqual(snapshot.switchable, ["u-tok-a"])
    }

    /// A refresh token that has expired cannot be renewed by anything but a
    /// login, so the account is not offered and a switch to it says so.
    func testAnExpiredRefreshTokenIsNotSwitchable() async {
        let vault = Vault()
        let expired = Date(timeIntervalSince1970: 1_700_000_000)
        let registry = makeRegistry(
            vault, now: { Date(timeIntervalSince1970: 1_800_000_000) }, identify: Self.byToken)
        let refreshMillis = Int(expired.timeIntervalSince1970 * 1000)
        vault.active = credential(
            "tok-b", inner: #","refreshTokenExpiresAt":\#(refreshMillis)"#)
        await registry.captureActive()
        vault.active = credential("tok-a")
        await registry.captureActive()

        let outcome = await registry.activate(uuid: "u-tok-b")

        guard case .failure(.needsLogin) = outcome else { return XCTFail("expected needsLogin") }
        XCTAssertEqual(registry.currentSnapshot().needsLogin, ["u-tok-b"])
        XCTAssertFalse(registry.currentSnapshot().switchable.contains("u-tok-b"))
        XCTAssertEqual(token(vault.active), "tok-a")
    }

    // MARK: Where the credential is read from

    /// A CLI that keeps no keychain item writes `.credentials.json`, and that
    /// is the account it is running as.
    func testTheFileIsCapturedWhenNoKeychainItemHoldsOne() async {
        let vault = Vault()
        vault.file = credential("tok-a")
        let registry = makeRegistry(vault, identify: Self.byToken)

        await registry.captureActive()

        XCTAssertEqual(registry.currentSnapshot().activeUUID, "u-tok-a")
    }

    /// Measured 2026-09-23 against Claude Code 2.1.280: a `/login` wrote the
    /// unscoped item alone, and the scoped item and the file kept the account
    /// before it. The name on the row and the limits under it both have to be
    /// the unscoped item's.
    func testIdentityAndLimitsBothComeFromTheUnscopedItem() async {
        let vault = Vault()
        vault.active = credential("tok-b")
        vault.siblings = [credential("tok-a")]
        vault.file = credential("tok-a")
        let registry = makeRegistry(vault, identify: Self.byToken)

        await registry.captureActive()
        let limits = ClaudeCodeCredentials.load(slot: vault.slot())

        XCTAssertEqual(registry.currentSnapshot().activeUUID, "u-tok-b")
        guard case .found(let found) = limits else { return XCTFail("expected a credential") }
        XCTAssertEqual(found.accessToken, "tok-b")
    }

    /// A signed-out CLI is on no account, whatever the index noted last.
    func testASlotThatEmptiedClearsTheActiveAccount() async {
        let vault = Vault()
        vault.active = credential("tok-a")
        let registry = makeRegistry(vault, identify: Self.byToken)
        await registry.captureActive()

        vault.active = nil
        let moved = await registry.captureActive()

        XCTAssertTrue(moved)
        XCTAssertNil(registry.currentSnapshot().activeUUID)
    }

    // MARK: What a switch reads

    /// A mirror that cannot be read is not a mirror with nothing in it: the
    /// switch is refused rather than written over a name it never saw.
    func testAnUnreadableMirrorRefusesTheSwitch() async {
        let vault = Vault()
        let registry = makeRegistry(vault, identify: Self.byToken)
        await archiveTwo(vault, registry)
        vault.fileReadFailure = CocoaError(.fileReadNoPermission)

        let outcome = await registry.activate(uuid: "u-tok-b")

        guard case .failure(.slotUnreadable) = outcome else {
            return XCTFail("expected the unreadable mirror to refuse the switch")
        }
        XCTAssertEqual(token(vault.active), "tok-a")
    }

    /// The mirror is one of the names the switch overwrites, so an account in
    /// it that nothing archived is archived first.
    func testAMirrorHoldingAnUnarchivedAccountIsArchivedBeforeTheSwitch() async {
        let vault = Vault()
        let registry = makeRegistry(vault, identify: Self.byToken)
        await archiveTwo(vault, registry)
        vault.file = credential("tok-c")

        let outcome = await registry.activate(uuid: "u-tok-b")

        guard case .success = outcome else { return XCTFail("expected the switch to succeed") }
        XCTAssertNotNil(vault.secret("u-tok-c"))
        XCTAssertEqual(token(vault.file), "tok-b")
    }

    /// A secret the keychain would not hand over is not an account that was
    /// never archived, and must not be worded as one.
    func testAnArchiveTheKeychainWouldNotReadIsNotNotArchived() async {
        let vault = Vault()
        let registry = makeRegistry(vault, identify: Self.byToken)
        await archiveTwo(vault, registry)
        vault.secretReadFailure = ClaudeKeychainCLI.Failure.unavailable

        let outcome = await registry.activate(uuid: "u-tok-b")

        guard case .failure(.keychainUnavailable) = outcome else {
            return XCTFail("expected keychainUnavailable")
        }
    }

    // MARK: What a switch writes

    /// Only the account half is archived; the MCP logins beside it are the
    /// CLI's as they are now.
    func testTheArchiveKeepsOnlyTheAccountHalf() async {
        let vault = Vault()
        vault.active = credential("tok-a", extra: #","mcpOAuth":{"server":"m1"}"#)
        let registry = makeRegistry(vault, identify: Self.byToken)

        await registry.captureActive()

        let archived = vault.secret("u-tok-a").flatMap(ClaudeCredentialBlob.object)
        XCTAssertEqual(archived.map { Set($0.keys) }, [ClaudeCredentialBlob.oauthKey])
    }

    /// A → B → A with an MCP login made in between: the login stays as it is
    /// live, and only the account changes.
    func testMCPLoginsSurviveASwitchAndBack() async {
        let vault = Vault()
        let registry = makeRegistry(vault, identify: Self.byToken)
        vault.active = credential("tok-b", extra: #","mcpOAuth":{"server":"m0"}"#)
        await registry.captureActive()
        vault.active = credential("tok-a", extra: #","mcpOAuth":{"server":"m1"}"#)
        await registry.captureActive()

        guard case .success = await registry.activate(uuid: "u-tok-b") else {
            return XCTFail("switching to B failed")
        }
        vault.active = vault.active.flatMap {
            ClaudeCredentialBlob.merging(
                account: $0, into: Data(#"{"mcpOAuth":{"server":"m2"}}"#.utf8))
        }
        guard case .success = await registry.activate(uuid: "u-tok-a") else {
            return XCTFail("switching back to A failed")
        }

        let live = vault.active.flatMap(ClaudeCredentialBlob.object)
        XCTAssertEqual(token(vault.active), "tok-a")
        XCTAssertEqual((live?["mcpOAuth"] as? [String: String])?["server"], "m2")
    }

    /// A keychain that is locked or will not answer is one sentence, not a
    /// status code and not a missing login.
    func testALockedKeychainOnWriteIsKeychainUnavailable() async {
        let vault = Vault()
        let registry = makeRegistry(vault, identify: Self.byToken)
        await archiveTwo(vault, registry)
        vault.writeFailures[Vault.primary] = ClaudeKeychainCLI.Failure.tool(36)

        let outcome = await registry.activate(uuid: "u-tok-b")

        guard case .failure(.keychainUnavailable) = outcome else {
            return XCTFail("expected keychainUnavailable")
        }
        XCTAssertEqual(token(vault.active), "tok-a")
    }

    /// Any other refusal keeps its status.
    func testAnotherKeychainRefusalKeepsItsStatus() async {
        let vault = Vault()
        let registry = makeRegistry(vault, identify: Self.byToken)
        await archiveTwo(vault, registry)
        vault.writeFailures[Vault.primary] = ClaudeKeychainCLI.Failure.tool(25)

        let outcome = await registry.activate(uuid: "u-tok-b")

        guard case .failure(.keychain(25)) = outcome else { return XCTFail("expected keychain(25)") }
    }

    /// The mirror is written last. When it refuses, the keychain items that
    /// already took the new account are put back, so the names still agree.
    func testAMirrorThatRefusesPutsTheKeychainBack() async {
        let vault = Vault()
        let registry = makeRegistry(vault, identify: Self.byToken)
        await archiveTwo(vault, registry)
        vault.file = credential("tok-a")
        vault.writeFailures[.file] = CocoaError(.fileWriteNoPermission)

        let outcome = await registry.activate(uuid: "u-tok-b")

        guard case .failure(.mirrorWrite) = outcome else { return XCTFail("expected mirrorWrite") }
        XCTAssertEqual(token(vault.active), "tok-a")
        XCTAssertEqual(token(vault.file), "tok-a")
        XCTAssertEqual(registry.currentSnapshot().activeUUID, "u-tok-a")
    }

    /// Only a put-back that fails too leaves the names disagreeing, and that
    /// is the one case worded as a switch stopped part way.
    func testAPutBackThatFailsIsAPartialSwitch() async {
        let vault = Vault()
        let registry = makeRegistry(vault, identify: Self.byToken)
        await archiveTwo(vault, registry)
        vault.file = credential("tok-a")
        vault.writeFailures[.file] = CocoaError(.fileWriteNoPermission)
        vault.restoreFails = true

        let outcome = await registry.activate(uuid: "u-tok-b")

        guard case .failure(.partialSwitch) = outcome else { return XCTFail("expected partialSwitch") }
    }

    /// A write can land and still report a failure, as a `security` process
    /// that commits and then outlives its budget does. That name is put back
    /// too, so the error's claim that nothing changed is true.
    func testAWriteThatLandedBeforeItFailedIsPutBack() async {
        let vault = Vault()
        let registry = makeRegistry(vault, identify: Self.byToken)
        await archiveTwo(vault, registry)
        vault.landThenFail[Vault.primary] = ClaudeKeychainCLI.Failure.unavailable

        let outcome = await registry.activate(uuid: "u-tok-b")

        guard case .failure(.keychainUnavailable) = outcome else {
            return XCTFail("expected keychainUnavailable")
        }
        XCTAssertEqual(token(vault.active), "tok-a")
        XCTAssertEqual(registry.currentSnapshot().activeUUID, "u-tok-a")
    }

    /// And when that name will not go back, the switch is reported as the
    /// partial one it is rather than as a refusal that changed nothing.
    func testAWriteThatLandedAndWillNotGoBackIsAPartialSwitch() async {
        let vault = Vault()
        let registry = makeRegistry(vault, identify: Self.byToken)
        await archiveTwo(vault, registry)
        vault.landThenFail[Vault.primary] = ClaudeKeychainCLI.Failure.unavailable
        vault.restoreFails = true

        let outcome = await registry.activate(uuid: "u-tok-b")

        guard case .failure(.partialSwitch) = outcome else { return XCTFail("expected partialSwitch") }
    }

    /// A name that held nothing before the switch and took the account is
    /// taken away again when a later write fails, rather than left holding an
    /// account the other names do not.
    func testANameCreatedByAFailedSwitchIsRemovedAgain() async {
        let vault = Vault()
        let registry = makeRegistry(vault, identify: Self.byToken)
        await archiveTwo(vault, registry)
        vault.file = credential("tok-a")
        vault.active = nil
        vault.writeFailures[.file] = CocoaError(.fileWriteNoPermission)

        let outcome = await registry.activate(uuid: "u-tok-b")

        guard case .failure(.mirrorWrite) = outcome else { return XCTFail("expected mirrorWrite") }
        XCTAssertNil(vault.active)
        XCTAssertEqual(vault.removed, [Vault.primary])
        XCTAssertEqual(token(vault.file), "tok-a")
    }

    /// A sibling that holds nothing is not a name the CLI reads, so a switch
    /// never writes it, and a rollback has nothing there to take away. The
    /// removal above is therefore reachable only through the primary name.
    func testAnEmptySiblingIsNeitherWrittenNorRolledBack() async {
        let vault = Vault()
        let registry = makeRegistry(vault, identify: Self.byToken)
        await archiveTwo(vault, registry)
        vault.siblings = [nil]
        vault.file = credential("tok-a")
        vault.writeFailures[.file] = CocoaError(.fileWriteNoPermission)

        let outcome = await registry.activate(uuid: "u-tok-b")

        guard case .failure(.mirrorWrite) = outcome else { return XCTFail("expected mirrorWrite") }
        XCTAssertFalse(vault.touched.contains(Vault.sibling(0)))
        XCTAssertEqual(vault.siblings, [nil])
        XCTAssertEqual(token(vault.active), "tok-a")
    }

    // MARK: Reentrancy

    /// The poll's capture is one at a time: a second one that arrives while
    /// the first waits on the vendor does not identify the same token again
    /// behind it.
    func testCapturesDoNotStackBehindOneInFlight() async {
        let vault = Vault()
        vault.active = credential("tok-a")
        let entered = expectation(description: "the first capture is identifying")
        let gate = Latch()
        let calls = LockedValue(0)
        let registry = makeRegistry(vault) { token in
            calls.update { $0 += 1 }
            if calls.load() == 1 {
                entered.fulfill()
                await gate.wait()
            }
            return Self.byToken(token)
        }

        let first = Task { await registry.captureActive() }
        await fulfillment(of: [entered], timeout: 5)
        let second = await registry.captureActive()
        gate.open()
        let moved = await first.value

        XCTAssertFalse(second)
        XCTAssertTrue(moved)
        XCTAssertEqual(calls.load(), 1)
        XCTAssertEqual(registry.currentSnapshot().activeUUID, "u-tok-a")
    }

    /// A poll suspended on identifying a rotation must not put the badge back
    /// on the account a switch made while it was away has just left.
    func testACaptureResumingAfterASwitchDoesNotUndoIt() async {
        let vault = Vault()
        let entered = expectation(description: "the poll is identifying")
        let gate = Latch()
        let first = LockedValue(true)
        let registry = makeRegistry(vault) { token in
            if token == "tok-a1", first.load() {
                first.update { $0 = false }
                entered.fulfill()
                await gate.wait()
            }
            return ClaudeAccountIdentity(
                uuid: token.hasPrefix("tok-a") ? "u-a" : "u-b", email: nil, organization: nil,
                organizationType: nil, rateLimitTier: nil)
        }
        vault.active = credential("tok-b")
        await registry.captureActive()
        vault.active = credential("tok-a")
        await registry.captureActive()
        vault.active = credential("tok-a1")

        let poll = Task { await registry.captureActive() }
        await fulfillment(of: [entered], timeout: 5)
        let outcome = await registry.activate(uuid: "u-b")
        gate.open()
        _ = await poll.value

        guard case .success = outcome else { return XCTFail("expected the switch to succeed") }
        XCTAssertEqual(token(vault.active), "tok-b")
        XCTAssertEqual(registry.currentSnapshot().activeUUID, "u-b")
    }

    // MARK: The index

    /// An index that will not read is moved aside, byte for byte, rather than
    /// read as empty and written over by the next capture.
    func testACorruptIndexIsSetAsideRatherThanOverwritten() async throws {
        let vault = Vault()
        let indexURL = ClaudeAccountStore.defaultURL(in: tempDir)
        let corrupt = Data("{not json".utf8)
        try corrupt.write(to: indexURL)
        vault.active = credential("tok-a")
        let registry = makeRegistry(vault, identify: Self.byToken)

        await registry.captureActive()

        let aside = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
            .filter { $0.hasPrefix(ClaudeAccountStore.setAsidePrefix) }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: tempDir.appendingPathComponent(aside[0])), corrupt)
        XCTAssertTrue(registry.currentSnapshot().indexSetAside)
        XCTAssertEqual(registry.currentSnapshot().accounts.map(\.uuid), ["u-tok-a"])
    }

    /// Absent is not unreadable: a first launch starts an index and says
    /// nothing about one being set aside.
    func testAMissingIndexIsAnEmptyOneAndNothingIsSetAside() async {
        let vault = Vault()
        vault.active = credential("tok-a")
        let registry = makeRegistry(vault, identify: Self.byToken)

        await registry.captureActive()

        XCTAssertFalse(registry.currentSnapshot().indexSetAside)
        XCTAssertEqual(registry.currentSnapshot().accounts.map(\.uuid), ["u-tok-a"])
    }

    /// A truncated index holds nothing that decodes, and the archived secrets
    /// it named are still in the keychain. Read as empty, the next capture
    /// wrote over it and every one of them left the switcher.
    func testAnEmptyIndexIsSetAsideRatherThanOverwritten() async throws {
        let vault = Vault()
        try Data().write(to: ClaudeAccountStore.defaultURL(in: tempDir))
        vault.active = credential("tok-a")
        let registry = makeRegistry(vault, identify: Self.byToken)

        await registry.captureActive()

        let aside = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
            .filter { $0.hasPrefix(ClaudeAccountStore.setAsidePrefix) }
        XCTAssertEqual(aside.count, 1)
        XCTAssertTrue(registry.currentSnapshot().indexSetAside)
    }

    // MARK: Teardown

    /// A watcher cancelled while it waits on the vendor belongs to an engine
    /// that is going away, and must not write the archive after it.
    func testACaptureCancelledDuringIdentificationWritesNothing() async {
        let vault = Vault()
        vault.active = credential("tok-a")
        let entered = expectation(description: "the capture is identifying")
        let gate = Latch()
        let registry = makeRegistry(vault) { token in
            entered.fulfill()
            await gate.wait()
            return Self.byToken(token)
        }

        let poll = Task { await registry.captureActive() }
        await fulfillment(of: [entered], timeout: 5)
        poll.cancel()
        gate.open()
        _ = await poll.value

        XCTAssertNil(vault.secret("u-tok-a"))
        XCTAssertTrue(registry.currentSnapshot().accounts.isEmpty)
        let index = ClaudeAccountStore.defaultURL(in: tempDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: index.path))
    }

    // MARK: Expiry

    /// Nothing about the active credential changes when an archived refresh
    /// token dies, so the poll is what has to notice it.
    func testARefreshTokenThatDiesWhileNothingChangesStopsBeingSwitchable() async {
        let vault = Vault()
        let clock = LockedValue(Date(timeIntervalSince1970: 1_800_000_000))
        let registry = makeRegistry(vault, now: { clock.load() }, identify: Self.byToken)
        let refreshMillis = Int((1_800_000_000 + 60) * 1000)
        vault.active = credential(
            "tok-b", inner: #","refreshTokenExpiresAt":\#(refreshMillis)"#)
        await registry.captureActive()
        vault.active = credential("tok-a")
        await registry.captureActive()
        XCTAssertTrue(registry.currentSnapshot().switchable.contains("u-tok-b"))

        clock.update { $0 = $0.addingTimeInterval(120) }
        let moved = await registry.captureActive()

        XCTAssertTrue(moved)
        XCTAssertFalse(registry.currentSnapshot().switchable.contains("u-tok-b"))
        XCTAssertEqual(registry.currentSnapshot().needsLogin, ["u-tok-b"])
    }

    // MARK: Why a switch was refused

    /// Bytes that are not a credential blob cannot be merged into, and that
    /// is a slot Sissy could not read rather than an account it could not
    /// name.
    func testASlotHoldingSomethingThatIsNotABlobIsUnreadable() async {
        let vault = Vault()
        let registry = makeRegistry(vault, identify: Self.byToken)
        await archiveTwo(vault, registry)
        vault.siblings = [Data("not json".utf8)]

        let outcome = await registry.activate(uuid: "u-tok-b")

        guard case .failure(.slotUnreadable) = outcome else {
            return XCTFail("expected slotUnreadable")
        }
        XCTAssertEqual(token(vault.active), "tok-a")
    }

    // MARK: One credential for the row

    private func probe(spending token: String) async -> ClaudeLimitsProbe {
        let probe = ClaudeLimitsProbe(
            credentials: { _ in
                .found(ClaudeCredentials(accessToken: token, expiresAt: .distantFuture))
            },
            fetch: { _ in
                ClaudeLimitsProbe.Reading(
                    windows: [UsageWindow(minutes: 300, usedPercent: 40, resetsAt: .distantFuture)!],
                    credits: nil)
            })
        _ = await probe.refreshOnce {}
        return probe
    }

    private func signals(
        _ registry: ClaudeAccountRegistry, _ probe: ClaudeLimitsProbe,
        profile: ClaudeProfileSource? = nil
    ) -> ProviderSignals {
        ClaudeCodeSignals(
            limitsProbe: probe, webSources: LockedValue([]), webLinks: LockedValue([:]),
            profile: profile
                ?? ClaudeProfileSource(url: tempDir.appendingPathComponent("absent.json")),
            accounts: registry
        ).currentSignals()
    }

    /// A `.claude.json` naming one account, read the way the engine reads it.
    private func profile(naming uuid: String) throws -> ClaudeProfileSource {
        let url = tempDir.appendingPathComponent("claude.json")
        try Data(
            #"{"oauthAccount":{"accountUuid":"\#(uuid)","organizationType":"claude_max"}}"#.utf8
        ).write(to: url)
        let source = ClaudeProfileSource(url: url)
        source.refresh()
        return source
    }

    /// A registry that has identified nobody leaves the config file's owner
    /// as the name on the row, and a reading nothing matched to that name
    /// does not go under it: the file can name the account before a
    /// `/login`, and the probe can have spent the token after it.
    func testLimitsAreNotLaidUnderTheFilesOwnerWhenNothingVerifiedTheToken() async throws {
        let registry = makeRegistry(Vault(), identify: Self.byToken)

        let reading = signals(
            registry, await probe(spending: "tok-b"), profile: try profile(naming: "u-tok-a"))

        XCTAssertNil(registry.currentSnapshot().activeUUID)
        XCTAssertEqual(reading.plan, "max")
        XCTAssertTrue(reading.windows.isEmpty)
    }

    /// Where nothing names an account at all, there is no name to put the
    /// reading under wrongly, and it stands.
    func testLimitsStandWhenNothingNamesAnAccount() async {
        let registry = makeRegistry(Vault(), identify: Self.byToken)

        let reading = signals(registry, await probe(spending: "tok-b"))

        XCTAssertEqual(reading.windows.map(\.usedPercent), [40])
    }

    /// A `/login` between the registry's poll and the probe's: the probe has
    /// already spent the new account's token while the registry still names
    /// the old one. The reading must not go under that name.
    func testLimitsReadWithAnotherAccountsTokenAreNotLaidUnderTheSignedInName() async {
        let vault = Vault()
        vault.active = credential("tok-a")
        let registry = makeRegistry(vault, identify: Self.byToken)
        await registry.captureActive()
        vault.active = credential("tok-b")

        let reading = signals(registry, await probe(spending: "tok-b"))

        XCTAssertEqual(registry.currentSnapshot().activeUUID, "u-tok-a")
        XCTAssertTrue(reading.windows.isEmpty)
    }

    /// The same credential on both sides is the ordinary case, and the probe
    /// answers for the row.
    func testLimitsReadWithTheIdentifiedTokenAreLaidOnTheRow() async {
        let vault = Vault()
        vault.active = credential("tok-a")
        let registry = makeRegistry(vault, identify: Self.byToken)
        await registry.captureActive()

        let reading = signals(registry, await probe(spending: "tok-a"))

        XCTAssertEqual(reading.windows.map(\.usedPercent), [40])
    }
}

/// Holds an async caller until the test lets it go.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if opened { return true }
                waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let pending = lock.withLock {
            opened = true
            defer { waiter = nil }
            return waiter
        }
        pending?.resume()
    }
}
