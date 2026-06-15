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
        while !latest.isReachable && Date() < deadline && !Task.isCancelled {
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
                return status
            }
            if let body = try? JSONDecoder().decode(HealthResponse.self, from: data) {
                status = body.usageReader == "no-jsonl-found" ? .usageReaderEmpty : .up
                uptimeSeconds = body.uptimeSeconds
            } else {
                status = .up
            }
        } catch {
            status = .down
        }
        return status
    }
}

extension ServerHealthMonitor.Status {
    var isReachable: Bool {
        self == .up || self == .usageReaderEmpty
    }
}
