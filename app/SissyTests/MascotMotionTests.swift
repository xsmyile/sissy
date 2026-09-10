import XCTest

@testable import Sissy

/// `step(at:)` is the timing both mascot surfaces play from — the status
/// button's animator and the panel header — so the frame it picks is asserted
/// here rather than through either of them.
final class MascotMotionTests: XCTestCase {
    func testABlinkStartsOnTheRestingSilhouette() {
        XCTAssertEqual(SissyMenuBarMotion.blink.step(at: .zero)?.index, 0)
    }

    /// Sampled mid-frame, not on a boundary, so the assertion does not turn on
    /// how `Int(seconds * 60)` truncates a value sitting exactly on one.
    func testFramesAdvanceAtSixtyPerSecond() {
        XCTAssertEqual(SissyMenuBarMotion.blink.step(at: .milliseconds(108))?.index, 6)
        XCTAssertEqual(SissyMenuBarMotion.blink.step(at: .milliseconds(208))?.index, 12)
    }

    func testAMotionThatHasRunOutReportsNoFrame() {
        let motion = SissyMenuBarMotion.blink
        let past = Duration.seconds(motion.duration)

        XCTAssertNil(motion.step(at: past))
    }

    /// A negative elapsed would index below the motion's own range.
    func testTimeBeforeTheStartReportsNoFrame() {
        XCTAssertNil(SissyMenuBarMotion.blink.step(at: .milliseconds(-1)))
    }

    func testTheClosingHalfLandsOnTheShutEyeHold() {
        let motion = SissyMenuBarMotion.eyeClose
        let lastMoment = Duration.seconds(motion.duration - 0.001)

        XCTAssertEqual(motion.step(at: .zero)?.index, 0)
        XCTAssertEqual(motion.step(at: lastMoment)?.index, motion.frameRange.upperBound - 1)
    }

    /// The hold is byte-identical frames, so playing the halves back to back
    /// must cross it once, not replay it.
    func testTheHalvesCrossTheShutEyeHoldWithoutReplayingIt() {
        let closing = SissyMenuBarMotion.eyeClose.frameRange
        let opening = SissyMenuBarMotion.eyeOpen.frameRange

        XCTAssertTrue(closing.upperBound <= opening.lowerBound, "the halves overlap")
        XCTAssertEqual(opening.upperBound, SissyMenuBarMotion.blink.frameRange.upperBound)
        XCTAssertEqual(closing.lowerBound, SissyMenuBarMotion.blink.frameRange.lowerBound)
        XCTAssertFalse(
            (closing.upperBound..<opening.lowerBound).isEmpty,
            "the halves meet with no hold between them"
        )
    }

    /// The clamp is what leaves the last frame something to land on: a
    /// deadline past the motion's end would sleep beyond its own playback.
    func testAFrameNeverOutlastsTheMotion() {
        for motion in [SissyMenuBarMotion.blink, .eyeClose, .eyeOpen] {
            for millisecond in stride(from: 0, to: Int(motion.duration * 1000), by: 1) {
                guard let step = motion.step(at: .milliseconds(millisecond)) else {
                    XCTFail("\(motion) reported no frame \(millisecond) ms in")
                    break
                }
                XCTAssertLessThanOrEqual(step.endsAt, motion.duration)
                XCTAssertTrue(motion.frameRange.contains(step.index))
            }
        }
    }

    func testEveryFrameOfTheSequenceIsNamed() {
        XCTAssertEqual(SissyMenuBarMotion.frameAssetNames.count, SissyMenuBarMotion.blink.frameRange.count)
        XCTAssertEqual(SissyMenuBarMotion.frameAssetNames.first, "SissyMotionBlink000")
        XCTAssertEqual(SissyMenuBarMotion.frameAssetNames.last, "SissyMotionBlink023")
    }
}
