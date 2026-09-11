import XCTest

@testable import Sissy

/// An unset toggle is the only one that asks the disk. An explicit one is
/// obeyed in both directions, which is the whole point of being able to set
/// it: off with the logs sitting right there, on before a CLI has written
/// anything.
final class ProviderActivationTests: XCTestCase {
    func testAnExplicitTrueIsOnWhateverIsOnDisk() {
        XCTAssertEqual(ProviderActivation.resolve(toggle: true, autoDetected: false), .on)
        XCTAssertEqual(ProviderActivation.resolve(toggle: true, autoDetected: true), .on)
    }

    func testAnExplicitFalseIsOffWhateverIsOnDisk() {
        XCTAssertEqual(ProviderActivation.resolve(toggle: false, autoDetected: true), .off)
        XCTAssertEqual(ProviderActivation.resolve(toggle: false, autoDetected: false), .off)
    }

    func testAnUnsetToggleAsksTheDisk() {
        XCTAssertEqual(ProviderActivation.resolve(toggle: nil, autoDetected: true), .autoDetected)
        XCTAssertEqual(ProviderActivation.resolve(toggle: nil, autoDetected: false), .autoNotFound)
    }

    /// A reader is built for exactly the two states that mean "metering", and
    /// the readiness list carries the other two so the tab can say why there
    /// is no row in the panel.
    func testOnlyTheTwoOnStatesMeter() {
        XCTAssertTrue(ProviderActivation.on.isMetering)
        XCTAssertTrue(ProviderActivation.autoDetected.isMetering)
        XCTAssertFalse(ProviderActivation.off.isMetering)
        XCTAssertFalse(ProviderActivation.autoNotFound.isMetering)
    }
}
