import XCTest

@testable import Sissy

@MainActor
final class UpdateControllerTests: XCTestCase {
    func testDevelopmentBuildNeverStartsTheUpdater() {
        let updates = UpdateController(isDevBuild: true)
        updates.start()
        XCTAssertFalse(updates.isRunning)
    }

    func testMenuOffersACheckWhenNothingIsPending() {
        XCTAssertEqual(UpdateController.menuTitle(pendingVersion: nil), "Check for Updates…")
    }

    func testMenuNamesThePendingVersion() {
        XCTAssertEqual(UpdateController.menuTitle(pendingVersion: "0.3.1"), "Update to 0.3.1…")
    }

    func testBundleDeclaresAFeedAndKey() {
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertFalse((info["SUPublicEDKey"] as? String ?? "").isEmpty)
        XCTAssertNotNil(UpdateController(isDevBuild: true).feedHost)
    }
}
