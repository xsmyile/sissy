import AppKit
import Foundation
import Observation

/// Main runtime owner for the menubar app. UI surfaces observe this object,
/// while the metering engine and the login item stay as leaf implementation
/// details behind it.
@MainActor
@Observable
final class SissyModel {
    var currentFrame: FrameData? = nil
    var lastFrameAt: Date? = nil
    var preferences: Preferences
    var settingsTab: SettingsTab = .general

    private let supportDirectory: URL
    let engine: UsageEngineHost
    let loginItem: LoginItemController

    /// `loginItem` is injected so a test can pin the lookup to a service that
    /// is definitely not registered, rather than letting whatever is on the
    /// machine decide what the model reports. `supportDirectory` is injected
    /// for the other half of that problem: `xcodebuild test` launches the
    /// real app host, which builds this model against the machine's own
    /// install, so a test covering a path that persists preferences needs
    /// somewhere else to write.
    init(
        loginItem: LoginItemController = LoginItemController(),
        supportDirectory: URL = Preferences.appSupportDir()
    ) {
        self.supportDirectory = supportDirectory
        self.preferences = .load(from: supportDirectory)
        self.loginItem = loginItem
        self.engine = UsageEngineHost()
        self.engine.attach(model: self)
    }

    func start() {
        retireLegacyAgentIfNeeded()
        engine.start()
    }

    /// Stops metering and waits for it. Reached from termination, which is the
    /// only thing that ends a run.
    func stop() async {
        await engine.stop()
    }

    /// Undoes the LaunchAgent an older install registered, once.
    private func retireLegacyAgentIfNeeded() {
        let outcome = LegacyAgentRetirement.run(
            alreadyRan: preferences.retiredServerAgent,
            loginItem: loginItem
        ) { [self] in
            preferences.retiredServerAgent = true
            savePreferences()
        }
        guard !outcome.retired.isEmpty else { return }
        sissyLog(
            "sissy: retired \(outcome.retired.joined(separator: ", "))"
                + (outcome.claimedLoginItem ? "; Sissy now opens at login in its place" : ""))
    }

    func savePreferences() {
        preferences.save(to: supportDirectory)
    }

    // MARK: Menu snapshots

    struct MenuSnapshot {
        let header: HeaderSnapshot
        let statusIcon: StatusIconSnapshot
    }

    struct HeaderSnapshot: Equatable {
        /// Carried as the pose rather than an asset name so the panel can
        /// cross-fade between the two, which needs both of them at once.
        let isAsleep: Bool
        let title: String
        /// The header's second line. nil hands the line back to the date.
        let subtitle: String?

        /// Sissy is awake exactly when there is a reading to show. In one
        /// process there is no link to lose, so the only way to have nothing
        /// is to have read nothing yet — and the subtitle then has to say
        /// which nothing, because "still looking", "nothing to find" and
        /// "found it, the day is empty" are the same blank panel otherwise.
        /// The third is the common one first thing in the morning, and the
        /// only one of the three that is not a fault.
        static func make(hasFrame: Bool, isWarm: Bool, filesWatched: Int) -> Self {
            guard !hasFrame else {
                return Self(isAsleep: false, title: "Sissy", subtitle: nil)
            }
            guard isWarm else {
                return Self(
                    isAsleep: true,
                    title: "Sissy is waking up",
                    subtitle: "Reading your session logs"
                )
            }
            return Self(
                isAsleep: true,
                title: "Sissy is sleeping",
                subtitle: filesWatched == 0 ? "No session logs found" : "Nothing spent yet today"
            )
        }
    }

    /// The glyph is fixed and drawn at full opacity, so all the menu bar icon
    /// reports is whether Sissy is awake: the eye is shut while nothing is
    /// reaching the app.
    struct StatusIconSnapshot {
        let isAsleep: Bool
    }

    /// A frame together with when it landed.
    struct LiveFrame {
        let frame: FrameData
        let at: Date
    }

    /// Sissy's one resting asset, template-rendered by the catalogue so every
    /// surface tints it for its own context.
    static let sissyAssetName = "SissyMenuBarTemplate"

    /// The same silhouette with its eye shut. Both the menu bar and the
    /// panel's header rest on this one while nothing is reaching the app.
    static let sissySleepingAssetName = "SissyMenuBarSleepingTemplate"

    var menuSnapshot: MenuSnapshot {
        let header = HeaderSnapshot.make(
            hasFrame: currentFrame != nil,
            isWarm: engine.isWarm,
            filesWatched: engine.filesWatched
        )
        return MenuSnapshot(header: header, statusIcon: StatusIconSnapshot(isAsleep: header.isAsleep))
    }

    // MARK: Menu actions

    func setClaudeLimits(_ enabled: Bool) {
        engine.setClaudeLimits(enabled)
    }

    // MARK: Keep awake

    /// A mode the app has asked for and the engine has not answered yet.
    ///
    /// The engine re-emits on every change, but frames also arrive on their
    /// own every few hundred milliseconds while an agent is working — which
    /// is exactly when this control gets used. Retiring the request on the
    /// next frame rather than on the *answering* one would flash the old mode
    /// back for a moment, so the mode is what was asked for until a frame
    /// agrees with it.
    private struct PendingKeepAwake {
        let mode: KeepAwakeMode
        let askedAt: Date
    }

    private var pendingKeepAwake: PendingKeepAwake?

    /// How long an unanswered request keeps showing. Past it the engine's own
    /// answer wins, so a request power management refused stops misreporting
    /// the Mac.
    private static let keepAwakeAckWindow: TimeInterval = 5

    /// The keep-awake state as the panel should draw it.
    var keepAwake: KeepAwakeState {
        let reported = currentFrame?.keepAwake ?? .off
        guard let pending = pendingKeepAwake,
            reported.mode != pending.mode,
            Date().timeIntervalSince(pending.askedAt) < Self.keepAwakeAckWindow
        else { return reported }
        return KeepAwakeState(
            mode: pending.mode, active: reported.active, since: reported.since)
    }

    func setKeepAwake(_ mode: KeepAwakeMode) {
        guard mode != keepAwake.mode else { return }
        pendingKeepAwake = PendingKeepAwake(mode: mode, askedAt: Date())
        engine.setKeepAwake(mode: mode)
    }

    /// Where the engine's answer lands. Both fields move together so an
    /// arriving frame can retire a keep-awake request in the same step — but
    /// only the frame that actually carries the answer.
    func applyFrame(_ frame: FrameData) {
        if let pending = pendingKeepAwake, frame.keepAwake.mode == pending.mode {
            pendingKeepAwake = nil
        }
        currentFrame = frame
        lastFrameAt = Date()
    }

    func setSissyMotion(_ enabled: Bool) {
        guard enabled != preferences.sissyMotion else { return }
        preferences.sissyMotion = enabled
        savePreferences()
    }

    /// Registers or removes the app's own login item. Failures are the
    /// user's to see rather than the caller's to handle: the switch has no
    /// second way to get the app opened at login.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
        } catch {
            let verb = enabled ? "Enable" : "Disable"
            Task { await showError(title: "\(verb) at login failed", message: error.localizedDescription) }
        }
    }

    /// Forgets everything the archive kept. Nothing else in Sissy deletes a
    /// user's data, so it is reachable only from Settings and only behind a
    /// confirmation.
    func deleteUsageHistory() {
        engine.deleteUsageHistory()
    }

    func openLogs() {
        let url = SissyPaths.logsDir
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    // MARK: Derived state

    /// The last frame for as long as it still describes a day something is
    /// counting, paired with when it landed.
    ///
    /// nil until the first frame lands, and nothing nils it afterwards: in
    /// one process the engine is either counting or the app is gone, so a
    /// timestamp on screen can never be ageing under something that stopped.
    ///
    var liveFrame: LiveFrame? {
        guard let currentFrame, let lastFrameAt else { return nil }
        return LiveFrame(frame: currentFrame, at: lastFrameAt)
    }

    private func showError(title: String, message: String) async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

}
