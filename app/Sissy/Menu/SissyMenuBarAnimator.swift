import AppKit

/// Plays one mascot gesture at a time by swapping the status button's image
/// through a frame sequence.
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
                "Missing mascot frame \(name). Regenerate the asset catalogue."
            }
        }
    }

    /// Read before and during playback, so an open menu blocks a new gesture
    /// and interrupts a running one.
    var canAnimate: () -> Bool = { true }

    private(set) var isPlaying = false
    var isSchedulingOccasionalAnimations: Bool { occasionalTask != nil }

    private weak var button: NSButton?
    private let awakeImage: NSImage
    private let asleepImage: NSImage
    private let frames: [SissyMenuBarMotion: [NSImage]]
    private var pose: Pose = .awake
    private var playbackTask: Task<Void, Never>?
    private var occasionalTask: Task<Void, Never>?
    private var generation: UInt = 0
    private let reduceMotion: () -> Bool

    private static let occasionalInterval: ClosedRange<TimeInterval> = 120...240
    private static let frameTolerance: Duration = .milliseconds(1)

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
        awakeImage = try load(SissyModel.mascotAssetName)
        asleepImage = try load(SissyModel.mascotSleepingAssetName)
        frames = try Dictionary(
            uniqueKeysWithValues: SissyMenuBarMotion.allCases.map { motion in
                (motion, try motion.assetNames.map(load))
            }
        )
        self.button = button
        self.reduceMotion = reduceMotion
        button.image = awakeImage
    }

    isolated deinit {
        playbackTask?.cancel()
        occasionalTask?.cancel()
        button?.image = restingImage
    }

    /// Swaps the resting pose. Asleep also blocks gestures: a mascot that
    /// blinks while the daemon is unreachable claims something is arriving.
    func setPose(_ newPose: Pose) {
        guard newPose != pose else { return }
        pose = newPose
        stop()
    }

    /// Requests one gesture. A request that arrives during playback is
    /// dropped, never queued: a backlog of gestures reads as a twitching icon.
    @discardableResult
    func play(_ motion: SissyMenuBarMotion) -> Bool {
        guard pose == .awake, !isPlaying, button != nil, !reduceMotion(), canAnimate(),
            let images = frames[motion]
        else { return false }

        generation &+= 1
        let token = generation
        isPlaying = true
        let duration = motion.duration
        playbackTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            let started = clock.now
            var lastIndex = -1
            defer { self?.finish(generation: token) }

            while !Task.isCancelled {
                guard self?.generation == token, self?.button != nil,
                    self?.reduceMotion() == false, self?.canAnimate() == true
                else { return }

                let elapsed = started.duration(to: clock.now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                guard seconds < duration else { return }
                let index = min(Int(seconds * SissyMenuBarMotion.framesPerSecond), images.count - 1)
                if index != lastIndex {
                    self?.button?.image = images[index]
                    lastIndex = index
                }

                // Absolute deadlines skip overdue frames instead of stretching
                // the gesture when the main actor is busy.
                let next = min(Double(index + 1) / SissyMenuBarMotion.framesPerSecond, duration)
                let deadline = started.advanced(by: .nanoseconds(Int64(next * 1e9)))
                do { try await clock.sleep(until: deadline, tolerance: Self.frameTolerance) } catch { return }
            }
        }
        return true
    }

    /// Cancels a running gesture and restores the resting frame immediately.
    func stop() {
        generation &+= 1
        playbackTask?.cancel()
        playbackTask = nil
        isPlaying = false
        button?.image = restingImage
    }

    /// Schedules `motion` every few minutes. Nothing animates in between —
    /// this is character, not an indicator, so a blocked trigger is skipped
    /// rather than replayed later.
    func startOccasionalAnimations(_ motion: SissyMenuBarMotion) {
        stopOccasionalAnimations()
        occasionalTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let delay = TimeInterval.random(in: Self.occasionalInterval)
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.play(motion)
            }
        }
    }

    func stopOccasionalAnimations() {
        occasionalTask?.cancel()
        occasionalTask = nil
    }

    static let systemReduceMotion: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func finish(generation token: UInt) {
        guard generation == token else { return }
        playbackTask = nil
        isPlaying = false
        button?.image = restingImage
    }
}
