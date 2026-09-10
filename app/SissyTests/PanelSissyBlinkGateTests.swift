import XCTest

@testable import Sissy

/// The panel Sissy's blink is gated on the same rules the status button's
/// animator applies, and this is where they are asserted — the view itself
/// only holds the clock and the frame index.
final class PanelSissyBlinkGateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_757_000_000)

    private func gate(
        motionEnabled: Bool = true,
        reduceMotion: Bool = false,
        isAsleep: Bool = false
    ) -> PanelSissyBlinkGate {
        PanelSissyBlinkGate(
            motionEnabled: motionEnabled,
            reduceMotion: reduceMotion,
            isAsleep: isAsleep
        )
    }

    func testAFrameBlinksSissyWhenSheHasBeenStillLongEnough() {
        XCTAssertTrue(gate().allows(at: now, lastBlinkAt: .distantPast))
    }

    func testTheMotionPreferenceOffBlocksTheBlink() {
        XCTAssertFalse(gate(motionEnabled: false).allows(at: now, lastBlinkAt: .distantPast))
    }

    func testReduceMotionBlocksTheBlink() {
        XCTAssertFalse(gate(reduceMotion: true).allows(at: now, lastBlinkAt: .distantPast))
    }

    /// A blink while the daemon is unreachable would report an arrival that
    /// did not happen.
    func testASleepingSissyDoesNotBlink() {
        XCTAssertFalse(gate(isAsleep: true).allows(at: now, lastBlinkAt: .distantPast))
    }

    func testASecondFrameInsideTheCooldownIsDropped() {
        let justBefore = now.addingTimeInterval(-SissyMenuBarMotion.dataBlinkCooldown + 0.1)

        XCTAssertFalse(gate().allows(at: now, lastBlinkAt: justBefore))
    }

    func testAFrameOnceTheCooldownHasElapsedBlinksAgain() {
        let cooledDown = now.addingTimeInterval(-SissyMenuBarMotion.dataBlinkCooldown)

        XCTAssertTrue(gate().allows(at: now, lastBlinkAt: cooledDown))
    }
}
