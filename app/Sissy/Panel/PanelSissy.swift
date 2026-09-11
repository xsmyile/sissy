import SwiftUI

/// Whether a landing frame blinks Sissy in the panel, kept out of the view so
/// the rules can be asserted without rendering one.
struct PanelSissyBlinkGate {
    let motionEnabled: Bool
    let reduceMotion: Bool
    let isAsleep: Bool

    /// Asleep she never blinks: it would claim something is arriving
    /// while nothing is reaching the app. The cooldown is the animator's, so both
    /// surfaces pace their blinks the same way — each still keeps its own
    /// clock, and a panel opened mid-cooldown is not in phase with the menu
    /// bar.
    func allows(at now: Date, lastBlinkAt: Date) -> Bool {
        guard motionEnabled, !reduceMotion, !isAsleep else { return false }
        return now.timeIntervalSince(lastBlinkAt) >= SissyMenuBarMotion.dataBlinkCooldown
    }
}

/// Sissy in the panel header: the two resting poses cross-faded, with a
/// blink played over the awake one when a frame lands.
///
/// It replays `SissyMenuBarMotion.blink` — the sequence the status button's
/// animator draws — so the two surfaces move to the same timing instead of each
/// inventing one. Nothing here writes `button.image`: the menu bar's animator
/// stays its only writer.
struct PanelSissy: View {
    let isAsleep: Bool
    /// When the last frame landed. A change is the blink's trigger; the value
    /// itself is never drawn.
    let lastFrameAt: Date?
    let motionEnabled: Bool
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Bumped only when a blink is due, and compared against the generation
    /// playback has already consumed.
    ///
    /// The popover reuses one `NSHostingController` for the app's lifetime, so
    /// this state outlives every close and `.task(id:)` — which also fires on
    /// reappearance, not only on a change — would otherwise replay the last
    /// blink each time the panel opens, gate and cooldown bypassed.
    @State private var blinkGeneration: UInt = 0
    @State private var playedGeneration: UInt = 0
    @State private var lastBlinkAt: Date = .distantPast
    @State private var blinkFrame: Int?

    /// Long enough to read as the eye closing, short enough not to lag the
    /// power button the pose change follows.
    private static let poseFadeDuration: TimeInterval = 0.25

    /// A catalogue that lost a frame would render her blank mid-gesture.
    /// Resolved once, and the panel rests on the static silhouette instead —
    /// the same way `SissyMenuBarAnimator` degrades rather than draw nothing.
    private static let framesAreAvailable: Bool = SissyMenuBarMotion.frameAssetNames.allSatisfy {
        NSImage(named: $0) != nil
    }

    var body: some View {
        ZStack {
            image(awakeAssetName)
                .opacity(isAsleep ? 0 : 1)
            image(SissyModel.sissySleepingAssetName)
                .opacity(isAsleep ? 1 : 0)
        }
        .animation(.easeInOut(duration: Self.poseFadeDuration), value: isAsleep)
        .onChange(of: lastFrameAt) { _, arrival in
            guard arrival != nil else { return }
            scheduleBlink()
        }
        .task(id: blinkGeneration) {
            guard blinkGeneration != playedGeneration else { return }
            playedGeneration = blinkGeneration
            await playBlink()
        }
    }

    /// The awake layer carries a blink frame while one is playing and the
    /// resting silhouette otherwise. Frame 0 and frame 23 *are* that
    /// silhouette, so the handover in and out of a gesture is invisible.
    private var awakeAssetName: String {
        guard let blinkFrame else { return SissyModel.sissyAssetName }
        return SissyMenuBarMotion.frameAssetNames[blinkFrame]
    }

    /// Both poses are drawn, one of them transparent, because opacity is what
    /// animates: swapping the asset on one `Image` snaps, while fading a pair
    /// of them carries the eye shut the way the menu bar's own frames do.
    private func image(_ assetName: String) -> some View {
        Image(assetName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(.secondary)
    }

    private func scheduleBlink() {
        guard Self.framesAreAvailable else { return }
        let now = Date()
        let gate = PanelSissyBlinkGate(
            motionEnabled: motionEnabled,
            reduceMotion: reduceMotion,
            isAsleep: isAsleep
        )
        guard gate.allows(at: now, lastBlinkAt: lastBlinkAt) else { return }
        lastBlinkAt = now
        blinkGeneration &+= 1
    }

    /// Walks the sequence against absolute deadlines, so a busy main actor
    /// skips overdue frames instead of stretching the gesture past its own
    /// duration.
    private func playBlink() async {
        let motion = SissyMenuBarMotion.blink
        let clock = ContinuousClock()
        let started = clock.now
        defer { blinkFrame = nil }

        while !Task.isCancelled {
            guard let step = motion.step(at: started.duration(to: clock.now)) else { return }
            blinkFrame = step.index

            let deadline = started.advanced(by: .nanoseconds(Int64(step.endsAt * 1e9)))
            do {
                try await clock.sleep(until: deadline, tolerance: SissyMenuBarMotion.frameTolerance)
            } catch {
                return
            }
        }
    }
}
