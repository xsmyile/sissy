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

    private func eyeOverlay(
        of animator: SissyMenuBarAnimator,
        line: UInt = #line
    ) throws -> SissyOverlay {
        try XCTUnwrap(animator.eyeOverlay, "the animator installed no eye overlay", line: line)
    }

    private let held = SissyMenuBarAnimator.Artwork(eyeLit: true, dot: nil)

    /// The silhouette stays the template image in both states: that is what
    /// macOS applies the appearance, the menu highlight and full-strength ink
    /// to, and compositing the eye into it costs the body two fifths of that
    /// ink to the menu bar's vibrancy.
    func testTheSilhouetteStaysATemplateImageWhicheverWayTheEyeIs() throws {
        let button = NSButton()
        let animator = try makeAnimator(button)

        animator.setArtwork(held)
        XCTAssertEqual(button.image?.isTemplate, true)

        animator.setArtwork(.template)
        XCTAssertEqual(button.image?.isTemplate, true)
    }

    func testNothingHeldLeavesTheEyeUnlit() throws {
        let button = NSButton()
        let animator = try makeAnimator(button)

        XCTAssertEqual(animator.artwork, .template)
        XCTAssertTrue(try eyeOverlay(of: animator).isHidden)
    }

    func testAHoldLightsTheEyeOverTheSamePose() throws {
        let button = NSButton()
        let animator = try makeAnimator(button)

        animator.setArtwork(held)

        let overlay = try eyeOverlay(of: animator)
        XCTAssertEqual(animator.artwork, held)
        XCTAssertFalse(overlay.isHidden)
        XCTAssertEqual(overlay.image?.size, NSSize(width: iconSize, height: iconSize))
        XCTAssertEqual(overlay.contentTintColor, SissyArtwork.holdTint)
    }

    /// Pressure lights the dot and leaves the eye to the hold, and moving
    /// between the two levels recolours the dot over the same body.
    func testAPressureLightsTheDotAndLeavesTheEyeToTheHold() throws {
        let button = NSButton()
        let animator = try makeAnimator(button)
        let whole = button.image

        animator.setArtwork(.init(eyeLit: false, dot: .critical))
        let dotted = button.image

        XCTAssertTrue(try eyeOverlay(of: animator).isHidden)
        XCTAssertFalse(animator.dotOverlay.isHidden)
        XCTAssertEqual(animator.dotOverlay.contentTintColor, SissyArtwork.criticalTint)
        XCTAssertNotIdentical(dotted, whole)
        XCTAssertEqual(dotted?.isTemplate, true)

        animator.setArtwork(.init(eyeLit: false, dot: .warn))
        XCTAssertEqual(animator.dotOverlay.contentTintColor, SissyArtwork.warnTint)
        XCTAssertIdentical(button.image, dotted)

        animator.setArtwork(.template)
        XCTAssertTrue(animator.dotOverlay.isHidden)
        XCTAssertIdentical(button.image, whole)
    }

    /// A hold under pressure shows both, each in its own colour, on a body
    /// that has lost the eye's ink and the dot's corner together.
    func testAHoldUnderPressureShowsTheEyeAndTheDot() throws {
        let button = NSButton()
        let animator = try makeAnimator(button)
        animator.setArtwork(held)
        let eyeless = button.image

        animator.setArtwork(.init(eyeLit: true, dot: .warn))

        let eye = try eyeOverlay(of: animator)
        XCTAssertFalse(eye.isHidden)
        XCTAssertEqual(eye.contentTintColor, SissyArtwork.holdTint)
        XCTAssertFalse(animator.dotOverlay.isHidden)
        XCTAssertEqual(animator.dotOverlay.contentTintColor, SissyArtwork.warnTint)
        XCTAssertNotIdentical(button.image, eyeless)
    }

    /// Where the head comes nearest the corner, its ink reaches inside the
    /// dot's own radius, so the body the dot sits on has to have that ink cut
    /// out or the colour merges into it.
    func testTheDotTouchesTheHeadItIsCutOutOf() throws {
        let body = try SissyArtwork.silhouette(SissyModel.sissyAssetName, size: SissyArtwork.dotCanvas)

        XCTAssertGreaterThan(try inkInside(dotCut, of: body), 0, "the dot no longer touches the head")
    }

    /// Every body the animator can put under the dot leaves the ring empty:
    /// both poses and all 24 frames, whole and eyeless.
    func testEveryBodyUnderTheDotHasTheRingCutOut() throws {
        let names =
            [SissyModel.sissyAssetName, SissyModel.sissySleepingAssetName]
            + SissyMenuBarMotion.frameAssetNames
        for name in names + names.map(SissyArtwork.eyelessAssetName) {
            let body = try SissyArtwork.silhouette(name, size: SissyArtwork.dotCanvas)
            XCTAssertEqual(try inkInside(dotCut, of: SissyArtwork.knockedOut(body)), 0, name)
        }
    }

    private var dotCut: NSRect {
        let canvas = SissyArtwork.dotCanvas
        return SissyArtwork.dotRect(
            in: NSRect(x: 0, y: 0, width: canvas, height: canvas),
            margin: SissyArtwork.dotGap
        )
    }

    /// Opaque pixels of `image` inside the circle `oval` bounds, rasterized
    /// at 4x. A pixel counts only when the whole of it is inside, so the
    /// antialiased edge the cut itself draws is not read as ink it left.
    private func inkInside(_ oval: NSRect, of image: NSImage) throws -> Int {
        let scale: CGFloat = 4
        let side = Int(image.size.width * scale)
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )
        )
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()

        let radius = oval.width / 2 - 1 / scale
        var count = 0
        for row in 0..<side {
            for column in 0..<side {
                let x = (CGFloat(column) + 0.5) / scale
                let y = image.size.height - (CGFloat(row) + 0.5) / scale
                guard hypot(x - oval.midX, y - oval.midY) < radius else { continue }
                if let alpha = rep.colorAt(x: column, y: row)?.alphaComponent, alpha > 0.1 {
                    count += 1
                }
            }
        }
        return count
    }

    /// The blue is laid over the body, so a body that kept its own eye ink
    /// would show through the blue's antialiased edge as a fringe.
    func testALitEyeSitsOnTheEyelessSilhouette() throws {
        let button = NSButton()
        let animator = try makeAnimator(button)
        let whole = button.image

        animator.setArtwork(held)
        let eyeless = button.image

        XCTAssertNotIdentical(eyeless, whole)
        XCTAssertEqual(eyeless?.size, NSSize(width: iconSize, height: iconSize))

        animator.setArtwork(.template)
        XCTAssertIdentical(button.image, whole)
    }

    /// Shaped like the status item's own button, which
    /// `StatusItemController.configureButton` configures the same way: the
    /// cell's image rect is what the eye is placed against, and it depends on
    /// the button being image-only and unbordered.
    private func statusShapedButton() -> NSButton {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
        button.title = ""
        button.isBordered = false
        button.imagePosition = .imageOnly
        return button
    }

    /// The eye goes where the cell draws the silhouette, never into the whole
    /// button.
    ///
    /// Given the bounds, `NSImageView` centres the eye itself and rounds that
    /// offset to a whole point where `NSButtonCell` does not — measured at
    /// 0.95 device pixels of vertical drift on an eye three of them tall,
    /// appearing and disappearing as the hold was switched. The two rects
    /// differ at exactly the menu bar's own geometry, which is what the last
    /// assertion pins: a 17 pt icon in a 24 x 22 pt button centres on a half
    /// point in both axes.
    func testTheEyeIsDrawnIntoTheRectTheCellDrawsTheSilhouetteInto() throws {
        let button = statusShapedButton()
        let animator = try makeAnimator(button)
        let overlay = try eyeOverlay(of: animator)
        let cell = try XCTUnwrap(button.cell as? NSButtonCell)

        XCTAssertEqual(overlay.frame, cell.imageRect(forBounds: button.bounds))
        XCTAssertEqual(overlay.frame.size, NSSize(width: iconSize, height: iconSize))
        XCTAssertNotEqual(overlay.frame, button.bounds)
        XCTAssertEqual(animator.dotOverlay.frame, overlay.frame)
        withExtendedLifetime(animator) {}
    }

    /// The rect is asked for on every draw, so a button that is laid out after
    /// the animator was built still gets the eye in the right place.
    func testTheEyeFollowsTheButtonWhenItIsResized() throws {
        let button = statusShapedButton()
        let animator = try makeAnimator(button)
        let overlay = try eyeOverlay(of: animator)
        let before = overlay.frame

        button.setFrameSize(NSSize(width: 30, height: 26))
        animator.stop()

        let cell = try XCTUnwrap(button.cell as? NSButtonCell)
        XCTAssertNotEqual(overlay.frame, before)
        XCTAssertEqual(overlay.frame, cell.imageRect(forBounds: button.bounds))
        XCTAssertEqual(animator.dotOverlay.frame, overlay.frame)
    }

    /// The overlay is the one view sitting on the status button, so a click
    /// that landed on it instead of the button would lose the panel.
    func testTheEyeOverlayNeverTakesAClick() throws {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
        let animator = try makeAnimator(button)
        let overlay = try eyeOverlay(of: animator)

        XCTAssertNil(overlay.hitTest(NSPoint(x: overlay.bounds.midX, y: overlay.bounds.midY)))
        let dot = animator.dotOverlay
        XCTAssertNil(dot.hitTest(NSPoint(x: dot.bounds.midX, y: dot.bounds.midY)))
    }

    /// The overlay is a subview of a button the animator only borrows, so an
    /// animator that let go of it would leave a second one behind for its
    /// replacement to draw over.
    func testTheEyeOverlayLeavesWithItsAnimator() throws {
        let button = NSButton()
        try autoreleasepool {
            let animator = try makeAnimator(button)
            XCTAssertEqual(button.subviews.compactMap { $0 as? SissyOverlay }.count, 2)
            withExtendedLifetime(animator) {}
        }

        XCTAssertTrue(button.subviews.compactMap { $0 as? SissyOverlay }.isEmpty)
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
        let overlay = try eyeOverlay(of: animator)
        let resting = button.image

        XCTAssertTrue(animator.blink())
        await waitForFirstFrame(on: button, leaving: resting)
        let bodyBeforeTheFlip = button.image
        animator.setArtwork(held)

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

    // MARK: Menu bar dot

    func testANormalOrUnreadMacShowsNoDot() {
        XCTAssertNil(SissyDot(level: .normal))
        XCTAssertNil(SissyDot(level: nil))
    }

    func testEachLevelHasItsOwnDot() {
        XCTAssertEqual(SissyDot(level: .warn), .warn)
        XCTAssertEqual(SissyDot(level: .critical), .critical)
        XCTAssertEqual(SissyDot.warn.tint, NSColor.systemOrange)
        XCTAssertEqual(SissyDot.critical.tint, NSColor.systemRed)
    }
}
