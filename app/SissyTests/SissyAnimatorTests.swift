import AppKit
import XCTest

@testable import Sissy

@MainActor
final class SissyAnimatorTests: XCTestCase {
    private let iconSize: CGFloat = 17

    private func makeAnimator(
        _ button: NSButton,
        reduceMotion: Bool = false
    ) throws -> SissyMenuBarAnimator {
        try SissyMenuBarAnimator(button: button, iconSize: iconSize, reduceMotion: { reduceMotion })
    }

    /// Hands the main actor over until the gesture has drawn something.
    ///
    /// `blink` and `setPose` only enqueue a playback task, so anything asserted
    /// straight after them is asserted against the image the animator has not
    /// left yet — which is how an assertion about playback passes without any
    /// playback happening.
    private func waitForFirstFrame(
        on button: NSButton,
        leaving resting: NSImage?,
        line: UInt = #line
    ) async {
        for _ in 0..<Self.yieldBudget where button.image === resting {
            await Task.yield()
        }
        XCTAssertNotIdentical(button.image, resting, "the gesture drew no frame", line: line)
    }

    /// Waits for a gesture to end by itself. A blink is 380 ms of real time,
    /// so this yields rather than sleeps, and fails on the deadline instead of
    /// hanging the suite if playback never finishes.
    private func waitUntilIdle(_ animator: SissyMenuBarAnimator, line: UInt = #line) async {
        let deadline = ContinuousClock.now + Self.playbackDeadline
        while animator.isPlaying, ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertFalse(animator.isPlaying, "the gesture never finished", line: line)
    }

    private static let yieldBudget = 10_000
    private static let playbackDeadline: Duration = .seconds(3)

    /// The frames are addressed by name, so nothing but loading them catches a
    /// catalogue that was regenerated with a different set.
    func testEveryFrameAndBothRestingPosesLoadFromTheCatalogue() throws {
        let button = NSButton()
        let animator = try makeAnimator(button)

        XCTAssertFalse(animator.isPlaying)
        XCTAssertTrue(animator.blink())
        animator.setPose(.asleep, animated: false)
        animator.setPose(.awake, animated: false)
    }

    func testTheRestingImageIsInstalledAtTheRequestedSize() throws {
        let button = NSButton()
        _ = try makeAnimator(button)

        XCTAssertEqual(button.image?.size, NSSize(width: iconSize, height: iconSize))
        XCTAssertEqual(button.image?.isTemplate, true)
    }

    func testStopRestoresTheExactRestingImage() async throws {
        let button = NSButton()
        let animator = try makeAnimator(button)
        let resting = button.image

        XCTAssertTrue(animator.blink())
        await waitForFirstFrame(on: button, leaving: resting)

        animator.stop()

        XCTAssertFalse(animator.isPlaying)
        XCTAssertIdentical(button.image, resting)
    }

    func testABlinkFinishesOnItsOwnAndLeavesTheAnimatorFree() async throws {
        let button = NSButton()
        let animator = try makeAnimator(button)
        let resting = button.image

        XCTAssertTrue(animator.blink())
        await waitForFirstFrame(on: button, leaving: resting)
        await waitUntilIdle(animator)

        XCTAssertIdentical(button.image, resting)
        XCTAssertTrue(animator.blink(), "a finished gesture left the animator busy")
        animator.stop()
    }

    func testABlinkRequestedDuringPlaybackIsDropped() async throws {
        let button = NSButton()
        let animator = try makeAnimator(button)
        let resting = button.image

        XCTAssertTrue(animator.blink())
        await waitForFirstFrame(on: button, leaving: resting)

        XCTAssertFalse(animator.blink())
    }

    func testTheClosingHalfLandsOnTheShutEyeAndRefusesBlinks() async throws {
        let button = NSButton()
        let animator = try makeAnimator(button)
        let awake = button.image

        animator.setPose(.asleep)
        await waitForFirstFrame(on: button, leaving: awake)
        await waitUntilIdle(animator)
        let afterClosing = button.image

        XCTAssertFalse(animator.blink(), "a sleeping Sissy blinked")
        // Identity against the same animator's snapped pose: an animated
        // transition that ended on a frame instead of the pose would differ.
        animator.setPose(.awake, animated: false)
        animator.setPose(.asleep, animated: false)
        XCTAssertIdentical(button.image, afterClosing)
    }

    func testWakingUpPlaysTheOpeningHalfAndRestsAwake() async throws {
        let button = NSButton()
        let animator = try makeAnimator(button)
        let awake = button.image
        animator.setPose(.asleep, animated: false)
        let asleep = button.image

        animator.setPose(.awake)
        await waitForFirstFrame(on: button, leaving: asleep)
        await waitUntilIdle(animator)

        XCTAssertIdentical(button.image, awake)
        XCTAssertTrue(animator.blink())
        animator.stop()
    }

    /// The transition must not paint where it is going before it gets there:
    /// the eye would flash shut, then close.
    func testTheClosingHalfDoesNotStartFromTheShutEye() async throws {
        let button = NSButton()
        let animator = try makeAnimator(button)
        let awake = button.image
        animator.setPose(.asleep, animated: false)
        let asleep = button.image
        animator.setPose(.awake, animated: false)

        animator.setPose(.asleep)
        await waitForFirstFrame(on: button, leaving: awake)

        XCTAssertNotIdentical(button.image, asleep, "the eye flashed shut before closing")
    }

    func testAPoseChangeInterruptsARunningBlink() async throws {
        let button = NSButton()
        let animator = try makeAnimator(button)
        let awake = button.image

        XCTAssertTrue(animator.blink())
        await waitForFirstFrame(on: button, leaving: awake)
        animator.setPose(.asleep)
        await waitUntilIdle(animator)

        XCTAssertEqual(animator.pose, .asleep)
        XCTAssertNotIdentical(button.image, awake)
    }

    func testReduceMotionBlocksTheBlinkAndSnapsThePose() throws {
        let button = NSButton()
        let animator = try makeAnimator(button, reduceMotion: true)
        let awake = button.image

        XCTAssertFalse(animator.blink())

        animator.setPose(.asleep)

        XCTAssertFalse(animator.isPlaying)
        XCTAssertNotIdentical(button.image, awake)
    }

    func testAnOpenMenuBlocksTheBlinkAndSnapsThePose() throws {
        let button = NSButton()
        let animator = try makeAnimator(button)
        animator.canAnimate = { false }
        let awake = button.image

        XCTAssertFalse(animator.blink())

        animator.setPose(.asleep)

        XCTAssertFalse(animator.isPlaying)
        XCTAssertNotIdentical(button.image, awake)
    }
}
