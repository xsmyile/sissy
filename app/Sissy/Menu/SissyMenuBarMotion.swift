import Foundation

/// The mascot's eye movements, as index ranges into one rendered sequence.
///
/// The sequence is a full blink: 24 frames at 60 fps, traced from the same
/// silhouette as the resting icon, with frame 0 and frame 23 *being* that
/// silhouette — so a gesture starts and ends without a jump, whatever
/// interrupts it. Frames 6 through 9 are byte-identical: that is the shut-eye
/// hold, and it is why the closing half stops at 6 and the opening half starts
/// at 9 instead of replaying it.
enum SissyMenuBarMotion: Sendable {
    /// Shut and open again: the mascot noticing new numbers.
    case blink
    /// The closing half alone, left resting on the shut eye.
    case eyeClose
    /// The opening half alone, back to the resting silhouette.
    case eyeOpen

    var frameRange: Range<Int> {
        switch self {
        case .blink: 0..<Self.frameCount
        case .eyeClose: 0..<(Self.shutEyeFirst + 1)
        case .eyeOpen: Self.shutEyeLast..<Self.frameCount
        }
    }

    /// The blink's own duration is the one the frames were rendered from; it
    /// falls a frame short of the sequence on purpose, so the playback clamp
    /// always has a frame to land on. The halves are measured off the frames
    /// they actually carry.
    var duration: TimeInterval {
        switch self {
        case .blink: Self.blinkDuration
        case .eyeClose, .eyeOpen: Double(frameRange.count) / Self.framesPerSecond
        }
    }

    /// Where a motion is `elapsed` after it started: the frame to draw, and
    /// when that frame gives way to the next. `nil` once the motion has run
    /// out — the caller then rests on its own pose.
    ///
    /// The index is absolute, into `frameAssetNames`, so a caller holding the
    /// whole sequence needs no range arithmetic of its own. Both surfaces that
    /// play the mascot go through here: the timing is the one thing they must
    /// not each reinvent.
    func step(at elapsed: Duration) -> Step? {
        let components = elapsed.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        guard seconds >= 0, seconds < duration else { return nil }

        let offset = min(Int(seconds * Self.framesPerSecond), frameRange.count - 1)
        return Step(
            index: frameRange.lowerBound + offset,
            endsAt: min(Double(offset + 1) / Self.framesPerSecond, duration)
        )
    }

    /// One frame of a running motion, as `step(at:)` reports it.
    struct Step: Equatable, Sendable {
        /// Index into `frameAssetNames`.
        let index: Int
        /// Seconds from the motion's start at which this frame is replaced.
        let endsAt: TimeInterval
    }

    static let framesPerSecond = 60.0

    /// How far a frame may land from its deadline before the sleep is worth
    /// re-arming. Shared, like the rest of the timing, so neither surface
    /// drifts from the other.
    static let frameTolerance: Duration = .milliseconds(1)

    /// Shortest spacing between two data-driven blinks, shared by every
    /// surface that plays one. Each keeps its own clock, so this sets the
    /// rhythm they have in common, not a frame they share.
    ///
    /// The readers coalesce emits only down to
    /// `UsageReaderShared.pollEmitThrottle` (0.2 s), so a turn appending JSONL
    /// in bursts can push a frame a second — and a 380 ms gesture that often
    /// never lets the mascot settle reads as a twitch.
    static let dataBlinkCooldown: TimeInterval = 3

    /// Every frame of the sequence, in order, as asset catalogue names.
    static let frameAssetNames: [String] = (0..<frameCount).map {
        "SissyMotionBlink" + String(format: "%03d", $0)
    }

    private static let frameCount = 24
    private static let blinkDuration: TimeInterval = 0.380
    private static let shutEyeFirst = 6
    private static let shutEyeLast = 9
}
