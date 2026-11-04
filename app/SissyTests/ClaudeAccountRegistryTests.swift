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
    /// same modification date to the second.
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

    /// The word the CLI copies into `planDisplayName`, read at its source.
    func testParseTakesThePlansOwnWord() throws {
        let identity = try ClaudeAccountProfile.parse([
            "account": ["uuid": "u-1"],
            "organization": ["organization_type": "claude_max", "plan_display_name": "Ultra"],
        ])
        XCTAssertEqual(identity.planName, "Ultra")
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

    /// The organisation's id is what a reset is spent for.
    func testParseTakesTheOrganisationsId() throws {
        let identity = try ClaudeAccountProfile.parse([
            "account": ["uuid": "u-1"], "organization": ["uuid": "org-1", "name": "Acme Srl"],
        ])

        XCTAssertEqual(identity.organizationUUID, "org-1")
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
    /// here reads the real ones.
    private final class Vault: @unchecked Sendable {
        private let lock = NSLock()
        /// The unscoped item the CLI reads first.
        var active: Data?
        /// The scoped item the default home also carries.
        var scoped: Data?
        /// `.credentials.json` beside the config.
        var file: Data?
        var primaryReadFailure: Error?

        static let primary = ClaudeCLISlot.Name.keychain("primary")
        static let sibling = ClaudeCLISlot.Name.keychain("sibling")

        func slot() -> ClaudeCLISlot {
            ClaudeCLISlot(
                names: { [Self.primary, Self.sibling, .file] },
                read: { [self] name in
                    if name == Self.primary, let primaryReadFailure { throw primaryReadFailure }
                    return lock.withLock {
                        switch name {
                        case Self.primary: active
                        case Self.sibling: scoped
                        default: file
                        }
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

    private func makeRegistry(
        _ vault: Vault,
        now: @escaping @Sendable () -> Date = { Date() },
        identify: @escaping @Sendable (String) async throws -> ClaudeAccountIdentity
    ) -> ClaudeAccountRegistry {
        let store = ClaudeAccountStore(indexURL: ClaudeAccountStore.defaultURL(in: tempDir))
        return ClaudeAccountRegistry(store: store, slot: vault.slot(), identify: identify, now: now)
    }

    private static func byToken(_ token: String) -> ClaudeAccountIdentity {
        ClaudeAccountIdentity(
            uuid: "u-\(token)", email: nil, organization: nil, organizationType: nil,
            rateLimitTier: nil)
    }

    func testCaptureNamesTheActiveAccount() async {
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
    /// whether anything moved, or the picker waits for an unrelated frame to
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
        let moved = await registry.captureActive()

        XCTAssertTrue(first)
        XCTAssertFalse(unchanged)
        XCTAssertTrue(moved)
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

    /// An expired token in the slot answers 401 from the profile endpoint, and
    /// the watch asked again every two minutes for as long as it stayed there:
    /// about 30 refused requests an hour. The token that renews it is asked.
    func testAnExpiredTokenIsNotIdentifiedUntilItRenews() async {
        let vault = Vault()
        vault.active = credential("tok-a", expiresAt: 1_000_000_000_000)
        let asked = LockedValue(0)
        let registry = makeRegistry(
            vault,
            identify: { token in
                asked.update { $0 += 1 }
                return Self.byToken(token)
            })

        await registry.captureActive()
        await registry.captureActive()
        XCTAssertEqual(asked.load(), 0, "the endpoint was asked about a token known to be spent")

        vault.active = credential("tok-a-renewed")
        await registry.captureActive()
        XCTAssertEqual(asked.load(), 1)
    }

    /// A revoked token has an expiry still ahead of it, so that gate never
    /// catches one, and the watch asked about it every two minutes. Its refusal
    /// is remembered until the slot holds a different token.
    func testARefusedTokenIsNotAskedAboutAgainUntilItChanges() async {
        for status in [401, 403] {
            let vault = Vault()
            vault.active = credential("tok-a")
            let asked = LockedValue(0)
            let registry = makeRegistry(
                vault,
                identify: { token in
                    asked.update { $0 += 1 }
                    guard token != "tok-a" else { throw UsageRequestError.badStatus(status) }
                    return Self.byToken(token)
                })

            await registry.captureActive()
            await registry.captureActive()
            XCTAssertEqual(asked.load(), 1, "status \(status) was asked about again")

            vault.active = credential("tok-a-renewed")
            await registry.captureActive()
            XCTAssertEqual(asked.load(), 2, "the new token after \(status) was not asked about")
            XCTAssertEqual(registry.currentSnapshot().activeUUID, Self.byToken("tok-a-renewed").uuid)
        }
    }

    /// An outage says nothing about the token, so it is asked about again.
    func testAFailedIdentificationThatIsNotARefusalIsAskedAgain() async {
        let vault = Vault()
        vault.active = credential("tok-a")
        let asked = LockedValue(0)
        let registry = makeRegistry(
            vault,
            identify: { _ in
                asked.update { $0 += 1 }
                throw UsageRequestError.badStatus(500)
            })

        await registry.captureActive()
        await registry.captureActive()
        XCTAssertEqual(asked.load(), 2)
    }

    /// A 429 from the profile endpoint is waited out, not asked again on the
    /// next tick: the watch polls every two minutes and the endpoint is one
    /// that earns a persistent refusal from exactly that.
    func testARateLimitedIdentificationWaitsOutTheVendorsDelay() async {
        let vault = Vault()
        vault.active = credential("tok-a")
        let clock = LockedValue(Date())
        let asked = LockedValue(0)
        let registry = makeRegistry(
            vault, now: { clock.load() },
            identify: { token in
                asked.update { $0 += 1 }
                guard asked.load() > 1 else {
                    throw UsageRequestError.rateLimited(retryAfter: 600)
                }
                return Self.byToken(token)
            })

        await registry.captureActive()
        await registry.captureActive()
        XCTAssertEqual(asked.load(), 1, "the endpoint was asked again inside its own wait")

        clock.update { $0 = $0.addingTimeInterval(601) }
        await registry.captureActive()
        XCTAssertEqual(asked.load(), 2)
        XCTAssertEqual(registry.currentSnapshot().activeUUID, Self.byToken("tok-a").uuid)
    }

    /// Offline, or a token the vendor will not answer for: the credential is
    /// left alone rather than filed under a guess.
    func testAnUnidentifiableCredentialIsNotFiled() async {
        let vault = Vault()
        vault.active = credential("tok-a")
        let registry = makeRegistry(vault) { _ in
            throw UsageRequestError.badStatus(401)
        }
        await registry.captureActive()

        XCTAssertTrue(registry.currentSnapshot().accounts.isEmpty)
        XCTAssertNil(registry.currentSnapshot().activeUUID)
    }
    // MARK: What is offered

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
        vault.scoped = credential("tok-a")
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

    /// A truncated index holds nothing that decodes. Read as empty, the next
    /// capture wrote over it and every account left the picker.
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
    /// that is going away, and must not write the index after it.
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

        XCTAssertTrue(registry.currentSnapshot().accounts.isEmpty)
        let index = ClaudeAccountStore.defaultURL(in: tempDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: index.path))
    }

    // MARK: A slot that will not read

    /// Bytes that are not a credential blob are a slot Sissy could not read,
    /// which says nothing about who is signed in.
    func testASlotHoldingSomethingThatIsNotABlobChangesNothing() async {
        let vault = Vault()
        vault.active = credential("tok-a")
        let registry = makeRegistry(vault, identify: Self.byToken)
        await registry.captureActive()
        vault.active = Data("not json".utf8)

        let moved = await registry.captureActive()

        XCTAssertFalse(moved)
        XCTAssertEqual(registry.currentSnapshot().activeUUID, "u-tok-a")
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
