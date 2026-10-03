import XCTest

@testable import Sissy

/// The lid's warning is asked for once. These hold where the request lands,
/// that a confirmation is remembered across a relaunch, and that switching
/// off never asks.
@MainActor
final class SissyModelLidConfirmationTests: XCTestCase {
    private var supportDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SissyModelLidConfirmationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let directory = supportDirectory!
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    }

    func testTheFirstSwitchOnAsksOnTheAwakeTab() {
        let model = SissyModel(supportDirectory: supportDirectory)

        let asks = model.setKeepAwakeWithLidClosed(true)

        XCTAssertTrue(asks)
        XCTAssertTrue(model.lidConfirmationRequested)
        XCTAssertEqual(model.settingsTab, .awake)
    }

    func testAConfirmationIsRememberedAcrossARelaunch() {
        let model = SissyModel(supportDirectory: supportDirectory)
        model.setKeepAwakeWithLidClosed(true)

        model.confirmKeepAwakeWithLidClosed()

        XCTAssertFalse(model.lidConfirmationRequested)
        XCTAssertTrue(Preferences.load(from: supportDirectory).lidClosedConfirmed)
        let relaunched = SissyModel(supportDirectory: supportDirectory)
        XCTAssertFalse(relaunched.setKeepAwakeWithLidClosed(true))
        XCTAssertFalse(relaunched.lidConfirmationRequested)
    }

    func testSwitchingOffNeverAsks() {
        let model = SissyModel(supportDirectory: supportDirectory)

        XCTAssertFalse(model.setKeepAwakeWithLidClosed(false))
        XCTAssertFalse(model.lidConfirmationRequested)
    }
}
