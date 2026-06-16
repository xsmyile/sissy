import AppKit
import Foundation
import Observation
import SwiftUI

/// Transient menubar pop-ups for mood changes and cost milestones. Uses
/// `NSPopover` because SwiftUI has no menubar-anchored transient panel; the
/// SwiftUI content is hosted via `NSHostingController`. Chosen over a
/// Notification Center banner so it stays on-brand and bypasses Focus/DND.
///
/// Delivery rules (apply to both flows):
///   * Mood pop-up: skipped on the first frame after launch (nothing to
///     compare to) and whenever `state` doesn't change.
///   * Milestone pop-up: fires once per `(milestone, ts)` crossing.
///   * Suppressed when a pin is active, when
///     `Preferences.notifyOnMascotChange` is off, or while the status menu
///     is open.
///   * A single `NSPopover` instance is reused; consecutive changes replace
///     prior content instead of stacking.
@MainActor
final class MascotNotifier {
    private weak var model: SissyModel?
    private let statusButtonProvider: () -> NSStatusBarButton?
    private let menuIsOpenProvider: () -> Bool
    private var lastNotifiedState: String?
    private var lastMilestoneKey: MilestoneKey?
    private var isStopped = false
    private let popover = NSPopover()
    private var dismissWork: DispatchWorkItem?
    private var milestoneClearWork: DispatchWorkItem?

    private struct MilestoneKey: Equatable {
        let milestone: String
        let ts: Int
    }

    /// Wall-clock the pop-up stays visible before auto-dismiss. Matches the
    /// macOS notification banner default (5 s) so it reads as native banner
    /// cadence — long enough to clear the headline + cost subline at a
    /// glance, short enough to feel ephemeral. Same constant drives the
    /// header milestone clear so both surfaces fade in lock-step.
    private static let dismissAfter: TimeInterval = 5.0

    init(
        model: SissyModel,
        statusButtonProvider: @escaping () -> NSStatusBarButton?,
        menuIsOpenProvider: @escaping () -> Bool
    ) {
        self.model = model
        self.statusButtonProvider = statusButtonProvider
        self.menuIsOpenProvider = menuIsOpenProvider
        popover.behavior = .transient
        popover.animates = true
    }

    func start() {
        guard model != nil else { return }
        isStopped = false
        observeFrame()
    }

    func stop() {
        isStopped = true
        dismissWork?.cancel()
        dismissWork = nil
        milestoneClearWork?.cancel()
        milestoneClearWork = nil
        if popover.isShown { popover.performClose(nil) }
    }

    /// Re-arming observation of `model.currentFrame`. `@Observable` exposes no
    /// Combine publisher, so the two former pipelines become explicit stateful
    /// dedupes: the mood pop-up fires only when `state` changes (mirrors the
    /// old `removeDuplicates` on state), and the milestone pop-up fires once
    /// per `(milestone, ts)` crossing — distinct crossings carry distinct
    /// frame timestamps, while daemon replays of the same crossing repeat the
    /// ts. Reading the committed frame on the next main-actor turn also
    /// removes the `willSet` staleness the publisher version had to work
    /// around (state and cost/tokens now always come from the same frame).
    private func observeFrame() {
        guard !isStopped else { return }
        withObservationTracking {
            _ = model?.currentFrame
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isStopped else { return }
                self.processFrameChange()
                self.observeFrame()
            }
        }
    }

    private func processFrameChange() {
        let frame = model?.currentFrame
        let state = frame?.state
        if state != lastNotifiedState {
            handle(state: state, frame: frame)
        }
        if let frame, let milestone = frame.milestone, !milestone.isEmpty {
            let key = MilestoneKey(milestone: milestone, ts: frame.ts)
            if key != lastMilestoneKey {
                lastMilestoneKey = key
                handleMilestone(milestone, frame: frame)
            }
        }
    }

    private func handle(state: String?, frame: DisplayFrame?) {
        defer { lastNotifiedState = state }
        guard let model, let state else { return }

        // Pick the catchphrase once and publish it before the pop-up guards
        // run. Header reads `currentMoodPhrase` on its next refresh so the
        // two surfaces agree for a given transition. Even with the pref off,
        // a pin active, or the menu open, the header still rotates — only
        // the pop-up is suppressed.
        let phrase = StateDescriptor.randomVoice(for: state)
        model.currentMoodPhrase = phrase

        guard let button = statusButtonProvider(),
            lastNotifiedState != nil,
            model.pinnedMascot == nil,
            model.preferences.notifyOnMascotChange,
            !menuIsOpenProvider()
        else { return }

        let view = MoodChangePopover(
            state: state,
            content: .mood(voice: phrase),
            frame: frame
        )
        present(view, anchoredTo: button)
    }

    private func handleMilestone(_ raw: String, frame: DisplayFrame) {
        guard let model, let descriptor = MilestoneDescriptor.parse(raw) else { return }

        let phrase = descriptor.phrase()
        model.currentMilestonePhrase = phrase
        scheduleMilestoneClear()

        guard let button = statusButtonProvider(),
            model.preferences.notifyOnMascotChange,
            !menuIsOpenProvider()
        else { return }

        let view = MoodChangePopover(
            state: frame.state,
            content: .milestone(phrase: phrase),
            frame: frame
        )
        present(view, anchoredTo: button)
    }

    /// Clears the header's milestone line after the same dismiss window the
    /// pop-up uses, so the two surfaces fade together. Cancels any pending
    /// clear first — back-to-back crossings reset the timer instead of
    /// inheriting the previous one's countdown.
    private func scheduleMilestoneClear() {
        milestoneClearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.model?.currentMilestonePhrase = nil
        }
        milestoneClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dismissAfter, execute: work)
    }

    private func present(_ view: MoodChangePopover, anchoredTo button: NSStatusBarButton) {
        popover.contentViewController = NSHostingController(rootView: view)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.popover.isShown { self.popover.performClose(nil) }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dismissAfter, execute: work)
    }
}

/// SwiftUI content for the menubar pop-up. Two modes share the same chrome:
/// `.mood` reads "Sissy is X" for an organic state transition; `.milestone`
/// renders the celebration phrase verbatim because the catchphrase is
/// already a full sentence (e.g. "$25 lighter, worth every cent"). The
/// sprite + stats subline are identical across modes.
private struct MoodChangePopover: View {
    enum Content {
        case mood(voice: String)
        case milestone(phrase: String)
    }

    let state: String
    let content: Content
    let frame: DisplayFrame?

    var body: some View {
        HStack(spacing: 10) {
            Image(StateDescriptor.mascotImageName(for: state))
                .resizable()
                .renderingMode(.template)
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 13, weight: .semibold))
                if let frame, let line = Self.statsLine(frame: frame) {
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .fixedSize()
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var headline: String {
        switch content {
        case .mood(let voice): return StateDescriptor.moodHeadline(voice: voice)
        case .milestone(let phrase): return phrase
        }
    }

    private static func statsLine(frame: DisplayFrame) -> String? {
        var parts: [String] = []
        if frame.tokens != "..." { parts.append("\(frame.tokens) tok") }
        if frame.cost != "..." { parts.append("$\(frame.cost)") }
        if frame.burn != "..." { parts.append("\(frame.burn)/h") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
