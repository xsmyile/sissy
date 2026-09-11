import AppKit
import Foundation
import Observation

/// Main runtime owner for the menubar app. UI surfaces observe this object,
/// while server/service/WebSocket adapters stay as leaf implementation
/// details behind it.
@MainActor
@Observable
final class SissyModel {
    var currentFrame: DisplayFrame? = nil
    var lastFrameAt: Date? = nil
    var preferences: Preferences
    var settingsTab: SettingsTab = .general
    private var serverToggleInFlight: Bool = false
    private var serverToggleLabel: String = ""
    private var serverToggleTarget: ServerToggleTarget?

    /// Optimistic target for an in-flight Server start/stop. `nil` when no
    /// toggle is pending, so the menu derives the row state from the live
    /// service/health status instead.
    private enum ServerToggleTarget {
        case on
        case off
    }

    private let supportDirectory: URL
    let serverService: ServerServiceController
    let serverHealth: ServerHealthMonitor
    let webSocketClient: WebSocketClient
    let loginItem: LoginItemController

    /// `serverService` is injected so a test can pin the LaunchAgent lookup to
    /// a plist that is not in the bundle. Left to its default it asks
    /// `SMAppService` about the real agent, and whether a dev daemon happens
    /// to be registered on the machine would decide what the model reports.
    /// `loginItem` is injected for the same reason, and `supportDirectory`
    /// for the other half of that problem: `xcodebuild test` launches the real
    /// app host, which builds this model against the machine's own install, so
    /// a test covering a path that persists preferences needs somewhere else
    /// to write.
    init(
        serverService: ServerServiceController = ServerServiceController(),
        loginItem: LoginItemController = LoginItemController(),
        supportDirectory: URL = Preferences.appSupportDir()
    ) {
        self.supportDirectory = supportDirectory
        self.preferences = .load(from: supportDirectory)
        self.serverService = serverService
        self.loginItem = loginItem
        self.webSocketClient = WebSocketClient()
        // The monitor must always read the CURRENT preferences, not a
        // snapshot from app launch. A `var prefsRef` mutated after init
        // tripped Swift 6's "mutated after capture by sendable closure"
        // diagnostic; an explicit weak-box holds the back-reference
        // safely and the closure stays MainActor-isolated through
        // ServerHealthMonitor's @MainActor prefsProvider type.
        let holder = SissyModelWeakHolder()
        self.serverHealth = ServerHealthMonitor(prefsProvider: { holder.preferences() })
        holder.model = self
        self.webSocketClient.attach(model: self)
    }

    func start() {
        migrateServerPortIfNeeded()
        webSocketClient.start()
        serverHealth.start()
    }

    /// Applies the one-shot move off the previous default port, before the
    /// client and the health monitor read a port for the first time.
    ///
    /// The rewrite alone would leave the app talking to a port nothing is
    /// bound to: the running daemon reads `server.json` only at boot, so it
    /// stays on the old one until launchd starts it again — the next login,
    /// or never, from the user's side. Restarting the agent is what closes
    /// that gap. Only an `.enabled` agent is touched: one waiting for the
    /// user's approval in System Settings cannot be registered again, and
    /// unregistering it would turn the Server off to fix a port.
    func migrateServerPortIfNeeded() {
        guard preferences.migrateLegacyServerPort() else { return }
        let port = preferences.serverPort
        savePreferences()
        Task { [weak self] in
            guard let self else { return }
            await serverService.refresh()
            guard serverService.status == .enabled else { return }
            do {
                try await serverService.stop()
                try await serverService.start {
                    await self.serverHealth.refreshNow().isReachable
                }
            } catch {
                await showError(
                    title: "Server restart failed",
                    message:
                        "Sissy moved its daemon to port \(port) but could not restart it: "
                        + "\(error.localizedDescription). Switch Server off and on again "
                        + "from the menu bar to finish the move."
                )
            }
            await serverHealth.refreshNow()
            webSocketClient.reconnect()
        }
    }

    func savePreferences() {
        preferences.save(to: supportDirectory)
        preferences.writeServerConfig(to: supportDirectory)
    }

    func ensureAuthToken() {
        if preferences.authToken.isEmpty {
            preferences.authToken = Preferences.makeSecret()
        }
    }

    // MARK: Menu snapshots

    struct MenuSnapshot {
        let header: HeaderSnapshot
        let statusIcon: StatusIconSnapshot
        let server: ServerItemSnapshot
    }

    struct HeaderSnapshot {
        /// Carried as the pose rather than an asset name so the panel can
        /// cross-fade between the two, which needs both of them at once.
        let isAsleep: Bool
        let title: String
        /// The header's second line. nil hands the line back to the date.
        let subtitle: String?
    }

    /// The glyph is fixed and drawn at full opacity, so all the menu bar icon
    /// reports is whether Sissy is awake: the eye is shut while nothing is
    /// reaching the app.
    struct StatusIconSnapshot {
        let isAsleep: Bool
    }

    struct ServerItemSnapshot {
        let title: String
        let subtitle: String
        let isEnabled: Bool
        let isOn: Bool
        let requiresApproval: Bool
    }

    /// A frame together with when it landed.
    struct LiveFrame {
        let frame: DisplayFrame
        let at: Date
    }

    /// Sissy's one resting asset, template-rendered by the catalogue so every
    /// surface tints it for its own context.
    static let sissyAssetName = "SissyMenuBarTemplate"

    /// The same silhouette with its eye shut. Both the menu bar and the
    /// panel's header rest on this one while nothing is reaching the app.
    static let sissySleepingAssetName = "SissyMenuBarSleepingTemplate"

    var menuSnapshot: MenuSnapshot {
        let linkUp = webSocketClient.isConnected && currentFrame != nil
        let droppedAfterConnect = webSocketClient.hasEverConnected && !webSocketClient.isConnected
        let healthOffline = !serverHealth.status.isReachable
        let offline = droppedAfterConnect || healthOffline
        let server = serverItemSnapshot

        return MenuSnapshot(
            header: HeaderSnapshot(
                isAsleep: offline,
                title: headerTitle(isAsleep: offline, linkUp: linkUp),
                subtitle: headerSubtitle(isAsleep: offline, serverIsOn: server.isOn)
            ),
            statusIcon: StatusIconSnapshot(isAsleep: offline),
            server: server
        )
    }

    // MARK: Menu actions

    var serverIsBusy: Bool { serverToggleInFlight || serverService.isTransitioning }

    func toggleServer() {
        if serverToggleInFlight || serverService.isTransitioning { return }
        if serverService.requiresApproval && serverService.isAvailable {
            serverService.openLoginItemsSettings()
            return
        }
        if !serverService.isAvailable { return }

        let shouldStop = serverService.isRegistered || serverHealth.status.isReachable
        serverToggleInFlight = true
        serverToggleLabel = shouldStop ? "Stopping..." : "Starting..."
        serverToggleTarget = shouldStop ? .off : .on

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.serverToggleInFlight = false
                self.serverToggleLabel = ""
                self.serverToggleTarget = nil
            }
            do {
                if shouldStop {
                    try await serverService.stop {
                        let status = await self.serverHealth.refreshNow()
                        return !status.isReachable
                    }
                    await serverHealth.refreshNow()
                    webSocketClient.reconnect()
                } else {
                    let bookmark = serverService.errorLogBookmark()
                    let port = preferences.serverPort
                    ensureAuthToken()
                    savePreferences()
                    try await serverService.start {
                        let status = await self.serverHealth.refreshNow()
                        return status.isReachable
                    }
                    let status = await serverHealth.refreshNow()
                    webSocketClient.reconnect()
                    if !status.isReachable,
                        let hint = serverService.startFailureHint(since: bookmark, port: port)
                    {
                        await showError(title: "Start failed", message: hint)
                    }
                }
            } catch {
                let verb = shouldStop ? "Stop" : "Start"
                await showError(title: "\(verb) failed", message: error.localizedDescription)
            }
        }
    }

    func selectMetric(_ metric: Preferences.PrimaryMetric) {
        guard metric != preferences.primaryMetric else { return }
        preferences.primaryMetric = metric
        savePreferences()
        webSocketClient.pushSettings()
    }

    func setClaudeLimits(_ enabled: Bool) {
        guard enabled != preferences.claudeLimits else { return }
        preferences.claudeLimits = enabled
        savePreferences()
        webSocketClient.setClaudeLimits(enabled)
    }

    // MARK: Keep awake

    /// A mode the app has asked for and the daemon has not confirmed yet.
    ///
    /// The daemon rebroadcasts on every change, but frames also arrive on
    /// their own every few hundred milliseconds while an agent is working —
    /// which is exactly when this control gets used. Retiring the request on
    /// the next frame rather than on the *answering* one would flash the old
    /// mode back for a moment, so the mode is what was asked for until a frame
    /// agrees with it.
    private struct PendingKeepAwake {
        let mode: KeepAwakeMode
        let askedAt: Date
    }

    private var pendingKeepAwake: PendingKeepAwake?

    /// How long an unanswered request keeps showing. Past it the daemon's own
    /// answer wins, so a request that never arrived — a dropped socket, a
    /// daemon too old to know the message — stops misreporting the Mac.
    private static let keepAwakeAckWindow: TimeInterval = 5

    /// The keep-awake state as the panel should draw it.
    ///
    /// Gated on the server for the same reason the panel's numbers are: the
    /// assertion belongs to the daemon, so once that is gone nothing is being
    /// held whatever the last frame said.
    var keepAwake: KeepAwakeState {
        guard menuSnapshot.server.isOn else { return .off }
        let reported = currentFrame?.keepAwake ?? .off
        guard let pending = pendingKeepAwake,
            reported.mode != pending.mode,
            Date().timeIntervalSince(pending.askedAt) < Self.keepAwakeAckWindow
        else { return reported }
        return KeepAwakeState(mode: pending.mode, active: reported.active)
    }

    /// The daemon is the only thing that can hold the assertion, so the
    /// control is dead while it is not there to ask.
    var canKeepAwake: Bool { menuSnapshot.server.isOn && webSocketClient.isConnected }

    func setKeepAwake(_ mode: KeepAwakeMode) {
        guard mode != keepAwake.mode else { return }
        pendingKeepAwake = PendingKeepAwake(mode: mode, askedAt: Date())
        webSocketClient.setKeepAwake(mode: mode)
    }

    /// Where the daemon's answer lands. Both fields move together so an
    /// arriving frame can retire a keep-awake request in the same step — but
    /// only the frame that actually carries the answer.
    func applyFrame(_ frame: DisplayFrame) {
        if let pending = pendingKeepAwake, frame.keepAwake.mode == pending.mode {
            pendingKeepAwake = nil
        }
        currentFrame = frame
        lastFrameAt = frame.builtAt ?? Date()
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

    /// Drives the daemon to a requested state rather than flipping whatever it
    /// is in. A `Toggle` hands SwiftUI's new value to its binding, and a
    /// binding that discards it and toggles instead only agrees with the
    /// switch while every `set` arrives exactly once and already negated —
    /// an invariant SwiftUI does not promise. `toggleServer` stays for the
    /// panel's power button, which really is a one-shot action.
    func setServer(running: Bool) {
        guard running != serverItemSnapshot.isOn else { return }
        toggleServer()
    }

    func openLogs() {
        let url = serverService.openableLogsURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    // MARK: Derived state

    /// The last frame for as long as it still describes a day something is
    /// counting, paired with when it landed.
    ///
    /// nil once the daemon is gone. The numbers then describe a day that
    /// stopped being counted, and the panel's footer keeps ageing a timestamp
    /// nothing will refresh — "updated 3h ago" under a stopped server reads as
    /// a live reading of an idle daemon rather than as no reading at all.
    ///
    /// Derived rather than cleared on disconnect. The gate is the same `isOn`
    /// the power button shows, which keeps the two from disagreeing and leaves
    /// a registered-but-restarting daemon its frame instead of blanking the
    /// panel on every launchd blip.
    var liveFrame: LiveFrame? {
        guard serverItemSnapshot.isOn, let currentFrame, let lastFrameAt else { return nil }
        return LiveFrame(frame: currentFrame, at: lastFrameAt)
    }

    private var serverItemSnapshot: ServerItemSnapshot {
        let busy = serverToggleInFlight || serverService.isTransitioning
        let serverIsOn =
            serverToggleTarget.map { $0 == .on }
            ?? (serverService.isRegistered || serverHealth.status.isReachable)

        let title: String
        let subtitle: String
        if !serverService.isAvailable {
            title = "Server unavailable"
            subtitle = "Service missing"
        } else if serverService.requiresApproval {
            title = "Open Login Items Settings..."
            subtitle = "Approval required"
        } else if serverToggleInFlight {
            title = serverToggleLabel.replacingOccurrences(of: "...", with: " Server...")
            subtitle = serverToggleLabel
        } else if serverService.isTransitioning {
            title = serverService.transitionLabel.replacingOccurrences(of: "...", with: " Server...")
            subtitle = serverService.transitionLabel
        } else {
            title = serverIsOn ? "Stop Server" : "Start Server"
            switch serverHealth.status {
            case .up:
                subtitle = "Running"
            case .down:
                subtitle = serverService.isRegistered ? "Starting" : "Stopped"
            case .usageReaderEmpty:
                subtitle = "No JSONL"
            case .unknown:
                subtitle = "Checking"
            }
        }

        return ServerItemSnapshot(
            title: title,
            subtitle: subtitle,
            isEnabled: serverService.isAvailable && !busy,
            isOn: serverIsOn,
            requiresApproval: serverService.requiresApproval
        )
    }

    /// The panel's own name while it has a live reading, and what is wrong
    /// when it does not. The two failure lines matter more than the healthy
    /// one: the panel's only control is the switch beside this text, and a
    /// header that stayed silent would leave the switch's meaning to
    /// guesswork.
    /// Says what Sissy's face already shows, so the two can't disagree:
    /// the eye is shut exactly when nothing is reaching the app.
    private func headerTitle(isAsleep: Bool, linkUp: Bool) -> String {
        if isAsleep { return "Sissy is sleeping" }
        if !linkUp { return "Looking for Sissy..." }
        return "Sissy"
    }

    /// Why Sissy is asleep, or nil while she is awake — the panel shows
    /// today's date in that case. `serverIsOn` is what separates "you turned
    /// it off" from "it should be running and isn't".
    private func headerSubtitle(isAsleep: Bool, serverIsOn: Bool) -> String? {
        guard isAsleep else { return nil }
        return serverIsOn ? "Waiting for the daemon" : "Server is off"
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

/// The daemon's broadcast frame, as `FrameDecoder` hands it to the app.
struct DisplayFrame: Codable, Equatable {
    var tokens: String
    var cost: String
    var burn: String
    var ts: Int
    var primary: String
    var primaryLabel: String
    /// Per-provider totals carried on the WS frame so the panel derives its
    /// total and its rows from the same payload. Empty when no provider has
    /// emitted yet, or when the daemon predates the field.
    var providers: [ProviderSlice]
    /// Yesterday's raw combined totals, for the day-over-day delta. nil until
    /// every active provider has a previous-day snapshot — the daemon omits
    /// both wire keys together in that window, and nil renders as "no
    /// comparison" rather than a 0% that was never measured.
    var prev: PrevTotals?
    /// The daemon's keep-awake mode and whether it is holding. Defaults to off
    /// rather than being optional: a daemon too old to send the key is one
    /// that holds nothing, which is what off means.
    var keepAwake: KeepAwakeState = .off

    struct ProviderSlice: Codable, Equatable, Identifiable {
        let id: String
        let tokens: Int
        let cost: Decimal
        /// Subscription windows the CLI reported, shortest first. Empty for a
        /// provider that publishes none, which is what puts the row back on
        /// its share-of-today bar.
        let windows: [UsageWindow]
        /// Vendor's own plan token, nil when the daemon reported none — an
        /// API-key user, a CLI too old to name it, or a daemon predating the
        /// field. `UsageFormat.plan(_:tier:)` turns it into the words on the
        /// row.
        let plan: String?
        /// Limit tier the plan is metered at, for the one vendor that names
        /// one. Never present without `plan`.
        let planTier: String?

        init(
            id: String,
            tokens: Int,
            cost: Decimal,
            windows: [UsageWindow] = [],
            plan: String? = nil,
            planTier: String? = nil
        ) {
            self.id = id
            self.tokens = tokens
            self.cost = cost
            self.windows = windows
            self.plan = plan
            self.planTier = plan == nil ? nil : planTier
        }
    }

    /// One rate-limit window as the vendor reported it. `minutes` is the
    /// identity: vendors do not agree on an ordering, so the label comes from
    /// the length and never from the position in the payload.
    struct UsageWindow: Codable, Equatable, Identifiable {
        let minutes: Int
        let usedPercent: Double
        let resetsAt: Date

        var id: Int { minutes }
    }

    struct PrevTotals: Codable, Equatable {
        let tokens: Int
        let cost: Decimal
    }

    /// When the daemon built this frame, from its own `ts`.
    ///
    /// The Hub replays its cached payload to every client that connects, and
    /// that payload keeps the timestamp of the emit it came from — so a
    /// reconnect to an idle daemon reports the age of the real last frame
    /// instead of the moment the socket happened to open. nil for a frame
    /// with no usable `ts`, which leaves the caller to fall back to now.
    var builtAt: Date? {
        ts > 0 ? Date(timeIntervalSince1970: TimeInterval(ts)) : nil
    }
}

/// Lets `SissyModel.init` hand `ServerHealthMonitor` a closure that reads
/// "current" preferences without needing the fully-initialized `self` at
/// capture time. The closure captures the holder; the holder's `model`
/// pointer is filled in once `init` is done. Marked `@unchecked Sendable`
/// only because Swift 6 can't see the `@MainActor` boundary on
/// `prefsProvider`; reads always happen on MainActor.
@MainActor
private final class SissyModelWeakHolder: @unchecked Sendable {
    weak var model: SissyModel?
    func preferences() -> Preferences {
        model?.preferences ?? Preferences()
    }
}
