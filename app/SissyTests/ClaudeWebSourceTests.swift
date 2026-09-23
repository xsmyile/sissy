import XCTest

@testable import Sissy

/// What one poll of claude.ai publishes, and what each way of failing costs.
final class ClaudeWebSourceTests: XCTestCase {
    private static let session = "sk-ant-sid01-abc"

    private static func window(_ minutes: Int, _ percent: Double) -> UsageWindow {
        UsageWindow(minutes: minutes, usedPercent: percent, resetsAt: .distantFuture)!
    }

    private static func credits(_ used: Int) -> ProviderCredits {
        ProviderCredits(
            isEnabled: true, unit: .money(currency: "EUR", exponent: 2),
            usedMinor: used, capMinor: 30_000, observedAt: Date())
    }

    private func source(
        lookup: @escaping @Sendable (Bool) async -> ClaudeCredentialsLookup,
        fetch: @escaping @Sendable (String, String?) async throws -> ClaudeWebSource.Reading
    ) -> ClaudeWebSource {
        ClaudeWebSource(account: "a1b2c3d4", sessionSource: lookup, fetchSource: fetch)
    }

    private static func found(_ token: String) -> ClaudeCredentialsLookup {
        .found(ClaudeCredentials(accessToken: token, expiresAt: nil))
    }

    // MARK: - Which organization

    /// An account can hold more than one organization, and they answer
    /// different questions. The subscription is the one the plan meters.
    func testPicksTheSubscriptionOrganizationOverAnAPIOne() throws {
        let payload: [Any] = [
            ["uuid": "api-org", "capabilities": ["api", "api_individual"]],
            ["uuid": "chat-org", "capabilities": ["chat", "raven"]],
        ]
        XCTAssertEqual(try ClaudeWebSource.subscriptionOrganization(in: payload), "chat-org")
    }

    /// Position must not decide it: the same two the other way round answer
    /// the same.
    func testTheOrderTheVendorListsThemInDoesNotDecide() throws {
        let payload: [Any] = [
            ["uuid": "chat-org", "capabilities": ["chat"]],
            ["uuid": "api-org", "capabilities": ["api"]],
        ]
        XCTAssertEqual(try ClaudeWebSource.subscriptionOrganization(in: payload), "chat-org")
    }

    /// An account with one organization and no capability list still has one
    /// organization, and reporting it beats reporting nothing.
    func testFallsBackToTheOnlyOrganizationOnOffer() throws {
        let payload: [Any] = [["uuid": "only-org"]]
        XCTAssertEqual(try ClaudeWebSource.subscriptionOrganization(in: payload), "only-org")
    }

    func testAnEmptyAnswerIsMalformedRatherThanAnOrganization() {
        XCTAssertThrowsError(try ClaudeWebSource.subscriptionOrganization(in: []))
    }

    // MARK: - The agent

    /// Measured: the `Claude/<version>` product token is what claude.ai
    /// answers. Losing it is a 403, so it is asserted rather than assumed.
    func testTheAgentCarriesTheProductToken() {
        let agent = ClaudeWebSource.userAgent(appVersion: "9.9.9")
        XCTAssertTrue(agent.contains("Claude/9.9.9"))
        XCTAssertTrue(agent.contains("Safari/537.36"))
    }

    func testTheAgentNamesAVersionEvenWithoutTheAppInstalled() {
        let agent = ClaudeWebSource.userAgent(appVersion: nil)
        XCTAssertTrue(agent.contains("Claude/\(ClaudeWebSource.fallbackAppVersion)"))
    }

    func testReadsTheInstalledAppVersion() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Info-\(UUID().uuidString).plist")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": "1.2.3"], format: .xml, options: 0)
        try plist.write(to: url)
        XCTAssertEqual(ClaudeWebSource.installedAppVersion(at: url), "1.2.3")
    }

    func testAnAbsentAppNamesNoVersion() {
        let missing = URL(fileURLWithPath: "/no/such/Info.plist")
        XCTAssertNil(ClaudeWebSource.installedAppVersion(at: missing))
    }

    // MARK: - One poll

    func testAReadingReachesTheSignals() async {
        let source = source(
            lookup: { _ in Self.found(Self.session) },
            fetch: { _, _ in
                ClaudeWebSource.Reading(
                    organization: "org", windows: [Self.window(300, 42)],
                    credits: Self.credits(26_275))
            })
        _ = await source.refreshOnce {}
        let signals = source.currentSignals()
        XCTAssertEqual(signals.windows.map(\.usedPercent), [42])
        XCTAssertEqual(signals.credits?.usedMinor, 26_275)
        XCTAssertEqual(signals.limitsState, .quiet)
        XCTAssertNotNil(signals.limitsObservedAt)
    }

    /// The organization is resolved once and then carried, so the ordinary
    /// poll is one request rather than two.
    func testTheOrganizationIsCarriedIntoTheNextPoll() async {
        let seen = Sent()
        let source = source(
            lookup: { _ in Self.found(Self.session) },
            fetch: { _, organization in
                await seen.record(organization)
                return ClaudeWebSource.Reading(organization: "org", windows: [], credits: nil)
            })
        _ = await source.refreshOnce {}
        _ = await source.refreshOnce {}
        let organizations = await seen.organizations
        XCTAssertEqual(organizations, [nil, "org"])
    }

    /// A session claude.ai has closed is the one failure the user can act on,
    /// so it is published rather than only logged.
    func testASessionThatEndedIsPublishedAsSuch() async {
        let source = source(
            lookup: { _ in Self.found(Self.session) },
            fetch: { _, _ in throw UsageRequestError.badStatus(401) })
        _ = await source.refreshOnce {}
        XCTAssertEqual(source.currentSignals().limitsState, .sessionExpired)
        XCTAssertTrue(source.currentSignals().windows.isEmpty)
    }

    /// And it drops the held copy, so the next poll reads the item again
    /// rather than spending a session that is already closed.
    func testASessionThatEndedIsReadAgainOnTheNextPoll() async {
        let reads = Sent()
        let source = source(
            lookup: { _ in
                await reads.record(nil)
                return Self.found(Self.session)
            },
            fetch: { _, _ in throw UsageRequestError.badStatus(401) })
        _ = await source.refreshOnce {}
        _ = await source.refreshOnce {}
        let count = await reads.organizations.count
        XCTAssertEqual(count, 2)
    }

    /// A refusal from the host claude.ai redirected to was a refusal of a
    /// request carrying no cookie, so the session, its organization and the
    /// reading all stand, and the next poll does not read the item again.
    func testARefusalFromAnotherHostKeepsTheSession() async {
        let reads = Sent()
        let refuse = LockedValue(false)
        let source = source(
            lookup: { _ in
                await reads.record(nil)
                return Self.found(Self.session)
            },
            fetch: { _, _ in
                if refuse.load() { throw SissyHTTP.LeftItsOrigin(status: 401) }
                return ClaudeWebSource.Reading(
                    organization: "org", windows: [Self.window(300, 42)], credits: nil)
            })
        _ = await source.refreshOnce {}
        refuse.store(true)
        _ = await source.refreshOnce {}
        _ = await source.refreshOnce {}
        XCTAssertNotEqual(source.currentSignals().limitsState, .sessionExpired)
        XCTAssertEqual(source.currentSignals().windows.map(\.usedPercent), [42])
        let count = await reads.organizations.count
        XCTAssertEqual(count, 1)
    }

    /// A private endpoint punishes hammering, so a 429 with no figure of its
    /// own costs the long wait rather than the ordinary one.
    func testRateLimitingEarnsTheLongBackoff() async {
        let source = source(
            lookup: { _ in Self.found(Self.session) },
            fetch: { _, _ in throw UsageRequestError.rateLimited(retryAfter: nil) })
        let delay = await source.refreshOnce {}
        XCTAssertEqual(delay, .seconds(1800))
    }

    /// And it says so on the row: a block the vendor imposed is not a gap in
    /// the reading, and nothing else on the page can tell them apart.
    func testRateLimitingIsPublished() async {
        let source = source(
            lookup: { _ in Self.found(Self.session) },
            fetch: { _, _ in throw UsageRequestError.rateLimited(retryAfter: nil) })
        _ = await source.refreshOnce {}
        guard case .rateLimited(let until) = source.currentSignals().limitsState else {
            return XCTFail("a 429 left the row with nothing to say")
        }
        XCTAssertEqual(until.timeIntervalSinceNow, 1800, accuracy: 5)
    }

    /// Nobody was asked, so nobody refused: the source stays alive and the
    /// row says the grant can be given back.
    func testASilentMissAsksForAuthorizationRatherThanGivingUp() async {
        let source = source(
            lookup: { _ in .interactionRequired },
            fetch: { _, _ in
                XCTFail("a poll with no session must not reach the network")
                throw UsageRequestError.malformedPayload
            })
        _ = await source.refreshOnce {}
        XCTAssertEqual(source.currentSignals().limitsState, .needsAuthorization)
    }

    /// Every reader is built for a session that was listed as stored, so an
    /// item that is not there by the time it is read is a linked session gone
    /// missing, not a Claude Code with no stored login.
    func testAVanishedSessionReadsAsUnreadableRatherThanSignedOut() async {
        let source = source(
            lookup: { _ in .absent },
            fetch: { _, _ in throw UsageRequestError.malformedPayload })
        _ = await source.refreshOnce {}
        XCTAssertEqual(source.currentSignals().limitsState, .sessionUnreadable)
    }

    /// A stored session the keychain will not decode is the same case, and
    /// the same fix: link the account again.
    func testASessionTheKeychainCannotDecodeReadsAsUnreadable() async {
        let source = source(
            lookup: { _ in .unreadable(errSecDecode) },
            fetch: { _, _ in throw UsageRequestError.malformedPayload })
        _ = await source.refreshOnce {}
        XCTAssertEqual(source.currentSignals().limitsState, .sessionUnreadable)
    }

    // MARK: - The recorded organisation

    /// A refusal drops the session and never the organisation the link
    /// recorded: the next poll reads for that organisation rather than for
    /// whichever one the server happens to list first.
    func testARefusedSessionKeepsTheLinkedOrganization() async {
        let seen = Sent()
        let refuse = LockedValue(true)
        let source = ClaudeWebSource(
            account: "a1b2c3d4", organization: "team",
            sessionSource: { _ in Self.found(Self.session) },
            fetchSource: { _, organization in
                await seen.record(organization)
                if refuse.load() { throw UsageRequestError.badStatus(403) }
                return ClaudeWebSource.Reading(
                    organization: organization ?? "derived", windows: [], credits: nil)
            })
        _ = await source.refreshOnce {}
        refuse.store(false)
        _ = await source.refreshOnce {}
        let organizations = await seen.organizations
        XCTAssertEqual(organizations, ["team", "team"])
    }

    /// Switching the source off takes the gauges down with it: the aggregator
    /// rebuilds every slice from what is published, so a reading left behind
    /// would outlive the switch.
    func testSwitchingTheSourceOffClearsWhatItPublished() async {
        let source = source(
            lookup: { _ in Self.found(Self.session) },
            fetch: { _, _ in
                ClaudeWebSource.Reading(
                    organization: "org", windows: [Self.window(300, 42)],
                    credits: Self.credits(1))
            })
        _ = await source.refreshOnce {}
        await source.stop()
        let signals = source.currentSignals()
        XCTAssertTrue(signals.windows.isEmpty)
        XCTAssertNil(signals.credits)
        XCTAssertEqual(signals.limitsState, .quiet)
    }

    /// Records what each call was handed, so a test can assert on the
    /// sequence rather than on a duration.
    private actor Sent {
        private(set) var organizations: [String?] = []
        func record(_ organization: String?) { organizations.append(organization) }
    }
}
