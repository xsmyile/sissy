import ServiceManagement
import XCTest

@testable import Sissy

/// The retirement gets one shot per install, so what it spends that shot on
/// matters more than what it does with it. These pin the two answers that are
/// not "done": a plist this bundle cannot resolve, and an unregister that
/// failed — both have to leave the flag alone so the next launch tries again.
@MainActor
final class LegacyAgentRetirementTests: XCTestCase {
    private final class Flag {
        var marked = false
    }

    private struct UnregisterFailed: Error {}

    func testARegisteredAgentIsRetiredAndTheShotIsSpent() {
        let flag = Flag()
        var unregistered: [String] = []

        let outcome = LegacyAgentRetirement.run(
            alreadyRan: false,
            agentStatus: { _ in .enabled },
            unregisterAgent: { unregistered.append($0) },
            loginItem: LoginItemController(service: .agent(plistName: Self.absentPlist)),
            markRan: { flag.marked = true }
        )

        XCTAssertEqual(outcome.retired, LegacyAgentRetirement.labels)
        XCTAssertEqual(unregistered, LegacyAgentRetirement.labels)
        XCTAssertTrue(outcome.conclusive)
        XCTAssertTrue(flag.marked)
    }

    func testAMachineThatNeverHadTheAgentSpendsTheShotWithoutDoingAnything() {
        let flag = Flag()

        let outcome = LegacyAgentRetirement.run(
            alreadyRan: false,
            agentStatus: { _ in .notRegistered },
            unregisterAgent: { _ in XCTFail("nothing to unregister") },
            loginItem: LoginItemController(service: .agent(plistName: Self.absentPlist)),
            markRan: { flag.marked = true }
        )

        XCTAssertTrue(outcome.retired.isEmpty)
        XCTAssertTrue(outcome.conclusive)
        XCTAssertTrue(flag.marked)
        XCTAssertFalse(outcome.claimedLoginItem, "nothing was retired, so nothing was taken over")
    }

    /// The bug this exists for: `SMAppService` answers `.notFound` when the
    /// plist is missing from the bundle, which is a packaging mistake rather
    /// than a clean machine. Spending the shot on it leaves an agent starting
    /// at login forever, and no launch that could fix it.
    func testAnUnresolvablePlistLeavesTheShotForNextTime() {
        let flag = Flag()

        let outcome = LegacyAgentRetirement.run(
            alreadyRan: false,
            agentStatus: { _ in .notFound },
            unregisterAgent: { _ in XCTFail("nothing resolvable to unregister") },
            loginItem: LoginItemController(service: .agent(plistName: Self.absentPlist)),
            markRan: { flag.marked = true }
        )

        XCTAssertFalse(outcome.conclusive)
        XCTAssertFalse(flag.marked, "an unresolvable plist must not spend the one shot")
    }

    func testAFailedUnregisterLeavesTheShotForNextTime() {
        let flag = Flag()

        let outcome = LegacyAgentRetirement.run(
            alreadyRan: false,
            agentStatus: { _ in .enabled },
            unregisterAgent: { _ in throw UnregisterFailed() },
            loginItem: LoginItemController(service: .agent(plistName: Self.absentPlist)),
            markRan: { flag.marked = true }
        )

        XCTAssertTrue(outcome.retired.isEmpty)
        XCTAssertFalse(outcome.conclusive)
        XCTAssertFalse(flag.marked)
    }

    func testAnAlreadyRetiredInstallLooksAtNothing() {
        let flag = Flag()

        let outcome = LegacyAgentRetirement.run(
            alreadyRan: true,
            agentStatus: { _ in
                XCTFail("should not look")
                return .notRegistered
            },
            unregisterAgent: { _ in XCTFail("should not unregister") },
            loginItem: LoginItemController(service: .agent(plistName: Self.absentPlist)),
            markRan: { flag.marked = true }
        )

        XCTAssertEqual(outcome, LegacyAgentRetirement.Outcome())
        XCTAssertFalse(flag.marked)
    }

    /// Pins the login item to a plist the bundle does not carry, so these
    /// never touch whatever is registered on the machine running them.
    private static let absentPlist = "com.radonforge.sissy.tests.absent.plist"
}
