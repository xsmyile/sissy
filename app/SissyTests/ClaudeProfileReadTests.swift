import XCTest

@testable import Sissy

/// What `ClaudeProfileSource.refresh` takes off the CLI's `oauthAccount` block.
final class ClaudeProfileReadTests: XCTestCase {
    /// What a source holds after reading `data` the way it ships: off a file.
    private func read(_ data: Data) throws -> ClaudeProfileSource.Attributed {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-profile-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let source = ClaudeProfileSource(url: url)
        source.refresh(userInitiated: true)
        return source.currentAttributed()
    }

    private func account(_ fields: [String: String]) throws -> ProviderAccount? {
        var block: [String: String] = [
            "emailAddress": "davide@example.com", "organizationType": "claude_max",
        ]
        block.merge(fields) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: ["oauthAccount": block])
        return try read(data).signals.account
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
        return try read(data).signals.planTier
    }

    /// The tier Claude Code files under the organisation's key, with the
    /// user's own left empty, still reaches the badge.
    func testTheOrganisationsTierAnswersWhereTheUsersIsEmpty() throws {
        XCTAssertEqual(
            try tier(["organizationRateLimitTier": "default_claude_max_20x"]), "max_20x")
    }

    /// Measured 2026-11-04 on 2.1.318: the rename reached this one key and left
    /// the plan and the tier as they were.
    func testThePlansOwnWordIsRead() throws {
        var block = ["organizationType": "claude_max"]
        block["planDisplayName"] = "Ultra"
        let data = try JSONSerialization.data(withJSONObject: ["oauthAccount": block])
        let signals = try read(data).signals
        XCTAssertEqual(signals.plan, "max")
        XCTAssertEqual(signals.planName, "Ultra")
    }

    func testAnAccountThatNamesNoWordHasNone() throws {
        let data = try JSONSerialization.data(
            withJSONObject: ["oauthAccount": ["organizationType": "claude_team"]])
        let signals = try read(data).signals
        XCTAssertEqual(signals.plan, "team")
        XCTAssertNil(signals.planName)
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
