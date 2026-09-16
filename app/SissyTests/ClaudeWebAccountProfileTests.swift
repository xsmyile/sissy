import XCTest

@testable import Sissy

/// What claude.ai's own reply says about who a session belongs to, and the one
/// field of it that must not be believed.
///
/// The payload shape is the measured one, 2026-09-16: an account holding two
/// organisations, the subscription second in the list.
final class ClaudeWebAccountProfileTests: XCTestCase {
    private func payload(
        uuid: String = "c805523f-9d83-47ca-bb1a-4d6c94dd75bf",
        organizations: [[String: Any]]? = nil
    ) -> [String: Any] {
        [
            "uuid": uuid,
            "email_address": "someone@example.com",
            "memberships": (organizations ?? [individualOrganization, subscriptionOrganization])
                .map { ["organization": $0, "seat_tier": "team_tier_1"] },
        ]
    }

    private let subscriptionOrganization: [String: Any] = [
        "uuid": "1001ddb9-0acb-481b-927e-00244ed840ba",
        "name": "Master Soft Srl",
        "capabilities": ["chat", "raven"],
        "analytics_subscription_plan": "claude_team",
        "rate_limit_tier": "default_raven",
    ]

    private let individualOrganization: [String: Any] = [
        "uuid": "365c4aa6-2e03-4b6e-a529-6871eaab8c74",
        "name": "Someone's Individual Org",
        "capabilities": ["api", "api_individual"],
        "analytics_subscription_plan": "api_individual",
        "rate_limit_tier": "auto_api_evaluation",
    ]

    /// The whole reason this type produces `ClaudeAccountIdentity` rather than
    /// one of its own: measured, both vendors' endpoints answer this id for
    /// the same person, so a session and a CLI credential file under one key.
    func testTheAccountIsIdentifiedByAnthropicsOwnID() throws {
        let identity = try ClaudeWebAccountProfile.parse(payload())

        XCTAssertEqual(identity.uuid, "c805523f-9d83-47ca-bb1a-4d6c94dd75bf")
        XCTAssertEqual(identity.email, "someone@example.com")
    }

    /// An account can hold several organisations answering different
    /// questions. Reading the plan off the first listed would badge the
    /// subscription with the API org's, which nobody is on.
    func testThePlanComesFromTheSubscriptionOrganizationNotTheFirst() throws {
        let identity = try ClaudeWebAccountProfile.parse(payload())

        XCTAssertEqual(identity.organization, "Master Soft Srl")
        XCTAssertEqual(identity.organizationType, "claude_team")
    }

    /// The seat belongs to the membership, not to the organisation, so it is
    /// taken off the membership the subscription was chosen from. An account
    /// holding two would otherwise wear the other one's seat under the
    /// subscription's name.
    func testTheSeatComesFromTheSubscriptionMembership() throws {
        let identity = try ClaudeWebAccountProfile.parse([
            "uuid": "c805523f",
            "memberships": [
                ["organization": individualOrganization, "seat_tier": "team_standard"],
                ["organization": subscriptionOrganization, "seat_tier": "team_tier_1"],
            ],
        ])

        XCTAssertEqual(identity.organization, "Master Soft Srl")
        XCTAssertEqual(identity.seat, "team_tier_1")
    }

    /// An account on no chat plan names no organisation, so there is no
    /// membership to take a seat off either.
    func testAnAccountWithNoSubscriptionNamesNoSeat() throws {
        let identity = try ClaudeWebAccountProfile.parse([
            "uuid": "c805523f",
            "memberships": [
                ["organization": individualOrganization, "seat_tier": "team_standard"]
            ],
        ])

        XCTAssertNil(identity.seat)
    }

    /// The measured divergence, and the one field that is dropped rather than
    /// mapped: claude.ai reports this account `default_raven` where the OAuth
    /// profile reports `default_claude_max_5x`. Two taxonomies, so carrying
    /// claude.ai's would decorate a plan with a tier from another vocabulary.
    func testTheRateLimitTierIsLeftUnansweredRatherThanTranslated() throws {
        let identity = try ClaudeWebAccountProfile.parse(payload())

        XCTAssertNil(identity.rateLimitTier)
    }

    /// An account holding no `chat` organisation is on no chat plan, so it
    /// answers none rather than borrowing the one membership it does have.
    /// Taking the first would badge a subscription `api_individual`, and
    /// membership order is the server's, so two polls of one account could
    /// even disagree.
    func testAnAccountWithNoSubscriptionOrganizationAnswersNoPlan() throws {
        let identity = try ClaudeWebAccountProfile.parse(
            payload(organizations: [individualOrganization]))

        XCTAssertEqual(identity.uuid, "c805523f-9d83-47ca-bb1a-4d6c94dd75bf")
        XCTAssertNil(identity.organization)
        XCTAssertNil(identity.organizationType)
    }

    /// The degenerate shapes, which is the whole of what a boundary parser is
    /// for: a reply that lost the key, one that lists nothing, and one whose
    /// membership is not the object it was last week. Each costs the plan and
    /// none of them costs the account.
    func testAPayloadWithNothingUsableUnderMembershipsStillIdentifies() throws {
        let shapes: [[String: Any]] = [
            ["uuid": "c805523f", "email_address": "someone@example.com"],
            ["uuid": "c805523f", "memberships": []],
            ["uuid": "c805523f", "memberships": ["not-an-object"]],
            ["uuid": "c805523f", "memberships": [["organization": "not-an-object"]]],
            ["uuid": "c805523f", "memberships": [["seat_tier": "team_tier_1"]]],
        ]

        for shape in shapes {
            let identity = try ClaudeWebAccountProfile.parse(shape)

            XCTAssertEqual(identity.uuid, "c805523f")
            XCTAssertNil(identity.organizationType)
        }
    }

    /// Without an id there is no key to file the session under, which is the
    /// one thing this cannot proceed without. Absent and present-but-not-a-
    /// string are the same answer: the vendor did not name an account.
    func testAPayloadNamingNoAccountThrows() {
        let shapes: [[String: Any]] = [
            [:],
            ["uuid": ""],
            ["uuid": 42],
            ["email_address": "someone@example.com"],
        ]

        for shape in shapes {
            XCTAssertThrowsError(try ClaudeWebAccountProfile.parse(shape)) {
                XCTAssertEqual(
                    $0 as? ClaudeAccountProfile.Failure,
                    ClaudeAccountProfile.Failure.malformedPayload)
            }
        }
    }
}
