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
    var preferences: Preferences = .load()
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

    let serverService: ServerServiceController
    let serverHealth: ServerHealthMonitor
    let webSocketClient: WebSocketClient

    /// `serverService` is injected so a test can pin the LaunchAgent lookup to
    /// a plist that is not in the bundle. Left to its default it asks
    /// `SMAppService` about the real agent, and whether a dev daemon happens
    /// to be registered on the machine would decide what the model reports.
    init(serverService: ServerServiceController = ServerServiceController()) {
        self.serverService = serverService
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
        webSocketClient.start()
        serverHealth.start()
    }

    func savePreferences() {
        preferences.save()
        preferences.writeServerConfig()
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
        let imageName: String
        let title: String
        let subtitle: String?
        let isDimmed: Bool
    }

    /// Only the opacity varies now that the glyph is fixed: a dimmed mascot is
    /// how the menu bar reports that nothing is reaching it.
    struct StatusIconSnapshot {
        let alpha: CGFloat
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

    /// Sissy's one mascot asset, template-rendered by the catalogue so every
    /// surface tints it for its own context.
    static let mascotAssetName = "SissyMenuBarTemplate"

    var menuSnapshot: MenuSnapshot {
        let linkUp = webSocketClient.isConnected && currentFrame != nil
        let droppedAfterConnect = webSocketClient.hasEverConnected && !webSocketClient.isConnected
        let healthOffline = !serverHealth.status.isReachable
        let offline = droppedAfterConnect || healthOffline
        let server = serverItemSnapshot

        return MenuSnapshot(
            header: HeaderSnapshot(
                imageName: Self.mascotAssetName,
                title: headerTitle(linkUp: linkUp, serverIsOn: server.isOn),
                subtitle: headerSubtitle(linkUp: linkUp, serverIsOn: server.isOn),
                isDimmed: !linkUp
            ),
            statusIcon: StatusIconSnapshot(alpha: offline ? 0.4 : 1.0),
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
    private func headerTitle(linkUp: Bool, serverIsOn: Bool) -> String {
        if !serverIsOn { return "Server is off" }
        if !linkUp { return "Looking for Sissy..." }
        return "Sissy"
    }

    private func headerSubtitle(linkUp: Bool, serverIsOn: Bool) -> String? {
        if !serverIsOn { return "Nothing is being counted" }
        if !linkUp { return "Waiting for the daemon" }
        guard let frame = currentFrame else { return nil }
        // Single source of truth: when the daemon ships the providers array
        // (current build), sum it through the same formatter the Breakdown
        // submenu rows use so the header and the rows match to the penny.
        // Fallback path covers a newer-app/older-daemon dev rebuild skew and
        // the cold-start window before the first provider has emitted.
        if !frame.providers.isEmpty {
            return UsageFormat.headerSubtitle(providers: frame.providers, burn: frame.burn)
        }
        var parts: [String] = []
        if frame.tokens != "..." { parts.append("\(frame.tokens) tok") }
        if frame.cost != "..." { parts.append("$\(frame.cost)") }
        if frame.burn != "..." { parts.append("\(frame.burn)/h") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
    /// Per-provider totals carried on the WS frame so the menubar can derive
    /// the header subtitle and the panel's rows from the same payload. Empty
    /// when no provider has emitted yet (or daemon predates the field) —
    /// `headerSubtitle` falls back to the daemon-formatted scalars.
    var providers: [ProviderSlice]
    /// Yesterday's raw combined totals, for the day-over-day delta. nil until
    /// every active provider has a previous-day snapshot — the daemon omits
    /// both wire keys together in that window, and nil renders as "no
    /// comparison" rather than a 0% that was never measured.
    var prev: PrevTotals?

    struct ProviderSlice: Codable, Equatable, Identifiable {
        let id: String
        let tokens: Int
        let cost: Decimal
        /// Subscription windows the CLI reported, shortest first. Empty for a
        /// provider that publishes none, which is what puts the row back on
        /// its share-of-today bar.
        let windows: [UsageWindow]

        init(id: String, tokens: Int, cost: Decimal, windows: [UsageWindow] = []) {
            self.id = id
            self.tokens = tokens
            self.cost = cost
            self.windows = windows
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
