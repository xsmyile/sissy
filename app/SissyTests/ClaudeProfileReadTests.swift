import XCTest

@testable import Sissy

/// What `ClaudeProfileSource.read` takes off the CLI's `oauthAccount` block.
final class ClaudeProfileReadTests: XCTestCase {
    private func account(_ fields: [String: String]) throws -> ProviderAccount? {
        var block: [String: String] = [
            "emailAddress": "davide@example.com", "organizationType": "claude_max",
        ]
        block.merge(fields) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: ["oauthAccount": block])
        guard case .found(let profile) = ClaudeProfileSource.read(data) else { return nil }
        return profile.account
    }

    /// The full name leads, for the reason the OAuth profile's does.
    func testTheOwnersFullNameLeadsOverTheDisplayName() throws {
        let account = try account(["fullName": "Davide Rossi", "displayName": "Davide"])

        XCTAssertEqual(account?.name, "Davide Rossi")
    }

    func testTheDisplayNameAnswersWhereNoFullNameIsRecorded() throws {
        XCTAssertEqual(try account(["displayName": "Davide"])?.name, "Davide")
    }

    private func tier(_ fields: [String: String]) throws -> String? {
        var block: [String: String] = ["organizationType": "claude_max"]
        block.merge(fields) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: ["oauthAccount": block])
        guard case .found(let profile) = ClaudeProfileSource.read(data) else { return nil }
        return profile.tier
    }

    /// The tier Claude Code files under the organisation's key, with the
    /// user's own left empty, still reaches the badge.
    func testTheOrganisationsTierAnswersWhereTheUsersIsEmpty() throws {
        XCTAssertEqual(
            try tier(["organizationRateLimitTier": "default_claude_max_20x"]), "max_20x")
    }

    func testTheUsersOwnTierLeadsOverTheOrganisations() throws {
        XCTAssertEqual(
            try tier([
                "userRateLimitTier": "default_claude_max_5x",
                "organizationRateLimitTier": "default_claude_max_20x",
            ]), "max_5x")
    }

    func testAnAccountThatNamesNobodyHasNoName() throws {
        XCTAssertNil(try account([:])?.name)
    }
}
