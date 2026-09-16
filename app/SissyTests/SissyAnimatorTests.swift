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

    private func eyeOverlay(on button: NSButton, line: UInt = #line) throws -> SissyEyeOverlay {
        try XCTUnwrap(
            button.subviews.compactMap { $0 as? SissyEyeOverlay }.first,
            "the animator installed no eye overlay",
            line: line
        )
    }

    /// The silhouette stays the template image in both states: that is what
    /// macOS applies the appearance, the menu highlight and full-strength ink
    /// to, and compositing the eye into it costs the body two fifths of that
    /// ink to the menu bar's vibrancy.
    func testTheSilhouetteStaysATemplateImageWhicheverWayTheEyeIs() throws {
        let button = NSButton()
        let animator = try makeAnimator(button)

        animator.setArtwork(.lit)
        XCTAssertEqual(button.image?.isTemplate, true)

        animator.setArtwork(.template)
        XCTAssertEqual(button.image?.isTemplate, true)
    }

    func testNothingHeldLeavesTheEyeUnlit() throws {
        let button = NSButton()
        let animator = try makeAnimator(button)

        XCTAssertEqual(animator.artwork, .template)
        XCTAssertTrue(try eyeOverlay(on: button).isHidden)
    }

    func testAHoldLightsTheEyeOverTheSamePose() throws {
        let button = NSButton()
        let animator = try makeAnimator(button)

        animator.setArtwork(.lit)

        let overlay = try eyeOverlay(on: button)
        XCTAssertEqual(animator.artwork, .lit)
        XCTAssertFalse(overlay.isHidden)
        XCTAssertEqual(overlay.image?.size, NSSize(width: iconSize, height: iconSize))
        XCTAssertEqual(overlay.contentTintColor, SissyArtwork.holdTint)
    }

    /// The blue is laid over the body, so a body that kept its own eye ink
    /// would show through the blue's antialiased edge as a fringe.
    func testALitEyeSitsOnTheEyelessSilhouette() throws {
        let button = NSButton()
        let animator = try makeAnimator(button)
        let whole = button.image

        animator.setArtwork(.lit)
        let eyeless = button.image

        XCTAssertNotIdentical(eyeless, whole)
        XCTAssertEqual(eyeless?.size, NSSize(width: iconSize, height: iconSize))

        animator.setArtwork(.template)
        XCTAssertIdentical(button.image, whole)
    }

    /// The overlay is the one view sitting on the status button, so a click
    /// that landed on it instead of the button would lose the panel.
    func testTheEyeOverlayNeverTakesAClick() throws {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
        let animator = try makeAnimator(button)
        let overlay = try eyeOverlay(on: button)

        XCTAssertNil(overlay.hitTest(NSPoint(x: overlay.bounds.midX, y: overlay.bounds.midY)))
        withExtendedLifetime(animator) {}
    }

    /// The overlay is a subview of a button the animator only borrows, so an
    /// animator that let go of it would leave a second one behind for its
    /// replacement to draw over.
    func testTheEyeOverlayLeavesWithItsAnimator() throws {
        let button = NSButton()
        try autoreleasepool {
            let animator = try makeAnimator(button)
            XCTAssertNotNil(try eyeOverlay(on: button))
            withExtendedLifetime(animator) {}
        }

        XCTAssertTrue(button.subviews.compactMap { $0 as? SissyEyeOverlay }.isEmpty)
    }

    /// Both poses and all 24 frames need both halves of the split, and the one
    /// thing that catches a catalogue regenerated without them is loading
    /// every one of them.
    func testTheSplitCoversBothPosesAndEveryFrame() throws {
        for name in [SissyModel.sissyAssetName, SissyModel.sissySleepingAssetName]
            + SissyMenuBarMotion.frameAssetNames
        {
            XCTAssertNotNil(
                NSImage(named: SissyArtwork.eyeAssetName(for: name)),
                "no eye for \(name); re-run scripts/sissy-eye-assets.py"
            )
            XCTAssertNotNil(
                NSImage(named: SissyArtwork.eyelessAssetName(for: name)),
                "no eyeless silhouette for \(name); re-run scripts/sissy-eye-assets.py"
            )
        }
    }

    /// A hold taken while she is blinking lights the rest of the gesture, and
    /// the eye keeps step with the silhouette under it instead of sticking on
    /// the frame it was lit at.
    func testAHoldTakenDuringAGestureTracksTheRemainingFrames() async throws {
        let button = NSButton()
        let animator = try makeAnimator(button)
        let overlay = try eyeOverlay(on: button)
        let resting = button.image

        XCTAssertTrue(animator.blink())
        await waitForFirstFrame(on: button, leaving: resting)
        let bodyBeforeTheFlip = button.image
        animator.setArtwork(.lit)

        // The body has to move to the eyeless set on the flip itself. Left to
        // the gesture it would only move on the next frame index, and the
        // shut-eye hold is one index held for four frames' worth of time.
        XCTAssertNotIdentical(button.image, bodyBeforeTheFlip)
        XCTAssertFalse(overlay.isHidden)

        let litAt = overlay.image
        await waitUntilIdle(animator)

        XCTAssertNotIdentical(overlay.image, litAt)
        XCTAssertNotIdentical(button.image, resting)

        animator.setArtwork(.template)
        XCTAssertIdentical(button.image, resting)
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
