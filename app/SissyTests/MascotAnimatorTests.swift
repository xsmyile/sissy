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

    /// Hands the main actor over until the gesture has drawn something.
    ///
    /// `play` only enqueues its playback task, so anything asserted straight
    /// after it is asserted against the resting image the animator has not
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

    func testStopRestoresTheExactRestingImage() async throws {
        let button = NSButton()
        let animator = try makeAnimator(button)
        let resting = button.image

        XCTAssertTrue(animator.play(.blink))
        await waitForFirstFrame(on: button, leaving: resting)

        animator.stop()

        XCTAssertFalse(animator.isPlaying)
        XCTAssertIdentical(button.image, resting)
    }

    func testAGestureFinishesOnItsOwnAndLeavesTheAnimatorFree() async throws {
        let button = NSButton()
        let animator = try makeAnimator(button)
        let resting = button.image

        XCTAssertTrue(animator.play(.blink))
        await waitForFirstFrame(on: button, leaving: resting)
        await waitUntilIdle(animator)

        XCTAssertIdentical(button.image, resting)
        XCTAssertTrue(animator.play(.earTwitch), "a finished gesture left the animator busy")
        animator.stop()
    }

    func testAGestureRequestedDuringPlaybackIsDropped() async throws {
        let button = NSButton()
        let animator = try makeAnimator(button)
        let resting = button.image

        XCTAssertTrue(animator.play(.blink))
        await waitForFirstFrame(on: button, leaving: resting)

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

    func testSleepingSwapsTheRestingImageAndRefusesGestures() throws {
        let button = NSButton()
        let animator = try makeAnimator(button)
        let awake = button.image

        animator.setPose(.asleep)
        XCTAssertNotIdentical(button.image, awake)
        for motion in SissyMenuBarMotion.allCases {
            XCTAssertFalse(animator.play(motion), "\(motion) played while asleep")
        }

        animator.setPose(.awake)
        XCTAssertIdentical(button.image, awake)
        XCTAssertTrue(animator.play(.blink))
    }

    func testFallingAsleepInterruptsARunningGesture() async throws {
        let button = NSButton()
        let animator = try makeAnimator(button)
        let awake = button.image

        XCTAssertTrue(animator.play(.blink))
        await waitForFirstFrame(on: button, leaving: awake)

        animator.setPose(.asleep)

        XCTAssertFalse(animator.isPlaying)
        XCTAssertNotIdentical(button.image, awake)
    }

    func testTheOccasionalSchedulerReportsAndClearsItself() throws {
        let button = NSButton()
        let animator = try makeAnimator(button)
        XCTAssertFalse(animator.isSchedulingOccasionalAnimations)

        animator.startOccasionalAnimations(.earTwitch)
        XCTAssertTrue(animator.isSchedulingOccasionalAnimations)

        animator.stopOccasionalAnimations()
        XCTAssertFalse(animator.isSchedulingOccasionalAnimations)
    }
}
