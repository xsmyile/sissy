import AppKit
import Combine
import Foundation
import SwiftUI

/// Main runtime owner for the menubar app. UI surfaces observe this object,
/// while server/service/WebSocket adapters stay as leaf implementation
/// details behind it.
@MainActor
final class SissyModel: ObservableObject {
    @Published var currentFrame: DisplayFrame? = nil
    @Published var preferences: Preferences = .load()
    /// Optimistic mirror of the daemon's mascot pin. nil = Auto (computed
    /// state). The daemon is authoritative — this is just what the menu
    /// most recently asked for, used to flag the active row with a checkmark
    /// without waiting for the next frame to confirm.
    @Published var pinnedMascot: String? = nil
    /// Mood line picked at the last mascot state-change. Both the menubar
    /// header and the mood pop-up read this so they show the same catchphrase
    /// for the same transition (the pool offers 4 lines per state — without
    /// this, each surface would roll independently and disagree). Stays nil
    /// until the first transition is observed; the header then falls back to
    /// `StateDescriptor.voice(for:)` for its canonical line.
    @Published var currentMoodPhrase: String? = nil
    /// Celebration line for the most recent milestone crossing. Set by the
    /// notifier alongside the pop-up so the menubar header can mirror what
    /// the user just saw flash. Held verbatim (full sentence — no "Sissy is"
    /// prefix at render) and auto-cleared after the pop-up dismisses so the
    /// header returns to the canonical mood line.
    @Published var currentMilestonePhrase: String? = nil
    @Published private var serverToggleInFlight: Bool = false
    @Published private var serverToggleLabel: String = ""
    @Published private var serverToggleTargetIsOn: Bool?

    let serverService: ServerServiceController
    let serverHealth: ServerHealthMonitor
    let webSocketClient: WebSocketClient

    private var cancellables: Set<AnyCancellable> = []

    init() {
        self.serverService = ServerServiceController()
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
        bridgeLeafObjectChanges()
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
        let primaryMetric: Preferences.PrimaryMetric
        let milestoneFrequency: Preferences.MilestoneFrequency
        let mascotLabel: String
        let pinnedMascot: String?
        let canPickMascot: Bool
        let notifyOnMascotChange: Bool
        /// Hide the "Metric" submenu when no firmware companion is attached.
        /// The setting only affects the OLED's primary-slot render — the
        /// menubar header already prints tokens · cost · burn unconditionally,
        /// so without a device the row is a dead option. Pre-first-frame this
        /// stays true so the row doesn't flicker hidden→visible on connect.
        let showMetric: Bool
        /// Per-provider usage rows for the "Breakdown" submenu. Empty or
        /// single-entry lists are suppressed by the menu builder — only
        /// shown when at least two providers are active so a single-CLI
        /// install never sees a useless one-row submenu.
        let providerBreakdown: [DisplayFrame.ProviderSlice]
    }

    struct HeaderSnapshot {
        let imageName: String
        let title: String
        let subtitle: String?
        let isDimmed: Bool
    }

    struct StatusIconSnapshot {
        let imageName: String
        let alpha: CGFloat
    }

    struct ServerItemSnapshot {
        let title: String
        let subtitle: String
        let isEnabled: Bool
    }

    var menuSnapshot: MenuSnapshot {
        let linkUp = webSocketClient.isConnected && currentFrame != nil
        let spriteState = pinnedMascot ?? currentFrame?.state ?? "sleep"
        let droppedAfterConnect = webSocketClient.hasEverConnected && !webSocketClient.isConnected
        let healthOffline = !serverHealth.status.isReachable
        let offline = droppedAfterConnect || healthOffline
        let iconState = offline ? nil : (pinnedMascot ?? currentFrame?.state)

        return MenuSnapshot(
            header: HeaderSnapshot(
                imageName: StateDescriptor.mascotImageName(for: spriteState),
                title: headerTitle(linkUp: linkUp),
                subtitle: headerSubtitle(linkUp: linkUp),
                isDimmed: !linkUp
            ),
            statusIcon: StatusIconSnapshot(
                imageName: StateDescriptor.mascotImageName(for: iconState),
                alpha: offline ? 0.4 : 1.0
            ),
            server: serverItemSnapshot,
            primaryMetric: preferences.primaryMetric,
            milestoneFrequency: preferences.milestoneFrequency,
            mascotLabel: currentMascotLabel,
            pinnedMascot: pinnedMascot,
            canPickMascot: webSocketClient.isConnected,
            notifyOnMascotChange: preferences.notifyOnMascotChange,
            showMetric: currentFrame?.devicePresent ?? true,
            providerBreakdown: linkUp ? (currentFrame?.providers ?? []) : []
        )
    }

    // MARK: Menu actions

    func toggleServerFromMenu() {
        if serverToggleInFlight || serverService.isTransitioning { return }
        if serverService.requiresApproval && serverService.isAvailable {
            serverService.openLoginItemsSettings()
            return
        }
        if !serverService.isAvailable { return }

        let shouldStop = serverService.isRegistered || serverHealth.status.isReachable
        serverToggleInFlight = true
        serverToggleLabel = shouldStop ? "Stopping..." : "Starting..."
        serverToggleTargetIsOn = !shouldStop

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.serverToggleInFlight = false
                self.serverToggleLabel = ""
                self.serverToggleTargetIsOn = nil
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

    var pairingServerActionTitle: String {
        if serverToggleInFlight {
            return serverToggleLabel.replacingOccurrences(of: "...", with: " Server...")
        }
        if serverService.isTransitioning {
            return serverService.transitionLabel.replacingOccurrences(of: "...", with: " Server...")
        }
        if serverService.requiresApproval {
            return "Open Login Items Settings"
        }
        if serverService.isRegistered || serverHealth.status.isReachable {
            return "Restart Server"
        }
        return "Start Server"
    }

    var canRunPairingServerAction: Bool {
        serverService.isAvailable && !serverToggleInFlight && !serverService.isTransitioning
    }

    var pairingServerStatusText: String {
        if !serverService.isAvailable {
            return "The bundled server is unavailable."
        }
        if serverService.requiresApproval {
            return "macOS needs Login Items approval before the server can run."
        }
        if serverToggleInFlight || serverService.isTransitioning {
            return "Applying the server configuration."
        }
        switch serverHealth.status {
        case .up, .usageReaderEmpty:
            return "The server is running."
        case .down:
            return "The server is stopped."
        case .unknown:
            return "Checking the server."
        }
    }

    func applyPairingServerConfiguration() {
        if serverToggleInFlight || serverService.isTransitioning { return }
        if serverService.requiresApproval && serverService.isAvailable {
            serverService.openLoginItemsSettings()
            return
        }
        if !serverService.isAvailable { return }

        let shouldRestart = serverService.isRegistered || serverHealth.status.isReachable
        serverToggleInFlight = true
        serverToggleLabel = shouldRestart ? "Restarting..." : "Starting..."
        serverToggleTargetIsOn = true

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.serverToggleInFlight = false
                self.serverToggleLabel = ""
                self.serverToggleTargetIsOn = nil
            }

            let bookmark = serverService.errorLogBookmark()
            let port = preferences.serverPort
            do {
                ensureAuthToken()
                savePreferences()
                if shouldRestart {
                    try await serverService.stop {
                        let status = await self.serverHealth.refreshNow()
                        return !status.isReachable
                    }
                    await serverHealth.refreshNow()
                }
                try await serverService.start {
                    let status = await self.serverHealth.refreshNow()
                    return status.isReachable
                }
                let status = await serverHealth.refreshNow()
                webSocketClient.reconnect()
                if !status.isReachable,
                    let hint = serverService.startFailureHint(since: bookmark, port: port)
                {
                    await showError(title: "Server update failed", message: hint)
                }
            } catch {
                let verb = shouldRestart ? "Restart" : "Start"
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

    func selectMilestoneFrequency(_ preset: Preferences.MilestoneFrequency) {
        guard preset != preferences.milestoneFrequency else { return }
        preferences.milestoneFrequency = preset
        savePreferences()
        webSocketClient.setMilestoneFrequency(preset.rawValue)
    }

    func pinMascot(_ wire: String) {
        pinnedMascot = wire
        webSocketClient.setMascotPin(state: wire)
    }

    func clearMascotPin() {
        pinnedMascot = nil
        webSocketClient.setMascotPin(state: nil)
    }

    func toggleNotifications() {
        preferences.notifyOnMascotChange.toggle()
        savePreferences()
    }

    func openLogs() {
        let url = serverService.openableLogsURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    // MARK: Derived state

    private var serverItemSnapshot: ServerItemSnapshot {
        let busy = serverToggleInFlight || serverService.isTransitioning
        let serverIsOn =
            serverToggleTargetIsOn
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
            isEnabled: serverService.isAvailable && !busy
        )
    }

    private var currentMascotLabel: String {
        guard let wire = pinnedMascot else { return "Auto" }
        return Self.mascotStates.first(where: { $0.wire == wire })?.label ?? "Auto"
    }

    private func headerTitle(linkUp: Bool) -> String {
        if !linkUp { return "Looking for Sissy..." }
        let state = pinnedMascot ?? currentFrame?.state
        if let phrase = currentMilestonePhrase, pinnedMascot == nil {
            return phrase
        }
        if let phrase = currentMoodPhrase, pinnedMascot == nil {
            return StateDescriptor.moodHeadline(voice: phrase)
        }
        return StateDescriptor.moodHeadline(voice: StateDescriptor.voice(for: state))
    }

    private func headerSubtitle(linkUp: Bool) -> String? {
        if !linkUp { return "Waiting for the daemon" }
        guard let frame = currentFrame else { return nil }
        // Single source of truth: when the daemon ships the providers array
        // (current build), sum it through the same formatter the Breakdown
        // submenu rows use so the header and the rows match to the penny.
        // Fallback path covers a newer-app/older-daemon dev rebuild skew and
        // the cold-start window before the first provider has emitted.
        if !frame.providers.isEmpty {
            return StatusItemController.formatHeaderSubtitle(
                providers: frame.providers,
                burn: frame.burn
            )
        }
        var parts: [String] = []
        if frame.tokens != "..." { parts.append("\(frame.tokens) tok") }
        if frame.cost != "..." { parts.append("$\(frame.cost)") }
        if frame.burn != "..." { parts.append("\(frame.burn)/h") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func bridgeLeafObjectChanges() {
        Publishers.MergeMany([
            serverService.objectWillChange.eraseToVoid(),
            serverHealth.objectWillChange.eraseToVoid(),
            webSocketClient.objectWillChange.eraseToVoid(),
        ])
        .sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &cancellables)
    }

    private func showError(title: String, message: String) async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    static let mascotStates: [(label: String, wire: String)] = [
        ("Sleep", "sleep"),
        ("Think", "think"),
        ("Code", "code"),
        ("Trend", "trend"),
        ("Glow", "glow"),
        ("Angry", "angry"),
    ]
}

/// The frame as it lands on the device's OLED.
struct DisplayFrame: Codable, Equatable {
    var tokens: String
    var cost: String
    var burn: String
    var state: String
    var ts: Int
    var primary: String
    var primaryLabel: String
    /// True when daemon has at least one firmware sink attached. Gates the
    /// metric row in the menu and the "device connected" indicator in
    /// PairingView.
    var devicePresent: Bool
    /// Set by the daemon on the single frame that crosses a whole-dollar
    /// cost boundary. Format: `"cost:<D>"`. Cleared on every other frame.
    /// The notifier diffs on this and pops a milestone celebration when it
    /// goes from nil to a value.
    var milestone: String?
    /// Per-provider totals carried on the WS frame so the menubar can derive
    /// the header subtitle and the Breakdown submenu rows from the same
    /// payload. Empty when no provider has emitted yet (or daemon predates
    /// the field) — `headerSubtitle` falls back to the daemon-formatted
    /// scalars; Breakdown stays hidden by its `>= 2 sources` gate.
    var providers: [ProviderSlice]

    struct ProviderSlice: Codable, Equatable, Identifiable {
        let id: String
        let tokens: Int
        let cost: Decimal
    }

    static let empty = DisplayFrame(
        tokens: "...",
        cost: "...",
        burn: "...",
        state: "sleep",
        ts: 0,
        primary: "...",
        primaryLabel: "TOKENS",
        devicePresent: false,
        milestone: nil,
        providers: []
    )
}

extension Publisher where Failure == Never {
    fileprivate func eraseToVoid() -> AnyPublisher<Void, Never> {
        map { _ in () }.eraseToAnyPublisher()
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
