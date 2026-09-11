import AppKit

/// Plays Sissy's eye on the status button: a blink when data lands, and
/// the eye closing or opening as readings stop and start again.
///
/// Once this exists it is the only writer of `button.image`: a refresh that
/// reassigned the image mid-gesture would drop the remaining frames and leave
/// whichever one happened to be showing.
@MainActor
final class SissyMenuBarAnimator {
    /// The pose the button rests in between gestures.
    enum Pose {
        case awake
        case asleep
    }

    enum AssetError: LocalizedError {
        case missingImage(String)

        var errorDescription: String? {
            switch self {
            case .missingImage(let name):
                "Missing Sissy frame \(name). Regenerate the asset catalogue."
            }
        }
    }

    /// Read before and during playback, so an open menu blocks a new gesture
    /// and interrupts a running one.
    var canAnimate: () -> Bool = { true }

    private(set) var isPlaying = false
    private(set) var pose: Pose = .awake

    private weak var button: NSButton?
    private let awakeImage: NSImage
    private let asleepImage: NSImage
    /// One copy of each frame, shared by all three motions: a copy per motion
    /// would make the same artwork rasterize once per copy.
    private let frames: [NSImage]
    private var playbackTask: Task<Void, Never>?
    private var generation: UInt = 0
    private let reduceMotion: () -> Bool

    private var restingImage: NSImage { pose == .awake ? awakeImage : asleepImage }

    /// Loads every frame before touching the button, so a catalogue missing a
    /// frame leaves the caller's static icon exactly as it was.
    ///
    /// `NSImage(named:)` hands back the catalogue's shared instance, which is
    /// why each frame is copied before it is resized. The accessibility read
    /// is injected so a test can drive playback on a machine that has Reduce
    /// Motion switched on.
    init(
        button: NSButton,
        iconSize: CGFloat,
        reduceMotion: @escaping () -> Bool = SissyMenuBarAnimator.systemReduceMotion
    ) throws {
        func load(_ name: String) throws -> NSImage {
            guard let image = NSImage(named: name)?.copy() as? NSImage else {
                throw AssetError.missingImage(name)
            }
            image.size = NSSize(width: iconSize, height: iconSize)
            image.isTemplate = true
            return image
        }
        awakeImage = try load(SissyModel.sissyAssetName)
        asleepImage = try load(SissyModel.sissySleepingAssetName)
        frames = try SissyMenuBarMotion.frameAssetNames.map(load)
        self.button = button
        self.reduceMotion = reduceMotion
        button.image = awakeImage
    }

    isolated deinit {
        playbackTask?.cancel()
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
        button?.image = restingImage
    }

    /// Cancels a running gesture and restores the resting frame immediately.
    func stop() {
        cancelPlayback()
        button?.image = restingImage
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
                    self?.button?.image = self?.frames[step.index]
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
        button?.image = restingImage
    }
}
