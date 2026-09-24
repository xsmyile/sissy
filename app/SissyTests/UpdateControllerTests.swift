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

    func testAFoundUpdateIsNamedUnderTheButton() {
        XCTAssertEqual(
            UpdateController.statusLine(.available("0.3.1"), lastCheck: Date()),
            "Version 0.3.1 is available")
    }

    func testAFailedCheckSaysSoRatherThanWhenItRan() {
        XCTAssertEqual(
            UpdateController.statusLine(.failed, lastCheck: Date()), "Could not check for updates")
    }

    func testUpToDateCarriesWhenItWasChecked() {
        let line = UpdateController.statusLine(.upToDate, lastCheck: Date())
        XCTAssertTrue(line?.hasPrefix("Up to date · checked ") == true, line ?? "nil")
    }

    func testACopyThatNeverCheckedSaysNothing() {
        XCTAssertNil(UpdateController.statusLine(.idle, lastCheck: nil))
    }

    func testAProbeThatFoundAVersionOffersIt() {
        XCTAssertEqual(
            UpdateController.status(after: .found("0.3.1"), from: .checking), .available("0.3.1"))
    }

    func testAProbeThatReadAFeedWithNothingNewerIsUpToDate() {
        XCTAssertEqual(UpdateController.status(after: .notFound, from: .checking), .upToDate)
    }

    func testACycleThatEndsWhileStillCheckingWithAnErrorFailed() {
        XCTAssertEqual(
            UpdateController.status(after: .finished(failed: true), from: .checking), .failed)
    }

    func testACycleThatEndsWithoutAnErrorAndNoAnswerStopsTheSpinner() {
        XCTAssertEqual(
            UpdateController.status(after: .finished(failed: false), from: .checking), .idle)
    }

    /// Sparkle reports the finding before the cycle ends, and the end must
    /// not overwrite it: a found update that aborts the probe carries an error.
    func testTheEndOfACycleKeepsWhatItFound() {
        XCTAssertEqual(
            UpdateController.status(after: .finished(failed: true), from: .available("0.3.1")),
            .available("0.3.1"))
        XCTAssertEqual(
            UpdateController.status(after: .finished(failed: true), from: .upToDate), .upToDate)
    }

    func testASkippedVersionIsNoLongerOffered() {
        XCTAssertEqual(UpdateController.status(after: .skipped, from: .available("0.3.1")), .idle)
    }

    func testBundleDeclaresAFeedAndKey() {
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertFalse((info["SUPublicEDKey"] as? String ?? "").isEmpty)
        XCTAssertNotNil(UpdateController(isDevBuild: true).feedHost)
    }
}
