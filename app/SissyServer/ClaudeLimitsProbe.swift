import Foundation

/// Polls the endpoint Claude Code's own `/usage` reads, so the panel can show
/// the 5-hour and weekly subscription windows next to Codex's.
///
/// Claude Code, unlike Codex, writes no limit state to disk — the numbers only
/// exist in API responses. The endpoint is undocumented, which drives three
/// rules here: the poll is slow, a 429 backs off hard (third-party pollers
/// hammering it every 30 s are a known way to earn a persistent 429), and a
/// failure leaves the panel on its previous row rather than surfacing an
/// error the user cannot act on.
actor ClaudeLimitsProbe {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let betaHeader = "oauth-2025-04-20"
    private static let requestTimeout: TimeInterval = 10
    private static let refreshInterval: Duration = .seconds(300)
    private static let rateLimitedBackoff: Duration = .seconds(1800)
    private static let keychainTimeout: Duration = .seconds(20)

    /// Wire key to window length. Anthropic publishes finer buckets
    /// (`seven_day_opus`, `seven_day_sonnet`); the panel shows the two that
    /// apply to every plan.
    private static let buckets: [(key: String, minutes: Int)] = [
        ("five_hour", 300),
        ("seven_day", 10_080),
    ]

    nonisolated private let windows = AtomicWindows()
    private var pollTask: Task<Void, Never>?
    /// Last condition logged, so a poll that keeps failing the same way says
    /// so once instead of every five minutes — and a *different* failure
    /// still gets through.
    private var lastReported: String?

    /// Live windows, expired buckets dropped — a window past its reset
    /// describes a period that no longer exists, same rule the Codex reader
    /// applies to its own.
    nonisolated func currentWindows() -> [UsageWindow] { windows.live() }

    /// Starts the poll loop. `onRefresh` fires only when the windows actually
    /// changed, so a steady state costs no broadcasts. Idempotent.
    func start(onRefresh: @Sendable @escaping () async -> Void) {
        if pollTask != nil { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.refreshOnce(onRefresh: onRefresh)
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Logs `message` the first time this condition is seen, and again only
    /// once something else has happened in between.
    private func report(_ message: String) {
        if lastReported == message { return }
        lastReported = message
        daemonLog("sissy-serverd: \(message)")
    }

    /// One poll. Returns how long to wait before the next one.
    private func refreshOnce(onRefresh: @Sendable @escaping () async -> Void) async -> Duration {
        let credentials: ClaudeCredentials
        switch await ClaudeCredentialsStore.loadOffPool(timeout: Self.keychainTimeout) {
        case .found(let found):
            credentials = found
        case .absent:
            report(
                "no Claude Code credentials in the keychain under "
                    + "\(ClaudeCredentialsStore.keychainService); limits stay hidden until you "
                    + "sign into the CLI")
            return Self.refreshInterval
        case .denied:
            report(
                "keychain access to \(ClaudeCredentialsStore.keychainService) was refused; "
                    + "Claude Code limits stay hidden. Grant it in Keychain Access, or turn "
                    + "the setting off")
            stop()
            return Self.refreshInterval
        case .unreadable(let status):
            report("could not read Claude credentials (OSStatus \(status))")
            return Self.refreshInterval
        case .timedOut:
            report(
                "the keychain did not answer within \(Self.keychainTimeout); Claude limits are "
                    + "waiting on an authorization prompt")
            return Self.refreshInterval
        }

        guard credentials.isValid() else {
            report(
                "the Claude Code access token expired at \(credentials.expiresAt); waiting for "
                    + "the CLI to renew it")
            return Self.refreshInterval
        }

        do {
            let fetched = try await fetch(token: credentials.accessToken)
            let summary =
                fetched
                .map { "\($0.minutes)m \(Int($0.usedPercent.rounded()))%" }
                .joined(separator: ", ")
            report("Claude limits — " + (summary.isEmpty ? "endpoint returned no window" : summary))
            if fetched != windows.load() {
                windows.store(fetched)
                await onRefresh()
            }
            return Self.refreshInterval
        } catch ClaudeLimitsError.rateLimited {
            report("Claude usage endpoint returned 429; backing off for \(Self.rateLimitedBackoff)")
            return Self.rateLimitedBackoff
        } catch ClaudeLimitsError.badStatus(let code) {
            report("Claude usage endpoint returned HTTP \(code)")
            return Self.refreshInterval
        } catch {
            report("Claude usage request failed: \(error.localizedDescription)")
            return Self.refreshInterval
        }
    }

    private func fetch(token: String) async throws -> [UsageWindow] {
        var request = URLRequest(url: Self.usageURL, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 { throw ClaudeLimitsError.rateLimited }
            guard http.statusCode == 200 else {
                throw ClaudeLimitsError.badStatus(http.statusCode)
            }
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeLimitsError.malformedPayload
        }
        let windows = Self.parse(payload)
        if windows.isEmpty {
            // The endpoint is undocumented: naming the keys it did send is the
            // only way to tell "no limits on this plan" from "the shape moved".
            let shapes = Self.buckets.map { bucket -> String in
                guard let raw = payload[bucket.key] as? [String: Any] else {
                    return "\(bucket.key)=<missing>"
                }
                return "\(bucket.key)={\(raw.keys.sorted().joined(separator: "|"))}"
            }
            report(
                "Claude usage buckets did not parse; shapes: "
                    + shapes.joined(separator: ", "))
        }
        return windows
    }

    static func parse(_ payload: [String: Any]) -> [UsageWindow] {
        buckets.compactMap { bucket in
            guard let raw = payload[bucket.key] as? [String: Any],
                let resetsAt = parseReset(raw["resets_at"]),
                let usedPercent = utilization(of: raw)
            else { return nil }
            return UsageWindow(
                minutes: bucket.minutes,
                usedPercent: usedPercent,
                resetsAt: resetsAt
            )
        }
    }

    /// How much of the window is gone, as a percentage.
    ///
    /// A bucket reports either a ready-made `utilization` or a dollar budget,
    /// depending on the plan — and a dollar-metered bucket sends `utilization`
    /// as JSON null, which is why the percentage cannot simply be read.
    private static func utilization(of bucket: [String: Any]) -> Double? {
        if let direct = bucket["utilization"] as? Double { return direct }
        guard let used = bucket["used_dollars"] as? Double,
            let limit = bucket["limit_dollars"] as? Double,
            limit > 0
        else { return nil }
        return used / limit * 100
    }

    /// `resets_at` is accepted both as epoch seconds and as an ISO-8601
    /// string: the endpoint is undocumented, so the parse does not bet on one.
    private static func parseReset(_ raw: Any?) -> Date? {
        if let epoch = raw as? Double {
            return Date(timeIntervalSince1970: epoch)
        }
        if let text = raw as? String {
            return ClaudeCodeUsageReader.parseISODate(text)
        }
        return nil
    }
}

enum ClaudeLimitsError: Error {
    case rateLimited
    case badStatus(Int)
    case malformedPayload
}
