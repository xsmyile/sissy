import XCTest

@testable import Sissy

/// The host's two decisions about the agent hooks, taken out of the pass so
/// they can be asked without either CLI's configuration on disk.
final class AgentHookLaunchPassTests: XCTestCase {
    /// A run on defaults because `server.json` would not parse has no record
    /// of the switch, so it must not read an entry it finds as one to remove.
    func testAnUnreadableConfigSkipsThePass() {
        XCTAssertEqual(
            AgentHookLaunchPass.decide(enabled: false, removalPending: false, configIsWritable: false),
            .skip)
    }

    func testASwitchThatIsOnIsReaffirmed() {
        XCTAssertEqual(
            AgentHookLaunchPass.decide(enabled: true, removalPending: false, configIsWritable: true),
            .apply)
    }

    func testAPendingRemovalIsRetried() {
        XCTAssertEqual(
            AgentHookLaunchPass.decide(enabled: false, removalPending: true, configIsWritable: true),
            .apply)
    }

    func testASwitchThatIsOffOnlyLooks() {
        XCTAssertEqual(
            AgentHookLaunchPass.decide(enabled: false, removalPending: false, configIsWritable: true),
            .lookFirst)
    }

    func testALookThatFindsNoEntryDoesNotProceed() {
        XCTAssertFalse(AgentHookLaunchPass.lookFirst.proceeds(holdsOwnEntry: false))
    }

    func testALookThatFindsAnEntryProceeds() {
        XCTAssertTrue(AgentHookLaunchPass.lookFirst.proceeds(holdsOwnEntry: true))
    }

    func testAnEntrySurvivingAReportedRemovalKeepsItOwed() {
        XCTAssertTrue(
            AgentHookInstaller.removalOwed(enabled: false, refused: [], entrySurvives: true))
    }

    func testARefusedTargetKeepsTheRemovalOwed() {
        XCTAssertTrue(
            AgentHookInstaller.removalOwed(
                enabled: false, refused: ["Codex"], entrySurvives: false))
    }

    func testAClearRemovalIsNoLongerOwed() {
        XCTAssertFalse(
            AgentHookInstaller.removalOwed(enabled: false, refused: [], entrySurvives: false))
    }

    func testAnInstallOwesNoRemoval() {
        XCTAssertFalse(
            AgentHookInstaller.removalOwed(enabled: true, refused: ["Codex"], entrySurvives: true))
    }
}
