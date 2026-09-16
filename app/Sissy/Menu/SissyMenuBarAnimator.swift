import AppKit

/// Plays Sissy's eye on the status button: a blink when data lands, and
/// the eye closing or opening as readings stop and start again.
///
/// Once this exists it is the only writer of `button.image`, and the owner of
/// the eye overlay drawn above it: a refresh that reassigned either
/// mid-gesture would drop the remaining frames and leave whichever one
/// happened to be showing.
@MainActor
final class SissyMenuBarAnimator {
    /// The pose the button rests in between gestures.
    enum Pose {
        case awake
        case asleep
    }

    /// Which set of images the same pose is drawn from.
    ///
    /// Orthogonal to the pose because the two answer different questions: the
    /// pose is whether anything is reaching the app, the artwork whether the
    /// Mac is being held awake. Only three of the four pairs are reachable
    /// today — `SissyModel.keepAwake` reports `active` off the frame, and no
    /// frame is exactly what makes the pose shut — so a lit eye is always an
    /// open one. Keeping them independent here is what stops that becoming a
    /// rule the drawing relies on.
    enum Artwork {
        case template
        case lit
    }

    /// Read before and during playback, so an open menu blocks a new gesture
    /// and interrupts a running one.
    var canAnimate: () -> Bool = { true }

    private(set) var isPlaying = false
    private(set) var pose: Pose = .awake
    private(set) var artwork: Artwork = .template

    /// One image per pose and per frame of the blink.
    ///
    /// One copy of each, shared by all three motions: a copy per motion would
    /// make the same artwork rasterize once per copy.
    private struct Frames {
        let awake: NSImage
        let asleep: NSImage
        let blink: [NSImage]

        func resting(_ pose: Pose) -> NSImage { pose == .awake ? awake : asleep }
    }

    private weak var button: NSButton?
    private let silhouettes: Frames
    /// The two halves of the split and the view the eye is drawn in, or nil
    /// where the catalogue has no eye for a frame: Sissy is then exactly what
    /// she was rather than losing the blink with the tint, which is the part
    /// worth keeping of the two.
    private let lit: LitFrames?
    private let eyeOverlay: SissyEyeOverlay?

    /// The body a lit eye sits on, beside the eye itself. They are one value
    /// because a frame drawn from one and not the other is the fringe the
    /// split exists to remove.
    private struct LitFrames {
        let eyeless: Frames
        let eyes: Frames
    }
    private var playbackTask: Task<Void, Never>?
    /// Which frame of a gesture the button is showing, and nil while it rests.
    /// The playback loop's dedup reads it rather than keeping its own, so a
    /// redraw from outside the loop is not undone by the next tick.
    private var drawnFrame: Int?
    private var generation: UInt = 0
    private let reduceMotion: () -> Bool

    private var bodyFrames: Frames {
        artwork == .lit ? (lit?.eyeless ?? silhouettes) : silhouettes
    }

    private var restingImage: NSImage { bodyFrames.resting(pose) }

    /// Loads every frame before touching the button, so a catalogue missing a
    /// frame leaves the caller's static icon exactly as it was.
    ///
    /// The accessibility read is injected so a test can drive playback on a
    /// machine that has Reduce Motion switched on.
    init(
        button: NSButton,
        iconSize: CGFloat,
        reduceMotion: @escaping () -> Bool = SissyMenuBarAnimator.systemReduceMotion
    ) throws {
        func build(_ make: (String, CGFloat) throws -> NSImage) throws -> Frames {
            var blink: [NSImage] = []
            blink.reserveCapacity(SissyMenuBarMotion.frameAssetNames.count)
            for name in SissyMenuBarMotion.frameAssetNames {
                blink.append(try make(name, iconSize))
            }
            return Frames(
                awake: try make(SissyModel.sissyAssetName, iconSize),
                asleep: try make(SissyModel.sissySleepingAssetName, iconSize),
                blink: blink
            )
        }
        silhouettes = try build(SissyArtwork.silhouette)
        do {
            lit = try LitFrames(eyeless: build(SissyArtwork.eyeless), eyes: build(SissyArtwork.eye))
        } catch {
            lit = nil
            NSLog("sissy: eye tint unavailable: %@", error.localizedDescription)
        }
        eyeOverlay = lit == nil ? nil : SissyEyeOverlay.installed(on: button)
        self.button = button
        self.reduceMotion = reduceMotion
        drawResting()
    }

    /// The overlay goes with the animator. It is a subview of a button the
    /// animator only borrows, so leaving it behind would hand a rebuilt
    /// animator a second one to draw over.
    isolated deinit {
        playbackTask?.cancel()
        eyeOverlay?.removeFromSuperview()
        button?.image = restingImage
    }

    /// One blink. A request that arrives during playback is dropped, never
    /// queued: a backlog of blinks reads as a twitching icon.
    @discardableResult
    func blink() -> Bool {
        guard pose == .awake, !reduceMotion(), canAnimate() else { return false }
        return start(.blink)
    }

    /// Moves the resting pose, closing or opening the eye on the way there.
    ///
    /// Asleep also blocks the blink: blinking while nothing is reaching the
    /// app claims something is arriving. `animated` off — Reduce
    /// Motion, an open menu, or the pose the app starts in — snaps instead.
    ///
    /// The destination image is never installed before the transition runs:
    /// the eye would flash shut before closing, and flash open before opening.
    func setPose(_ newPose: Pose, animated: Bool = true) {
        guard newPose != pose else { return }
        let shouldAnimate = animated && !reduceMotion() && canAnimate()
        cancelPlayback()
        pose = newPose
        if shouldAnimate, start(newPose == .asleep ? .eyeClose : .eyeOpen) { return }
        drawResting()
    }

    /// Lights the eye, or puts it out, and redraws whatever is on screen so
    /// both layers move together.
    ///
    /// The frame on screen is redrawn rather than left to the gesture: the
    /// playback loop only writes when the frame index changes, and frames 6-9
    /// are one index held for four frames' worth of time. A flip landing in
    /// that window would show the lit eye over a body still drawn from the
    /// other set — the eye ink fringing through the blue, or no eye at all —
    /// which is the pairing the eyeless split exists to prevent.
    func setArtwork(_ newArtwork: Artwork) {
        guard newArtwork != artwork, let eyeOverlay else { return }
        artwork = newArtwork
        eyeOverlay.isHidden = newArtwork != .lit
        if let drawnFrame { draw(frame: drawnFrame) } else { drawResting() }
    }

    /// Cancels a running gesture and restores the resting frame immediately.
    func stop() {
        cancelPlayback()
        drawResting()
    }

    static let systemReduceMotion: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Runs `motion` to its end, then rests on the current pose. Each half of
    /// the blink ends on the pose it was started for, so the handover from the
    /// last frame to the resting image is invisible.
    @discardableResult
    private func start(_ motion: SissyMenuBarMotion) -> Bool {
        guard !isPlaying, button != nil else { return false }

        generation &+= 1
        let token = generation
        isPlaying = true
        playbackTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            let started = clock.now
            defer { self?.finish(generation: token) }

            while !Task.isCancelled {
                guard self?.generation == token, self?.button != nil,
                    self?.canAnimate() == true
                else { return }

                guard let step = motion.step(at: started.duration(to: clock.now)) else { return }
                if self?.drawnFrame != step.index {
                    self?.draw(frame: step.index)
                }

                // Absolute deadlines skip overdue frames instead of stretching
                // the gesture when the main actor is busy.
                let deadline = started.advanced(by: .nanoseconds(Int64(step.endsAt * 1e9)))
                let tolerance = SissyMenuBarMotion.frameTolerance
                do { try await clock.sleep(until: deadline, tolerance: tolerance) } catch { return }
            }
        }
        return true
    }

    /// The one place both layers are written, so the eye can never be left on
    /// a frame the silhouette under it has moved off.
    private func drawResting() {
        drawnFrame = nil
        button?.image = restingImage
        draw(eye: lit?.eyes.resting(pose))
    }

    private func draw(frame index: Int) {
        drawnFrame = index
        button?.image = bodyFrames.blink[index]
        draw(eye: lit?.eyes.blink[index])
    }

    /// The overlay is re-squared on the button every time it is drawn rather
    /// than autoresized into place: the button has no bounds yet when the
    /// animator is built, and a subview that starts at zero is one an
    /// autoresizing mask keeps at zero however big its superview gets.
    private func draw(eye image: NSImage?) {
        guard let eyeOverlay, let button else { return }
        eyeOverlay.frame = eyeRect(on: button)
        eyeOverlay.image = image
    }

    /// The rect the button's own cell draws the silhouette into, which is the
    /// only rect the eye may be drawn into as well.
    ///
    /// Given the button's whole bounds instead, the overlay centres the eye in
    /// them itself — and `NSImageView` rounds that centring offset to a whole
    /// point where `NSButtonCell` does not, so the two land apart whenever the
    /// offset falls on a half. A 17 pt icon in the status button always does:
    /// measured on macOS 26, the eye drew 0.95 device pixels high and 0.79
    /// wide of the ink it covers, which is a third of the height of an eye
    /// three device pixels tall, and it moved as the hold was switched — off,
    /// the eye is ink inside the cell's own image. Handing over a rect the
    /// size of the image leaves the overlay no centring left to round. The
    /// panel never had this: SwiftUI stacks both layers on one frame.
    private func eyeRect(on button: NSButton) -> NSRect {
        guard let cell = button.cell as? NSButtonCell else { return button.bounds }
        return cell.imageRect(forBounds: button.bounds)
    }

    /// Ends playback without deciding what the button shows: the callers
    /// differ on that, and a pose change must not paint its destination before
    /// its own transition has drawn a frame.
    private func cancelPlayback() {
        generation &+= 1
        playbackTask?.cancel()
        playbackTask = nil
        isPlaying = false
    }

    private func finish(generation token: UInt) {
        guard generation == token else { return }
        playbackTask = nil
        isPlaying = false
        drawResting()
    }
}
