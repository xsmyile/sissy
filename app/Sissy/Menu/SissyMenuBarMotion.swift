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

    static let framesPerSecond = 60.0

    /// Every frame of the sequence, in order, as asset catalogue names.
    static let frameAssetNames: [String] = (0..<frameCount).map {
        "SissyMotionBlink" + String(format: "%03d", $0)
    }

    private static let frameCount = 24
    private static let blinkDuration: TimeInterval = 0.380
    private static let shutEyeFirst = 6
    private static let shutEyeLast = 9
}
