import Foundation
import SwiftUI

/// Connects to the local Sissy server's `/ws` and feeds incoming frames
/// into `SissyModel.currentFrame`. Keeps the menu bar icon in sync with the
/// real mascot state instead of relying on a static placeholder.
///
/// Auto-reconnects on disconnect with a bounded exponential backoff so a
/// missing or restarting server doesn't permanently break the UI.
@MainActor
final class WebSocketClient: ObservableObject {
    @Published var isConnected: Bool = false
    /// Becomes true after the first successful WS handshake and never resets.
    /// Lets the menubar suppress the "offline" badge during the launch window
    /// before WS has had a chance to connect — otherwise the icon flickers
    /// offline → online → frame-state in the first second of app launch.
    @Published private(set) var hasEverConnected: Bool = false

    private weak var model: SissyModel?
    private var task: URLSessionWebSocketTask?
    private var session: URLSession = URLSession(configuration: .default)
    private var reconnectAttempt: Int = 0
    private var stopped: Bool = true
    private var reconnectTask: Task<Void, Never>?
    /// Prevents duplicate reconnect scheduling when both probeConnection and
    /// receive fail for the same task (which both happen on a real TCP drop).
    /// Without dedupe, reconnectAttempt double-increments per disconnect and
    /// the backoff jumps 1s → 4s → 16s → 30s instead of 1s → 2s → 4s → 8s.
    private var reconnectScheduled: Bool = false
    /// Fires if a freshly-resumed task hasn't completed its handshake within
    /// `connectTimeout`. Without it a half-open TCP (SYN sent, no reply) leaves
    /// the ping callback pending until the OS times out the socket (~60s),
    /// freezing the menubar on `--`. Cancelled the moment the connection goes
    /// live, so a healthy idle connection between sparse frames is never cut.
    private var connectTimeoutTask: Task<Void, Never>?
    private static let connectTimeout: TimeInterval = 8

    init() {}

    func attach(model: SissyModel) {
        self.model = model
    }

    func start() {
        stopped = false
        connect()
    }

    func stop() {
        stopped = true
        reconnectTask?.cancel()
        reconnectTask = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        isConnected = false
    }

    /// Cycle the connection — useful when the user rotates the token from the
    /// Settings window and we need to redo the bearer handshake.
    func reconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        reconnectAttempt = 0
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
        if !stopped { connect() }
    }

    private func connect() {
        reconnectScheduled = false
        guard let model else { return }
        let prefs = model.preferences
        var comps = URLComponents()
        comps.scheme = "ws"
        comps.host = prefs.serverHost
        comps.port = prefs.serverPort
        comps.path = "/ws"
        guard let url = comps.url else { return }

        var req = URLRequest(url: url)
        if !prefs.authToken.isEmpty {
            req.setValue("Bearer \(prefs.authToken)", forHTTPHeaderField: "Authorization")
        }

        let newTask = session.webSocketTask(with: req)
        task = newTask
        newTask.resume()
        startConnectTimeout(for: newTask)
        // Defer the hello until probeConnection confirms the handshake is up.
        // Sending it eagerly here would race against the connect and either
        // queue a wasted frame (if connect succeeds) or produce a duplicate
        // hello when probeConnection sends its own after the ping returns.
        probeConnection(newTask)
        receive()
    }

    private func startConnectTimeout(for candidate: URLSessionWebSocketTask) {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.connectTimeout * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isCurrentTask(candidate),
                !self.stopped, !self.isConnected
            else { return }
            NSLog("sissy websocket handshake timed out after %.0fs; reconnecting", Self.connectTimeout)
            self.connectTimeoutTask = nil
            candidate.cancel(with: .goingAway, reason: nil)
            self.scheduleReconnect()
        }
    }

    /// Promote a task to connected exactly once. Cancels the handshake
    /// watchdog and resets the backoff so the next drop starts fresh.
    private func markConnected() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        isConnected = true
        hasEverConnected = true
        reconnectAttempt = 0
    }

    /// Push the current primary-metric preference to the server. Used both on
    /// connect and whenever the user flips the picker in Settings — the server
    /// keeps the metric in-memory and applies it to all attached clients.
    func pushSettings() {
        sendHello()
    }

    /// Push the milestone-frequency preset to the daemon. Sent on
    /// menubar-pick; the daemon also reads `milestone_frequency` from the
    /// `hello` payload so a fresh connection reflects the current selection
    /// without needing a separate round-trip.
    func setMilestoneFrequency(_ value: String) {
        guard let task else { return }
        let payload: [String: Any] = [
            "type": "set_milestone_frequency",
            "value": value,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
            let text = String(data: data, encoding: .utf8)
        else { return }
        task.send(.string(text)) { error in
            if let error {
                NSLog("sissy set_milestone_frequency send failed: %@", error.localizedDescription)
            }
        }
    }

    /// Pin the mascot to `state` on the daemon (sticky until cleared).
    /// Passing nil clears the pin so the daemon resumes the computed state.
    func setMascotPin(state: String?) {
        guard let task else { return }
        var payload: [String: Any] = ["type": "set_state"]
        if let state {
            payload["state"] = state
        } else {
            payload["state"] = "auto"
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
            let text = String(data: data, encoding: .utf8)
        else { return }
        task.send(.string(text)) { error in
            if let error {
                NSLog("sissy set_state send failed: %@", error.localizedDescription)
            }
        }
    }

    private func sendHello() {
        guard let model, let task else { return }
        // Wire format is snake_case to match the server's enum
        // (PRIMARY_TOKENS/PRIMARY_BURN_RATE). Storage stays camelCase to keep
        // existing preferences.json files decodable without a migration.
        let metric: String
        switch model.preferences.primaryMetric {
        case .tokens: metric = "tokens"
        case .burnRate: metric = "burn_rate"
        }
        let payload: [String: Any] = [
            "type": "hello",
            "client": "mac-app",
            "primary_metric": metric,
            "milestone_frequency": model.preferences.milestoneFrequency.rawValue,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
            let text = String(data: data, encoding: .utf8)
        else { return }
        task.send(.string(text)) { error in
            if let error {
                // Connection might be mid-handshake; the next reconnect will
                // re-send. Log via stderr only so the UI stays quiet.
                NSLog("sissy hello send failed: %@", error.localizedDescription)
            }
        }
    }

    private func probeConnection(_ candidate: URLSessionWebSocketTask) {
        candidate.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self, self.isCurrentTask(candidate), !self.stopped else { return }
                if let error {
                    NSLog("sissy websocket ping failed: %@", error.localizedDescription)
                    self.isConnected = false
                    self.scheduleReconnect()
                    return
                }
                self.markConnected()
                self.sendHello()
            }
        }
    }

    private func isCurrentTask(_ candidate: URLSessionWebSocketTask) -> Bool {
        guard let task else { return false }
        return task === candidate
    }

    private func receive() {
        guard let candidate = task else { return }
        candidate.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                // Drop callbacks from a task we've already replaced (e.g. via
                // reconnect()). Without this guard, a cancelled task's stale
                // .failure delivers URLError.cancelled, which would clear
                // isConnected and re-schedule a reconnect that kills the
                // already-healthy new task — causing a visible icon flicker
                // immediately after Start.
                guard self.isCurrentTask(candidate), !self.stopped else { return }
                switch result {
                case .success(let message):
                    self.markConnected()
                    self.handle(message)
                    self.receive()
                case .failure:
                    self.isConnected = false
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let s): text = s
        case .data(let d): text = String(decoding: d, as: UTF8.self)
        @unknown default: return
        }

        guard let data = text.data(using: .utf8),
            let any = try? JSONSerialization.jsonObject(with: data),
            let dict = any as? [String: Any],
            dict["type"] as? String == "frame"
        else { return }

        let tokens = dict["tokens"] as? String ?? "..."
        let cost = dict["cost"] as? String ?? "..."
        let burn = dict["burn"] as? String ?? "..."
        let state = dict["state"] as? String ?? "think"
        let ts = dict["ts"] as? Int ?? 0
        let primary = dict["primary"] as? String ?? tokens
        let primaryLabel = dict["primary_label"] as? String ?? "TOKENS"
        let devicePresent = dict["device_present"] as? Bool ?? false
        // Present only on the single frame that crosses a threshold; absent
        // otherwise. The notifier filters non-crossing frames out via
        // `compactMap` and dedupes on `(milestone, ts)`.
        let milestone = dict["milestone"] as? String
        // Per-provider slices: header total + Breakdown rows derive from this.
        // Empty when the daemon hasn't emitted any provider yet, or when an
        // older daemon predates the field — `headerSubtitle` then falls back
        // to the daemon-formatted `tokens`/`cost` strings.
        var providers: [DisplayFrame.ProviderSlice] = []
        if let rawProviders = dict["providers"] as? [[String: Any]] {
            for raw in rawProviders {
                guard let id = raw["id"] as? String,
                    let tokensRaw = raw["tokens"] as? Int,
                    let costRaw = raw["cost"] as? String,
                    let costDec = Decimal(string: costRaw)
                else { continue }
                providers.append(.init(id: id, tokens: tokensRaw, cost: costDec))
            }
        }
        model?.currentFrame = DisplayFrame(
            tokens: tokens,
            cost: cost,
            burn: burn,
            state: state,
            ts: ts,
            primary: primary,
            primaryLabel: primaryLabel,
            devicePresent: devicePresent,
            milestone: milestone,
            providers: providers
        )
    }

    private func scheduleReconnect() {
        if stopped { return }
        if reconnectScheduled { return }
        reconnectScheduled = true
        // Equal-jitter backoff: half the capped exponential delay plus a random
        // point in the other half. Keeps a sensible floor while preventing
        // several clients from reconnecting in lock-step after a daemon restart.
        let cap = min(pow(2.0, Double(reconnectAttempt)), 30.0)
        let delaySeconds = cap / 2 + Double.random(in: 0...(cap / 2))
        reconnectAttempt += 1
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self, !self.stopped else { return }
            self.reconnectTask = nil
            self.connect()
        }
    }
}
