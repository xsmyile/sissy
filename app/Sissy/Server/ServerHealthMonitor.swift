import Combine
import Foundation

@MainActor
final class ServerHealthMonitor: ObservableObject {
    enum Status: Equatable {
        case unknown
        case up
        case down
        case usageReaderEmpty
    }

    @Published var status: Status = .unknown
    @Published var uptimeSeconds: Int = 0
    /// Per-provider snapshot from /stats. Empty until the first successful
    /// fetch, one entry per active provider (Claude Code, Codex, and any
    /// future CLI sources). The menubar reads this to decide whether to
    /// render the "Breakdown" submenu.
    @Published var providerBreakdown: [ProviderUsageSnapshot] = []

    struct ProviderUsageSnapshot: Equatable, Identifiable {
        let id: String
        let tokens: Int
        let cost: Decimal
    }

    private let prefsProvider: @MainActor () -> Preferences
    private var pollTask: Task<Void, Never>?
    private let pollInterval: Duration = .seconds(3)

    init(prefsProvider: @escaping @MainActor () -> Preferences) {
        self.prefsProvider = prefsProvider
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshNow()
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(3))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    @discardableResult
    func refreshNow() async -> Status {
        await updateStatus()
    }

    @discardableResult
    func waitUntilReachable(timeoutSeconds: Double = 6) async -> Status {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var latest = await refreshNow()
        while !latest.isReachable && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            latest = await refreshNow()
        }
        return latest
    }

    private func updateStatus() async -> Status {
        let prefs = prefsProvider()
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = prefs.serverHost
        comps.port = prefs.serverPort
        comps.path = "/health"
        guard let url = comps.url else {
            status = .unknown
            return status
        }
        var req = URLRequest(url: url, timeoutInterval: 2)
        if !prefs.authToken.isEmpty {
            req.setValue("Bearer \(prefs.authToken)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                status = .down
                providerBreakdown = []
                return status
            }
            if let body = try? JSONDecoder().decode(HealthResponse.self, from: data) {
                status = body.usageReader == "no-jsonl-found" ? .usageReaderEmpty : .up
                uptimeSeconds = body.uptimeSeconds
            } else {
                status = .up
            }
            // /stats piggy-backs on the same 3s cadence as /health. Failure
            // here is non-fatal: the menubar drops the Breakdown row but
            // the rest of the UI stays functional.
            await refreshStats(prefs: prefs)
        } catch {
            status = .down
            // Daemon unreachable — flush stale per-provider rows so the
            // menubar doesn't keep advertising counts that are no longer
            // backed by a live source.
            providerBreakdown = []
        }
        return status
    }

    private func refreshStats(prefs: Preferences) async {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = prefs.serverHost
        comps.port = prefs.serverPort
        comps.path = "/stats"
        guard let url = comps.url else { return }
        var req = URLRequest(url: url, timeoutInterval: 2)
        if !prefs.authToken.isEmpty {
            req.setValue("Bearer \(prefs.authToken)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
            let http = resp as? HTTPURLResponse, http.statusCode == 200,
            let body = try? JSONDecoder().decode(StatsResponse.self, from: data)
        else { return }
        guard let providers = body.providers, !providers.isEmpty else {
            // /stats came back without a populated providers map: either an
            // older daemon that doesn't surface providers, or the aggregator
            // hasn't emitted yet. Clear the previous breakdown so the menu
            // hides the row instead of showing stale data.
            providerBreakdown = []
            return
        }
        var rows: [ProviderUsageSnapshot] = []
        for (id, entry) in providers {
            let cost = Decimal(string: entry.cost) ?? 0
            rows.append(ProviderUsageSnapshot(id: id, tokens: entry.tokens, cost: cost))
        }
        // Stable order so the submenu doesn't shuffle between polls — Claude
        // Code first (v0.1.0 baseline), then Codex, then anything else
        // alphabetically.
        rows.sort { lhs, rhs in
            let lp = Self.providerOrder(lhs.id)
            let rp = Self.providerOrder(rhs.id)
            if lp != rp { return lp < rp }
            return lhs.id < rhs.id
        }
        providerBreakdown = rows
    }

    private static func providerOrder(_ id: String) -> Int {
        switch id {
        case "claude-code": return 0
        case "codex": return 1
        default: return 2
        }
    }
}

extension ServerHealthMonitor.Status {
    var isReachable: Bool {
        self == .up || self == .usageReaderEmpty
    }
}
