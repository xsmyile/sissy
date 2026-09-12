import AppKit
import XCTest

@testable import Sissy

/// `step(at:)` is the timing both Sissy surfaces play from — the status
/// button's animator and the panel header — so the frame it picks is asserted
/// here rather than through either of them.
final class SissyMotionTests: XCTestCase {
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

    /// Every frame the blink draws is a write to `button.image`, and AppKit
    /// answers each one by re-capturing the status item into a bitmap. The
    /// hold is four byte-identical frames, so drawing it once is four of those
    /// captures Sissy does not pay for and nobody could have seen.
    func testTheBlinkDrawsTheShutEyeHoldOnce() {
        let motion = SissyMenuBarMotion.blink
        let drawn = stride(from: 0, to: Int(motion.duration * 1000), by: 1)
            .compactMap { motion.step(at: .milliseconds($0))?.index }

        XCTAssertEqual(Set(drawn).intersection(6...9), [6])
        XCTAssertEqual(Set(drawn).count, 20, "the blink draws a frame it did not draw before")
    }

    /// Collapsing the hold must not shorten the blink: the frame that stands
    /// in for it is drawn for the whole of the time all four used to fill.
    func testTheHoldKeepsTheTimeItsFramesFilled() {
        let step = SissyMenuBarMotion.blink.step(at: .milliseconds(108))

        XCTAssertEqual(step?.index, 6)
        XCTAssertEqual(step?.endsAt ?? 0, 10 / SissyMenuBarMotion.framesPerSecond, accuracy: 0.0001)
    }

    /// Neither half may inherit the blink's collapse: each begins or ends
    /// inside the hold, and a half that skipped to its far edge would jump.
    func testTheHalvesStillStartAndStopOnTheirOwnFrame() {
        let closing = SissyMenuBarMotion.eyeClose
        let opening = SissyMenuBarMotion.eyeOpen

        XCTAssertEqual(closing.step(at: .milliseconds(108))?.index, 6)
        XCTAssertEqual(
            closing.step(at: .milliseconds(108))?.endsAt ?? 0,
            7 / SissyMenuBarMotion.framesPerSecond,
            accuracy: 0.0001
        )
        XCTAssertEqual(opening.step(at: .zero)?.index, 9)
        XCTAssertEqual(
            opening.step(at: .zero)?.endsAt ?? 0,
            1 / SissyMenuBarMotion.framesPerSecond,
            accuracy: 0.0001
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

    /// `PanelSissy` leans on this: its `.task(id:)` is only safe from being
    /// restarted mid-gesture because a second blink cannot come due before the
    /// first has finished.
    func testTheCooldownOutlastsTheBlinkItPaces() {
        XCTAssertGreaterThan(
            SissyMenuBarMotion.dataBlinkCooldown,
            SissyMenuBarMotion.blink.duration
        )
    }

    /// `PanelSissy` withholds the blink when a frame will not resolve, so
    /// this is the predicate that decides whether the panel animates at all.
    func testEveryFrameNameResolvesFromTheCatalogue() {
        let missing = SissyMenuBarMotion.frameAssetNames.filter { NSImage(named: $0) == nil }

        XCTAssertEqual(missing, [], "frames absent from the asset catalogue")
    }

    func testEveryFrameOfTheSequenceIsNamed() {
        XCTAssertEqual(SissyMenuBarMotion.frameAssetNames.count, SissyMenuBarMotion.blink.frameRange.count)
        XCTAssertEqual(SissyMenuBarMotion.frameAssetNames.first, "SissyMotionBlink000")
        XCTAssertEqual(SissyMenuBarMotion.frameAssetNames.last, "SissyMotionBlink023")
    }
}
