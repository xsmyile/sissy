import AppKit
import XCTest

@testable import Sissy

@MainActor
final class MascotAnimatorTests: XCTestCase {
    private let iconSize: CGFloat = 17

    private func makeAnimator(
        _ button: NSButton,
        reduceMotion: Bool = false
    ) throws -> SissyMenuBarAnimator {
        try SissyMenuBarAnimator(button: button, iconSize: iconSize, reduceMotion: { reduceMotion })
    }

    /// The frames are addressed by name, so nothing but loading them catches a
    /// catalogue that was regenerated with a different set.
    func testEveryFrameOfEveryGestureLoadsFromTheCatalogue() throws {
        let button = NSButton()
        let animator = try makeAnimator(button)
        XCTAssertFalse(animator.isPlaying)
        for motion in SissyMenuBarMotion.allCases {
            XCTAssertTrue(animator.play(motion), "\(motion) refused to start")
            animator.stop()
        }
    }

    func testTheRestingImageIsInstalledAtTheRequestedSize() throws {
        let button = NSButton()
        _ = try makeAnimator(button)
        XCTAssertEqual(button.image?.size, NSSize(width: iconSize, height: iconSize))
        XCTAssertEqual(button.image?.isTemplate, true)
    }

    func testStopRestoresTheExactRestingImage() throws {
        let button = NSButton()
        let animator = try makeAnimator(button)
        let idle = button.image

        XCTAssertTrue(animator.play(.blink))
        animator.stop()

        XCTAssertFalse(animator.isPlaying)
        XCTAssertIdentical(button.image, idle)
    }

    func testAGestureRequestedDuringPlaybackIsDropped() throws {
        let button = NSButton()
        let animator = try makeAnimator(button)

        XCTAssertTrue(animator.play(.blink))
        XCTAssertFalse(animator.play(.earTwitch))
        XCTAssertFalse(animator.play(.blink))
    }

    func testReduceMotionBlocksEveryGesture() throws {
        let button = NSButton()
        let animator = try makeAnimator(button, reduceMotion: true)

        for motion in SissyMenuBarMotion.allCases {
            XCTAssertFalse(animator.play(motion))
        }
        XCTAssertFalse(animator.isPlaying)
    }

    func testABlockedSurfaceStopsGesturesFromStarting() throws {
        let button = NSButton()
        let animator = try makeAnimator(button)
        animator.canAnimate = { false }

        XCTAssertFalse(animator.play(.blink))
        XCTAssertFalse(animator.isPlaying)
    }

    func testTheOccasionalSchedulerReportsAndClearsItself() throws {
        let button = NSButton()
        let animator = try makeAnimator(button)
        XCTAssertFalse(animator.isSchedulingOccasionalAnimations)

        animator.startOccasionalAnimations()
        XCTAssertTrue(animator.isSchedulingOccasionalAnimations)

        animator.stopOccasionalAnimations()
        XCTAssertFalse(animator.isSchedulingOccasionalAnimations)
    }
}
