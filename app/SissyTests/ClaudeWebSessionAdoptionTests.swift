import XCTest

@testable import Sissy

/// What the pass does to the keychain, decided without one.
///
/// The pass itself is the code under test; only its two dependencies stand in.
/// The failure that matters is ending with no session at all, which costs the
/// user an import, and that has to be provable without the developer's own
/// login keychain taking part.
final class ClaudeWebSessionAdoptionTests: XCTestCase {
    private static let identity = ClaudeAccountIdentity(
        uuid: "c805523f", email: "someone@example.com", organization: "Master Soft Srl",
        organizationType: "claude_team", rateLimitTier: nil)

    /// A session that claude.ai will not identify stays exactly where it is.
    ///
    /// Offline, or a session that has ended. Dropping it to be tidy would cost
    /// the user an import for a condition that clears itself, and the legacy
    /// item is what makes the next launch try again.
    func testAnUnidentifiedSessionIsLeftWhereItIs() async {
        let vault = Vault([ClaudeWebSessionStore.legacyAccount: "sk-ant-sid-old"])

        let outcome = await ClaudeWebSessionAdoption.run(store: vault.store()) { _ in
            throw ClaudeAccountProfile.Failure.malformedPayload
        }

        XCTAssertEqual(outcome, .unidentified)
        XCTAssertEqual(vault.contents, [ClaudeWebSessionStore.legacyAccount: "sk-ant-sid-old"])
    }

    /// The ordinary case after this ships, and every launch after the first.
    func testAnInstallWithNoLegacySessionDoesNothing() async {
        let vault = Vault(["c805523f": "sk-ant-sid-keyed"])

        let outcome = await ClaudeWebSessionAdoption.run(store: vault.store()) { _ in Self.identity }

        XCTAssertEqual(outcome, .nothingToAdopt)
        XCTAssertEqual(vault.contents, ["c805523f": "sk-ant-sid-keyed"])
    }

    /// The move itself: one session, under the account it turned out to
    /// belong to, and the un-keyed item gone.
    func testAnIdentifiedSessionMovesUnderItsAccount() async {
        let vault = Vault([ClaudeWebSessionStore.legacyAccount: "sk-ant-sid-old"])

        let outcome = await ClaudeWebSessionAdoption.run(store: vault.store()) { _ in Self.identity }

        XCTAssertEqual(outcome, .adopted(uuid: "c805523f"))
        XCTAssertEqual(vault.contents, ["c805523f": "sk-ant-sid-old"])
    }

    /// The invariant the write order exists for: a pass cut short after the
    /// write and before the delete leaves two copies of one session, never
    /// none. The duplicate clears on the next pass, because the legacy item is
    /// still there to be adopted; a missing session would need the user.
    func testAnInterruptedMoveLeavesTwoCopiesRatherThanNone() async {
        let vault = Vault(
            [ClaudeWebSessionStore.legacyAccount: "sk-ant-sid-old"], failDelete: true)

        _ = await ClaudeWebSessionAdoption.run(store: vault.store()) { _ in Self.identity }

        XCTAssertEqual(vault.contents["c805523f"], "sk-ant-sid-old")
        XCTAssertEqual(vault.contents[ClaudeWebSessionStore.legacyAccount], "sk-ant-sid-old")
    }

    /// The keychain half, in memory. The pass itself is the code under test.
    private final class Vault: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: String]
        private let failDelete: Bool

        init(_ items: [String: String], failDelete: Bool = false) {
            self.items = items
            self.failDelete = failDelete
        }

        var contents: [String: String] { lock.withLock { items } }

        func store() -> ClaudeWebSessionAdoption.Store {
            ClaudeWebSessionAdoption.Store(
                read: { [self] account in lock.withLock { items[account] } },
                write: { [self] account, session in
                    lock.withLock { items[account] = session }
                },
                delete: { [self] account in
                    guard !failDelete else { throw ClaudeWebSessionStoreError.keychain(errSecAuthFailed) }
                    lock.withLock { items[account] = nil }
                })
        }
    }
}
