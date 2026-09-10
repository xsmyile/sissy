import Foundation

/// The mascot's two menu bar gestures, each a frame sequence sampled at a
/// fixed rate.
///
/// The frames are traced from the same silhouette as the resting icon, and the
/// first and last frame of every sequence *are* that silhouette — so a gesture
/// starts and ends without a jump, whatever interrupts it. Durations come from
/// the motion the frames were rendered from, not from the frame count: the
/// sequence carries one frame past the end so the playback clamp always has a
/// frame to land on.
enum SissyMenuBarMotion: String, CaseIterable, Sendable {
    case blink
    case earTwitch

    var duration: TimeInterval {
        switch self {
        case .blink: Self.blinkDuration
        case .earTwitch: Self.earTwitchDuration
        }
    }

    var assetNames: [String] {
        switch self {
        case .blink: Self.names(prefix: "SissyMotionBlink", count: Self.blinkFrameCount)
        case .earTwitch: Self.names(prefix: "SissyMotionEar", count: Self.earTwitchFrameCount)
        }
    }

    static let framesPerSecond = 60.0

    private static let blinkDuration: TimeInterval = 0.380
    private static let earTwitchDuration: TimeInterval = 0.490
    private static let blinkFrameCount = 24
    private static let earTwitchFrameCount = 31

    private static func names(prefix: String, count: Int) -> [String] {
        (0..<count).map { prefix + String(format: "%03d", $0) }
    }
}
