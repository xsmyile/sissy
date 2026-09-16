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
    /// Orthogonal to the pose on purpose: the eye is lit or not for a reason
    /// that has nothing to do with whether it is open, and a manual hold with
    /// nothing arriving is exactly the pair — shut and lit — worth showing.
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
        lit = try? LitFrames(eyeless: build(SissyArtwork.eyeless), eyes: build(SissyArtwork.eye))
        eyeOverlay = lit == nil ? nil : SissyEyeOverlay.installed(on: button)
        self.button = button
        self.reduceMotion = reduceMotion
        drawResting()
    }

    isolated deinit {
        playbackTask?.cancel()
        drawResting()
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

    /// Lights the eye, or puts it out, without disturbing a gesture: the
    /// overlay tracks the silhouette frame by frame either way, so a hold
    /// taken mid-blink lights the rest of it and the resting frame after.
    func setArtwork(_ newArtwork: Artwork) {
        guard newArtwork != artwork, let eyeOverlay else { return }
        artwork = newArtwork
        eyeOverlay.isHidden = newArtwork != .lit
        guard !isPlaying else { return }
        drawResting()
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
            var lastIndex = -1
            defer { self?.finish(generation: token) }

            while !Task.isCancelled {
                guard self?.generation == token, self?.button != nil,
                    self?.canAnimate() == true
                else { return }

                guard let step = motion.step(at: started.duration(to: clock.now)) else { return }
                if step.index != lastIndex {
                    self?.draw(frame: step.index)
                    lastIndex = step.index
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
        button?.image = restingImage
        draw(eye: lit?.eyes.resting(pose))
    }

    private func draw(frame index: Int) {
        button?.image = bodyFrames.blink[index]
        draw(eye: lit?.eyes.blink[index])
    }

    /// The overlay is re-squared on the button every time it is drawn rather
    /// than autoresized into place: the button has no bounds yet when the
    /// animator is built, and a subview that starts at zero is one an
    /// autoresizing mask keeps at zero however big its superview gets.
    private func draw(eye image: NSImage?) {
        guard let eyeOverlay, let button else { return }
        eyeOverlay.frame = button.bounds
        eyeOverlay.image = image
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
