import LocalAuthentication
import XCTest

@testable import Sissy

/// The query is the whole feature: a read that carries these keys cannot put a
/// dialog on screen, and a read that has lost them silently can. Both halves
/// are asserted because either one alone leaves the door open — the context
/// covers the modern path, and the legacy keychain Claude Code writes into can
/// still raise Allow/Deny through it.
final class ClaudeCredentialsQueryTests: XCTestCase {
    func testASilentReadForbidsInteractionThroughTheAuthenticationContext() throws {
        let query = ClaudeCredentialsStore.makeQuery(allowingInteraction: false)

        let context = try XCTUnwrap(
            query[kSecUseAuthenticationContext as String] as? LAContext,
            "the silent read carries no authentication context"
        )
        XCTAssertTrue(context.interactionNotAllowed)
    }

    /// Resolved by name at runtime, so this is also the test that the symbol
    /// is still there: a rename or a removal in a future SDK would leave the
    /// query quietly interactive, which is the failure nobody would notice
    /// until a dialog appeared on someone's Mac at login.
    func testASilentReadAlsoFailsTheLegacyKeychainUI() throws {
        let query = ClaudeCredentialsStore.makeQuery(allowingInteraction: false)

        let key = try XCTUnwrap(
            resolve(ClaudeCredentialsStore.authenticationUIName),
            "kSecUseAuthenticationUI no longer resolves; the legacy keychain can still ask"
        )
        let fail = try XCTUnwrap(resolve(ClaudeCredentialsStore.authenticationUIFailName))
        XCTAssertEqual(query[key] as? String, fail)
    }

    /// The read a user action makes is the ordinary one. It has to be able to
    /// ask — that is the only moment Sissy is allowed to.
    func testAUserActionReadCarriesNeitherSuppressor() throws {
        let query = ClaudeCredentialsStore.makeQuery(allowingInteraction: true)

        XCTAssertNil(query[kSecUseAuthenticationContext as String])
        let key = try XCTUnwrap(resolve(ClaudeCredentialsStore.authenticationUIName))
        XCTAssertNil(query[key])
    }

    func testBothReadsAskForTheServiceClaudeCodeWritesUnder() {
        for interactive in [true, false] {
            let query = ClaudeCredentialsStore.makeQuery(allowingInteraction: interactive)
            XCTAssertEqual(
                query[kSecAttrService as String] as? String,
                ClaudeCredentialsStore.keychainService
            )
        }
    }

    /// The query's suppressors leave the legacy keychain's ACL panel alone, so
    /// this switch is the one that actually keeps a launch quiet. It is
    /// resolved by name, which makes its absence the same silent failure as a
    /// renamed constant — and it is deprecated, so the day it stops resolving
    /// will not be announced.
    func testTheLegacyKeychainInteractionSwitchStillResolves() {
        let name = ClaudeCredentialsStore.userInteractionName

        XCTAssertEqual(name, "SecKeychainSetUserInteractionAllowed")
        XCTAssertNotNil(dlsym(UnsafeMutableRawPointer(bitPattern: -2), name))
    }

    /// A suppressed read answers `errSecAuthFailed`, the same status a user
    /// clicking Deny produces. Reading it as a refusal would stop the probe on
    /// every launch, which is the failure `.interactionRequired` exists to
    /// prevent: nobody was shown anything, so nobody said no.
    func testASilentReadThatWouldHaveAskedIsNotARefusal() {
        let outcome = ClaudeCredentialsStore.classify(
            errSecAuthFailed, data: nil, allowingInteraction: false)

        guard case .interactionRequired = outcome else {
            return XCTFail("a read that was never allowed to ask reported \(outcome)")
        }
    }

    /// The other half of the same status: a user action did put the panel on
    /// screen, and this is the one path on which someone can actually refuse.
    func testAUserActionThatWasRefusedIsARefusal() {
        let outcome = ClaudeCredentialsStore.classify(
            errSecAuthFailed, data: nil, allowingInteraction: true)

        guard case .denied = outcome else {
            return XCTFail("a refused user action reported \(outcome)")
        }
    }

    func testAMissingItemIsAbsentWhicheverReadFoundIt() {
        for interactive in [true, false] {
            let outcome = ClaudeCredentialsStore.classify(
                errSecItemNotFound, data: nil, allowingInteraction: interactive)

            guard case .absent = outcome else {
                return XCTFail("a missing item reported \(outcome)")
            }
        }
    }

    private func resolve(_ name: String) -> String? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return symbol.assumingMemoryBound(to: CFString?.self).pointee as String?
    }

    /// The suppressor is process-wide and its restore is unconditional, so two
    /// readers overlapping would have the first one's restore re-open the
    /// panel for the second — a scheduled read putting Allow/Deny on screen,
    /// which is what the suppressors exist to prevent.
    ///
    /// Asserted on overlap rather than on the flag: the flag has no getter,
    /// and what has to be true is that no second reader is inside while one
    /// is. Each read holds long enough that an unlocked build overlaps on
    /// essentially every run.
    func testTwoSuppressedReadsNeverOverlap() {
        XCTAssertFalse(overlapWhileReading(iterations: 8) { _ in false })
    }

    /// And a read that is allowed to ask goes through the same gate: it
    /// suppresses nothing, but overlapping a silent read would leave that one
    /// running with the panel this caller deliberately left on.
    func testAnInteractiveReadIsSerialisedWithTheSilentOnes() {
        XCTAssertFalse(overlapWhileReading(iterations: 6) { $0.isMultiple(of: 2) })
    }

    /// A reader that cannot get in gives up rather than running unsuppressed,
    /// which would be the overlap this whole thing exists to prevent, on
    /// purpose.
    ///
    /// The wedged holder is what matters here: `SecItemCopyMatching` can park
    /// indefinitely where suppression did not take, and an unbounded lock
    /// would hand that one reader every other linked account's poll loop.
    func testAReaderThatCannotGetInGivesUpInsteadOfWaiting() {
        let held = expectation(description: "the lock was taken")
        let release = expectation(description: "the holder was told to let go")

        DispatchQueue.global().async {
            ClaudeCredentialsStore.suppressingInteraction(false, unavailable: ()) {
                held.fulfill()
                _ = XCTWaiter().wait(for: [release], timeout: 5)
            }
        }
        wait(for: [held], timeout: 5)

        let answer = ClaudeCredentialsStore.suppressingInteraction(
            false, unavailable: "gave up", timeout: 0.05
        ) { "read" }

        XCTAssertEqual(answer, "gave up", "a reader waited on a holder that was not letting go")
        release.fulfill()
    }

    /// And what it gives up with is the one status `classify` reads the same
    /// way for both callers: the item is there and this read could not have
    /// it. `errSecAuthFailed` would tell an interactive caller a person had
    /// clicked Deny.
    func testGivingUpReadsAsInteractionRequiredForBothCallers() {
        for allowingInteraction in [true, false] {
            let outcome = ClaudeCredentialsStore.classify(
                errSecInteractionNotAllowed, data: nil, allowingInteraction: allowingInteraction)
            guard case .interactionRequired = outcome else {
                return XCTFail("giving up read as something the caller would act on")
            }
        }
    }

    /// Occupancy of the suppressed section, counted under its own lock so the
    /// observation is not the thing being tested.
    private struct Occupancy: Sendable {
        var inside = 0
        var overlapped = false
    }

    /// Whether any two of `iterations` concurrent reads were ever inside at
    /// once. `interactive` decides what each one passes.
    private func overlapWhileReading(
        iterations: Int,
        interactive: @escaping @Sendable (Int) -> Bool
    ) -> Bool {
        let seen = LockedValue(Occupancy())
        let done = expectation(description: "every read finished")
        done.expectedFulfillmentCount = iterations

        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            ClaudeCredentialsStore.suppressingInteraction(
                interactive(index), unavailable: ()
            ) {
                seen.update {
                    $0.inside += 1
                    if $0.inside > 1 { $0.overlapped = true }
                }
                Thread.sleep(forTimeInterval: 0.01)
                seen.update { $0.inside -= 1 }
            }
            done.fulfill()
        }

        wait(for: [done], timeout: 5)
        return seen.load().overlapped
    }
}
