import XCTest

@testable import Sissy

/// The `oauthAccount` block a switch moves along with the credential.
final class ClaudeCLIProfileTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sissy-cli-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private let radon = ClaudeAccountIdentity(
        uuid: "u-radon", email: "someone@example.com", name: "Someone",
        organization: "Radon", organizationType: "claude_team",
        rateLimitTier: "default_claude_max_5x", seat: "team_tier_1",
        organizationUUID: "org-radon")

    private let previousBlock: [String: Any] = [
        "accountUuid": "u-master", "emailAddress": "someone@example.org",
        "organizationUuid": "org-master", "organizationName": "Master",
        "organizationRole": "primary_owner", "billingType": "stripe_subscription",
        "ccOnboardingFlags": ["seen": true],
    ]

    func testTheBlockIsReplacedWithTheNewAccountAndNothingOfThePreviousOne() throws {
        let root: [String: Any] = ["oauthAccount": previousBlock, "numStartups": 12]

        let updated = ClaudeCLIProfile.adopting(radon, into: root)
        let block = try XCTUnwrap(updated["oauthAccount"] as? [String: String])

        XCTAssertEqual(
            block,
            [
                "accountUuid": "u-radon", "emailAddress": "someone@example.com",
                "organizationUuid": "org-radon", "organizationName": "Radon",
                "organizationType": "claude_team", "userRateLimitTier": "default_claude_max_5x",
                "seatTier": "team_tier_1",
            ])
        XCTAssertEqual(updated["numStartups"] as? Int, 12)
    }

    /// The CLI's own block for the account is richer than Sissy's, so a
    /// switch to the account it already names writes nothing.
    func testABlockAlreadyNamingTheAccountIsLeftAlone() {
        let root: [String: Any] = ["oauthAccount": ["accountUuid": "u-radon", "displayName": "S"]]

        XCTAssertTrue(ClaudeCLIProfile.names(radon, in: root))
        XCTAssertFalse(ClaudeCLIProfile.names(radon, in: ["oauthAccount": previousBlock]))
    }

    /// One account can hold two organisations, and a block naming the account
    /// under the other one is the wrong organisation all the same.
    func testABlockNamingTheAccountUnderAnotherOrganisationIsReplaced() {
        let root: [String: Any] = [
            "oauthAccount": ["accountUuid": "u-radon", "organizationUuid": "org-other"]
        ]

        XCTAssertFalse(ClaudeCLIProfile.names(radon, in: root))
    }

    func testAConfigWithNoBlockTakesOne() throws {
        let updated = ClaudeCLIProfile.adopting(radon, into: ["numStartups": 1])

        let block = try XCTUnwrap(updated["oauthAccount"] as? [String: String])
        XCTAssertEqual(block["accountUuid"], "u-radon")
    }

    /// An identity archived before the organisation's id was recorded leaves
    /// it out, which is what makes the CLI ask the profile endpoint for it.
    func testAnUnknownOrganisationIdIsLeftOutRatherThanCarriedOver() throws {
        let archived = ClaudeAccountIdentity(
            uuid: "u-radon", email: nil, organization: "Radon", organizationType: nil,
            rateLimitTier: nil)

        let updated = ClaudeCLIProfile.adopting(archived, into: ["oauthAccount": previousBlock])
        let block = try XCTUnwrap(updated["oauthAccount"] as? [String: String])

        XCTAssertEqual(block, ["accountUuid": "u-radon", "organizationName": "Radon"])
    }

    func testTheFileKeepsItsOtherKeysAndItsPermissions() throws {
        let url = tempDir.appendingPathComponent(".claude.json")
        try write(["oauthAccount": previousBlock, "projects": ["/a": ["x": 1]]], to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        try ClaudeCLIProfile.adopt(radon, at: url)

        let root = try read(url)
        XCTAssertEqual((root["oauthAccount"] as? [String: Any])?["accountUuid"] as? String, "u-radon")
        XCTAssertEqual(
            ((root["projects"] as? [String: Any])?["/a"] as? [String: Any])?["x"] as? Int, 1)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        XCTAssertEqual((mode as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".lock"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempDir.path), [".claude.json"])
    }

    /// A config kept elsewhere and linked into place is written where it
    /// lives, and the link stays a link.
    func testALinkedConfigIsWrittenThroughTheLink() throws {
        let real = tempDir.appendingPathComponent("dotfiles.json")
        let link = tempDir.appendingPathComponent(".claude.json")
        try write(["oauthAccount": previousBlock], to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        try ClaudeCLIProfile.adopt(radon, at: link)

        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        XCTAssertEqual(destination, real.path)
        XCTAssertEqual(
            (try read(real)["oauthAccount"] as? [String: Any])?["accountUuid"] as? String, "u-radon")
    }

    /// A lock the CLI lets go of while Sissy waits is taken and written under.
    func testALockReleasedWithinTheWaitIsTaken() throws {
        let url = tempDir.appendingPathComponent(".claude.json")
        try write(["oauthAccount": previousBlock], to: url)
        let lock = url.path + ".lock"
        try FileManager.default.createDirectory(atPath: lock, withIntermediateDirectories: false)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { rmdir(lock) }

        try ClaudeCLIProfile.adopt(radon, at: url)

        XCTAssertEqual(
            (try read(url)["oauthAccount"] as? [String: Any])?["accountUuid"] as? String, "u-radon")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock))
    }

    /// A write no longer wanted by the time it would land leaves the file and
    /// its directory exactly as they were.
    func testAWriteNoLongerWantedLeavesTheFileAlone() throws {
        let url = tempDir.appendingPathComponent(".claude.json")
        try write(["oauthAccount": previousBlock], to: url)
        let before = try Data(contentsOf: url)

        let wrote = try ClaudeCLIProfile.adopt(radon, at: url, while: { false })

        XCTAssertFalse(wrote)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempDir.path), [".claude.json"])
    }

    /// A lock the CLI holds is not broken: the write gives up and the file is
    /// left exactly as it was.
    func testALockTheCLIHoldsIsWaitedForAndNotBroken() throws {
        let url = tempDir.appendingPathComponent(".claude.json")
        try write(["oauthAccount": previousBlock], to: url)
        let before = try Data(contentsOf: url)
        try FileManager.default.createDirectory(
            atPath: url.path + ".lock", withIntermediateDirectories: false)

        XCTAssertThrowsError(try ClaudeCLIProfile.adopt(radon, at: url)) { error in
            XCTAssertEqual(error as? ClaudeCLIProfile.Failure, .locked)
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".lock"))
    }

    func testAFileAlreadyNamingTheAccountIsNotRewritten() throws {
        let url = tempDir.appendingPathComponent(".claude.json")
        try write(["oauthAccount": ["accountUuid": "u-radon", "displayName": "S"]], to: url)
        let before = try Data(contentsOf: url)

        try ClaudeCLIProfile.adopt(radon, at: url)

        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testAMissingFileIsNotCreated() throws {
        let url = tempDir.appendingPathComponent(".claude.json")

        try ClaudeCLIProfile.adopt(radon, at: url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAFileThatIsNotAnObjectIsRefusedAndKept() throws {
        let url = tempDir.appendingPathComponent(".claude.json")
        try Data("[1]".utf8).write(to: url)

        XCTAssertThrowsError(try ClaudeCLIProfile.adopt(radon, at: url)) { error in
            XCTAssertEqual(error as? ClaudeCLIProfile.Failure, .unreadable)
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("[1]".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".lock"))
    }

    private func write(_ root: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: root).write(to: url)
    }

    private func read(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}
