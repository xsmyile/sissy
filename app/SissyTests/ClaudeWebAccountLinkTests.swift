import XCTest

@testable import Sissy

/// What a session has to answer before it is filed.
///
/// Both answers are stored rather than derived per poll, which is the whole
/// point: membership order is the server's, so an account holding a personal
/// plan and a team seat can be read for a different organisation on two
/// consecutive polls of one session.
final class ClaudeWebAccountLinkTests: XCTestCase {
    private static let identity = ClaudeAccountIdentity(
        uuid: "c805523f", email: "someone@example.com", organization: "Master Soft Srl",
        organizationType: "claude_team", rateLimitTier: nil)

    private func resolve(
        organizations: [ClaudeWebOrganization],
        identify: @escaping @Sendable (String) async throws -> ClaudeAccountIdentity = { _ in
            ClaudeWebAccountLinkTests.identity
        }
    ) async throws -> ClaudeWebAccountLink.Outcome {
        try await ClaudeWebAccountLink.resolve(
            session: "sk-ant-sid-live",
            identify: identify,
            organizations: { _ in organizations })
    }

    /// The measured case, and every account seen so far: one organisation
    /// answers the usage question, so there is nothing to ask.
    func testOneSubscriptionOrganizationLinksOutright() async throws {
        let outcome = try await resolve(organizations: [
            ClaudeWebOrganization(id: "org-1", name: "Master Soft Srl", plan: "team")
        ])

        XCTAssertEqual(
            outcome,
            .linked(ClaudeWebLink(identity: Self.identity, organization: "org-1")))
    }

    /// Several, and the pick becomes the user's. Nothing is filed meanwhile.
    func testSeveralSubscriptionOrganizationsAskInstead() async throws {
        let organizations = [
            ClaudeWebOrganization(id: "org-1", name: "Master Soft Srl", plan: "team"),
            ClaudeWebOrganization(id: "org-2", name: "Radon Forge", plan: "max"),
        ]

        let outcome = try await resolve(organizations: organizations)

        XCTAssertEqual(
            outcome, .choice(identity: Self.identity, organizations: organizations))
    }

    /// An account on no chat plan is one Sissy cannot read limits for, which
    /// is a different sentence from a session that did not answer.
    func testAnAccountWithNoSubscriptionIsNamedAsSuch() async {
        do {
            _ = try await resolve(organizations: [])
            XCTFail("expected the link to fail")
        } catch {
            XCTAssertEqual(error as? ClaudeWebAccountLink.Failure, .noSubscription)
        }
    }

    /// A session claude.ai will not answer for is the user's to retry, and
    /// nothing is written for it.
    func testASessionClaudeAiWillNotAnswerForFailsToIdentify() async {
        do {
            _ = try await resolve(
                organizations: [
                    ClaudeWebOrganization(
                        id: "org-1", name: "Master Soft Srl", plan: "team")
                ],
                identify: { _ in throw ClaudeAccountProfile.Failure.badStatus(401) })
            XCTFail("expected the link to fail")
        } catch {
            XCTAssertEqual(error as? ClaudeWebAccountLink.Failure, .unidentified)
        }
    }

    /// The label is the plan, because claude.ai auto-generates the name of the
    /// organisation a personal plan comes with — and in more than one shape,
    /// measured on two accounts, so the name cannot be pattern-matched.
    func testOrganizationsAreLabelledByPlan() {
        let labels = UsageFormat.organizationChoices([
            ClaudeWebOrganization(id: "org-1", name: "Radon Forge", plan: "team"),
            ClaudeWebOrganization(
                id: "org-2", name: "davide@radonforge.com's Organization", plan: "pro"),
        ])

        XCTAssertEqual(labels.map(\.label), ["Team", "Pro"])
    }

    /// Two organisations on one plan are told apart by nothing but their
    /// names, so there the name comes back.
    func testTwoOrganizationsOnOnePlanKeepTheirNames() {
        let labels = UsageFormat.organizationChoices([
            ClaudeWebOrganization(id: "org-1", name: "Radon Forge", plan: "team"),
            ClaudeWebOrganization(id: "org-2", name: "Acme Srl", plan: "team"),
        ])

        XCTAssertEqual(
            labels.map(\.label), ["Team · Radon Forge", "Team · Acme Srl"])
    }

    /// An organisation the vendor named no plan for has only its name.
    func testAnOrganizationWithNoPlanKeepsItsName() {
        let labels = UsageFormat.organizationChoices([
            ClaudeWebOrganization(id: "org-1", name: "Radon Forge", plan: nil)
        ])

        XCTAssertEqual(labels.map(\.label), ["Radon Forge"])
    }

    /// The capability is what names a subscription organisation, and the
    /// measured account's other one answers a different question entirely.
    func testOnlyChatOrganizationsAreOffered() {
        let payload: [[String: Any]] = [
            ["uuid": "org-api", "name": "API", "capabilities": ["api_individual"]],
            ["uuid": "org-1", "name": "Master Soft Srl", "capabilities": ["chat", "claude_pro"]],
            ["uuid": "org-2", "name": "Radon Forge", "capabilities": ["chat"]],
        ]

        let chat = ClaudeWebSource.subscriptionOrganizations(among: payload)

        XCTAssertEqual(chat.compactMap { $0["uuid"] as? String }, ["org-1", "org-2"])
    }
}

/// The file that names what each linked session is for.
final class ClaudeWebSessionIndexTests: XCTestCase {
    private var directory: URL!
    private var index: ClaudeWebSessionIndex!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        index = ClaudeWebSessionIndex(url: ClaudeWebSessionIndex.defaultURL(in: directory))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func link(_ uuid: String, organization: String?) -> ClaudeWebLink {
        ClaudeWebLink(
            identity: ClaudeAccountIdentity(
                uuid: uuid, email: "\(uuid)@example.com", organization: "Org \(uuid)",
                organizationType: "claude_team", rateLimitTier: nil),
            organization: organization)
    }

    /// An index nobody has written is no links, not a failure.
    func testAnAbsentFileIsNoLinks() {
        XCTAssertTrue(index.load().isEmpty)
    }

    func testALinkSurvivesARoundTrip() throws {
        try index.remember(link("c805523f", organization: "org-1"))

        XCTAssertEqual(index.load()["c805523f"]?.organization, "org-1")
        XCTAssertEqual(index.load()["c805523f"]?.identity.email, "c805523f@example.com")
    }

    /// Linking the same account again replaces its entry: the session it
    /// describes has just been replaced too.
    func testRelinkingAnAccountReplacesItsEntry() throws {
        try index.remember(link("c805523f", organization: "org-1"))
        try index.remember(link("c805523f", organization: "org-2"))

        XCTAssertEqual(index.load().count, 1)
        XCTAssertEqual(index.load()["c805523f"]?.organization, "org-2")
    }

    /// A session adopted from Claude.app was never asked about, so it records
    /// no organisation rather than the one a capability happened to pick.
    func testAnAdoptedSessionRecordsNoOrganization() throws {
        try index.remember(link("c805523f", organization: nil))

        XCTAssertNil(index.load()["c805523f"]?.organization)
        XCTAssertNotNil(index.load()["c805523f"])
    }

    func testForgettingOneLeavesTheOthers() throws {
        try index.remember(link("c805523f", organization: "org-1"))
        try index.remember(link("dbab20e1", organization: "org-2"))

        try index.forget(uuid: "c805523f")

        XCTAssertEqual(Array(index.load().keys), ["dbab20e1"])
    }

    func testForgettingEverythingEmptiesIt() throws {
        try index.remember(link("c805523f", organization: "org-1"))
        try index.remember(link("dbab20e1", organization: "org-2"))

        try index.forgetAll()

        XCTAssertTrue(index.load().isEmpty)
    }
}
