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
    let updates: UpdateController

    /// `loginItem` is injected so a test can pin the lookup to a service that
    /// is definitely not registered, rather than letting whatever is on the
    /// machine decide what the model reports. `supportDirectory` is injected
    /// for the other half of that problem: `xcodebuild test` launches the
    /// real app host, which builds this model against the machine's own
    /// install, so a test covering a path that persists preferences needs
    /// somewhere else to write.
    init(
        loginItem: LoginItemController = LoginItemController(),
        updates: UpdateController = UpdateController(),
        supportDirectory: URL = Preferences.appSupportDir()
    ) {
        self.supportDirectory = supportDirectory
        self.preferences = .load(from: supportDirectory)
        self.loginItem = loginItem
        self.updates = updates
        self.engine = UsageEngineHost()
        self.engine.attach(model: self)
    }

    /// Brings the app up: the login item's state, the one-shot retirement of
    /// the legacy agent, metering, then the updater.
    ///
    /// The login item is read here rather than left to Settings because
    /// `LoginItemController` starts at `.notRegistered` and Settings' own
    /// refresh lands a frame after the switch is already on screen — long
    /// enough for a registered login item to draw as off and then animate on.
    /// The query costs 1–7 ms against launchd, measured, at a point where
    /// nothing is drawn yet. Settings keeps refreshing on appearance: only the
    /// system knows that the user has since undone it from Login Items.
    ///
    /// A copy that will not survive to the next login is logged here, because
    /// the one place it is shown is a Settings row nobody may open.
    func start() {
        loginItem.refresh()
        if loginItem.location.isTransient {
            sissyLog("sissy: running from a \(loginItem.location) copy; start at login is withheld")
        }
        retireLegacyAgentIfNeeded()
        engine.start()
        updates.start()
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
        ///
        /// The title is a sentence about what Sissy is doing in every case but
        /// one, where it degenerates to her name — which is the case the panel
        /// spends nearly all its time in. `holdingForAgents` fills it: the
        /// automatic mode holding the Mac is the only state where a sentence
        /// about the agents is true, because a manual hold is a switch the
        /// user threw and has nothing to do with them. The duration of the
        /// hold is not here; it belongs beside the reading's age, under this.
        static func make(
            hasFrame: Bool, isWarm: Bool, filesWatched: Int, isMetering: Bool = true,
            holdingForAgents: Bool = false
        ) -> Self {
            guard !hasFrame else {
                return Self(
                    isAsleep: false,
                    title: holdingForAgents ? "Sissy is up with the agents" : "Sissy",
                    subtitle: nil
                )
            }
            guard isWarm else {
                return Self(
                    isAsleep: true,
                    title: "Sissy is waking up",
                    subtitle: "Reading your session logs"
                )
            }
            // Asked behind the warmth and in front of the count, because a run
            // with nothing switched on is warm with nothing to watch — and
            // "no session logs found" sends someone looking at a log tree for
            // a provider Sissy was told not to read.
            guard isMetering else {
                return Self(
                    isAsleep: true,
                    title: "Sissy is sleeping",
                    subtitle: "No provider switched on"
                )
            }
            return Self(
                isAsleep: true,
                title: "Sissy is sleeping",
                subtitle: filesWatched == 0 ? "No session logs found" : "Nothing spent yet today"
            )
        }
    }

    /// The glyph is fixed and drawn at full opacity, so the menu bar icon
    /// reports two things and both of them with the eye: it is shut while
    /// nothing is reaching the app, and lit while the Mac is being held awake.
    ///
    /// The hold is read off `active` rather than off the mode, the way the
    /// status menu's own line is: a mode that is armed and holding nothing has
    /// left the Mac free to sleep, and an icon claiming otherwise is the
    /// battery complaint this was meant to answer.
    struct StatusIconSnapshot {
        let isAsleep: Bool
        let isHolding: Bool
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
        let hold = keepAwake
        let header = HeaderSnapshot.make(
            hasFrame: currentFrame != nil,
            isWarm: engine.isWarm,
            filesWatched: engine.filesWatched,
            isMetering: engine.isMetering,
            holdingForAgents: hold.mode == .auto && hold.active
        )
        return MenuSnapshot(
            header: header,
            statusIcon: StatusIconSnapshot(isAsleep: header.isAsleep, isHolding: hold.active)
        )
    }

    // MARK: Menu actions

    func refreshProvider(_ id: String) {
        engine.refreshProvider(id)
    }

    func refreshForge(_ id: String) {
        engine.refreshForge(id)
    }

    func refreshAll() {
        engine.refreshAll()
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
    ///
    /// Falls back to the mode the engine booted with rather than to `off`,
    /// because the engine takes its hold before the readers have produced a
    /// frame to report it in. `active` stays false across that window — the
    /// hold is the engine's to confirm — but the mode is a setting the app can
    /// read straight from `server.json`, and getting it wrong there costs more
    /// than a cold tint: see `UsageEngineHost.keepAwakeMode`.
    var keepAwake: KeepAwakeState {
        let reported =
            currentFrame?.keepAwake ?? KeepAwakeState(mode: engine.keepAwakeMode, active: false)
        guard let pending = pendingKeepAwake,
            reported.mode != pending.mode,
            Date().timeIntervalSince(pending.askedAt) < Self.keepAwakeAckWindow
        else { return reported }
        return KeepAwakeState(
            mode: pending.mode,
            active: reported.active,
            since: reported.since,
            coversScreen: reported.coversScreen)
    }

    /// Which armed mode the panel's button puts the switch back into.
    ///
    /// The button toggles and there are three modes, so the one it returns to
    /// is the one the user last had — chosen from the menu, or carried across
    /// a relaunch by the first frame that reports an armed mode. It is UI
    /// state and not a setting: the mode itself lives in `server.json`, and a
    /// second copy of it here could disagree with the file the assertions are
    /// taken from.
    private(set) var preferredKeepAwakeMode: KeepAwakeMode = .on

    func setAgentHooks(_ enabled: Bool) {
        engine.setAgentHooks(enabled)
    }

    func setKeepScreenAwake(_ enabled: Bool) {
        engine.setKeepScreenAwake(enabled)
    }

    func setKeepAwake(_ mode: KeepAwakeMode) {
        guard mode != keepAwake.mode else { return }
        if mode != .off { preferredKeepAwakeMode = mode }
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
        if frame.keepAwake.mode != .off { preferredKeepAwakeMode = frame.keepAwake.mode }
        currentFrame = frame
        lastFrameAt = Date()
    }

    /// Drops the reading on screen, for a change that invalidates it rather
    /// than updating it. Switching a provider off is the one: its tokens are
    /// still in the last frame, and a panel that goes on showing them until
    /// the next event lands reads as a switch that did nothing.
    func clearFrame() {
        currentFrame = nil
        lastFrameAt = nil
    }

    func setSissyMotion(_ enabled: Bool) {
        guard enabled != preferences.sissyMotion else { return }
        preferences.sissyMotion = enabled
        savePreferences()
    }

    /// Which window the panel's headline is over. Persisted rather than held
    /// for the life of the popover: the panel's page selection is dropped on
    /// close because it is navigation, where this is a reading the user chose.
    func setUsagePeriod(_ period: UsagePeriod) {
        guard period != preferences.usagePeriod else { return }
        preferences.usagePeriod = period
        savePreferences()
    }

    /// Which end of a rate-limit window its gauge prints. A wording, so it
    /// reaches the panel through `UsagePanelSnapshot` like every other number
    /// on screen and nothing about the readings themselves moves.
    func setLimitsReading(_ reading: LimitsReading) {
        guard reading != preferences.limitsReading else { return }
        preferences.limitsReading = reading
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

    /// Asks where the archive should go and writes it there as CSV.
    ///
    /// A folder rather than a file, because the export is one CSV per provider
    /// plus a combined one — the split Numbers turns back into a sheet each on
    /// import, which is why this is not a workbook and not a dependency.
    ///
    /// App-modal rather than a sheet on Settings: the button is only reachable
    /// with that window already open and the app already active, and a sheet
    /// would need the window handed down through the view to attach to.
    func exportUsageHistory() {
        let panel = NSSavePanel()
        panel.title = "Export usage history"
        panel.prompt = "Export"
        panel.nameFieldLabel = "Folder:"
        panel.nameFieldStringValue =
            "Sissy usage \(UsageReaderShared.dayFormatter.string(from: Date()))"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task { await writeUsageHistory(to: directory) }
    }

    private func writeUsageHistory(to directory: URL) async {
        do {
            let days = try await engine.exportUsageHistory(to: directory)
            guard days > 0 else {
                await showError(
                    title: "There is no usage history to export",
                    message: "Sissy records a day once it has counted something in it. "
                        + "Nothing was written."
                )
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } catch let failure as UsageEngineHost.ExportFailure {
            await showError(title: "Export failed", message: failure.localizedDescription)
        } catch {
            await showError(
                title: "Export failed",
                message: "Sissy could not write to "
                    + "\((directory.path as NSString).abbreviatingWithTildeInPath). "
                    + error.localizedDescription
            )
        }
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
