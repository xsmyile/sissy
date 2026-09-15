import XCTest

@testable import Sissy

/// Which keychain item one config home's credential lives in.
///
/// The rule is Claude Code's, not Sissy's, and it is the whole of switching an
/// account: address the wrong item and the switch either does nothing or signs
/// the user into someone else. Verified 2026-09-15 against the two homes on
/// one Mac, where the items the CLI had written were named exactly this.
final class ClaudeAccountActivationTests: XCTestCase {
    func testAHomeIsAddressedByTheFirstEightHexOfItsPathDigest() {
        let service = ClaudeAccountActivation.scopedService(for: "/Users/davide/.claude-mastersoft")

        XCTAssertEqual(service, "Claude Code-credentials-a8264a74")
    }

    func testTheDefaultHomesOwnPathHashesTheSameWay() {
        XCTAssertEqual(
            ClaudeAccountActivation.scopedService(for: "/Users/davide/.claude"),
            "Claude Code-credentials-8a380954")
    }

    /// The CLI reads the unsuffixed item when it is started with no
    /// `CLAUDE_CONFIG_DIR`, so the default home is that item rather than the
    /// hash of its path — which is also what makes a switch visible to a bare
    /// `claude` in any terminal.
    func testTheDefaultHomeIsTheUnscopedItem() {
        XCTAssertEqual(
            ClaudeAccountActivation.service(for: AccountDefaults.claudeHome),
            ClaudeAccountActivation.activeService)
    }

    func testANamedHomeIsScoped() {
        let home = URL(fileURLWithPath: "/tmp/sissy-tests/.claude-work")

        XCTAssertEqual(
            ClaudeAccountActivation.service(for: home),
            ClaudeAccountActivation.scopedService(for: "/tmp/sissy-tests/.claude-work"))
    }

    /// Claude Code 2.1+ refuses a login name outside `[a-zA-Z0-9._-]` and
    /// files the item under a fixed name instead, so addressing it by `$USER`
    /// alone would miss it on exactly the machines that have SSO logins.
    func testALoginNameTheCLIWillNotAcceptFallsBackToItsOwn() {
        XCTAssertEqual(
            ClaudeAccountActivation.keychainAccount(environment: ["USER": "first@example.com"]),
            "claude-code-user")
    }

    func testAnOrdinaryLoginNameIsUsedAsIs() {
        XCTAssertEqual(
            ClaudeAccountActivation.keychainAccount(environment: ["USER": "davide"]), "davide")
    }
}
