import XCTest

@testable import Sissy

/// What an unlink reports when the keychain or the index will not do its
/// half, decided with both halves standing in.
final class AccountUnlinkTests: XCTestCase {
    private struct Refused: Error {}

    func testAnUnlinkThatRemovedBothHalvesSucceeds() async {
        let outcome = await AccountUnlink.run(
            "claude.ai session", removeCredential: {}, forgetName: {})

        XCTAssertNoThrow(try outcome.get())
    }

    /// A keychain that would not delete the credential leaves the account
    /// linked, and the Unlink that did nothing has to say so.
    func testACredentialTheKeychainKeptIsReported() async {
        let outcome = await AccountUnlink.run(
            "claude.ai session", removeCredential: { throw Refused() }, forgetName: {})

        XCTAssertEqual(outcome.failure, .credentialKept)
    }

    /// The name stays while the credential does: dropping it would leave a
    /// row for a secret that is still in the keychain with nothing to call it.
    func testACredentialTheKeychainKeptKeepsItsName() async {
        let forgot = LockedValue(false)

        _ = await AccountUnlink.run(
            "claude.ai session", removeCredential: { throw Refused() },
            forgetName: { forgot.store(true) })

        XCTAssertFalse(forgot.load())
    }

    func testANameTheIndexKeptIsReported() async {
        let outcome = await AccountUnlink.run(
            "claude.ai session", removeCredential: {}, forgetName: { throw Refused() })

        XCTAssertEqual(outcome.failure, .nameKept)
    }

    /// Each failure names its own remedy, for both vendors, so an Unlink that
    /// did nothing never reads as one that worked.
    func testEachUnlinkFailureIsWordedApart() {
        XCTAssertNotEqual(
            ClaudeAccountLinkCopy.unlinkFailure(.credentialKept),
            ClaudeAccountLinkCopy.unlinkFailure(.nameKept))
        XCTAssertNotEqual(
            CodexAccountLinkCopy.unlinkFailure(.credentialKept),
            CodexAccountLinkCopy.unlinkFailure(.nameKept))
    }

    /// A credential the keychain kept is reported only while its account is
    /// still listed: once it is gone some other way, "still linked" is false.
    func testAKeptCredentialStopsStandingOnceTheAccountIsGone() {
        let report = AccountUnlink.Report(account: "a1b2c3d4", failure: .credentialKept)

        XCTAssertFalse(report.stands(amongListed: []))
    }

    func testAKeptCredentialStandsWhileTheAccountIsListed() {
        let report = AccountUnlink.Report(account: "a1b2c3d4", failure: .credentialKept)

        XCTAssertTrue(report.stands(amongListed: ["a1b2c3d4"]))
    }

    /// A name the index kept describes an account that was unlinked, so an
    /// account listed again has been linked again and the report is stale.
    func testAKeptNameStopsStandingOnceTheAccountIsListedAgain() {
        let report = AccountUnlink.Report(account: "a1b2c3d4", failure: .nameKept)

        XCTAssertFalse(report.stands(amongListed: ["a1b2c3d4"]))
    }

    func testAKeptCredentialSaysTheAccountIsStillLinked() {
        let message = ClaudeAccountLinkCopy.unlinkFailure(.credentialKept)
        XCTAssertTrue(message.contains("still linked"), message)
        XCTAssertTrue(message.contains("keychain"), message)
    }
}

extension Result {
    fileprivate var failure: Failure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}
