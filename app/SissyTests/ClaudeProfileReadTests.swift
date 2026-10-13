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

    func testAnAccountThatNamesNobodyHasNoName() throws {
        XCTAssertNil(try account([:])?.name)
    }
}
