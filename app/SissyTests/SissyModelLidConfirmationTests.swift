import XCTest

@testable import Sissy

/// The lid's warning is asked for once. These hold where the request lands,
/// that a confirmation on file is not asked again while one the engine did
/// not take is, and that switching off never asks.
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

    /// A confirmation already on file is not asked for again, which is what
    /// lets the cup's menu switch the lid directly after the first time.
    func testAConfirmationOnFileIsNotAskedAgain() {
        Preferences(lidClosedConfirmed: true).save(to: supportDirectory)
        let model = SissyModel(supportDirectory: supportDirectory)

        XCTAssertFalse(model.setKeepAwakeWithLidClosed(true))
        XCTAssertFalse(model.lidConfirmationRequested)
    }

    /// A confirmation the engine could not act on, here because metering has
    /// not started, is not spent: the next switch-on asks again.
    func testAConfirmationTheEngineDidNotTakeIsAskedAgain() {
        let model = SissyModel(supportDirectory: supportDirectory)
        model.setKeepAwakeWithLidClosed(true)

        model.confirmKeepAwakeWithLidClosed()

        XCTAssertFalse(model.lidConfirmationRequested)
        XCTAssertFalse(Preferences.load(from: supportDirectory).lidClosedConfirmed)
        XCTAssertTrue(model.setKeepAwakeWithLidClosed(true))
    }

    func testSwitchingOffNeverAsks() {
        let model = SissyModel(supportDirectory: supportDirectory)

        XCTAssertFalse(model.setKeepAwakeWithLidClosed(false))
        XCTAssertFalse(model.lidConfirmationRequested)
    }
}
