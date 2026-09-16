import Foundation

/// Polls claude.ai for the windows and the credits, with the session
/// Claude.app already holds.
///
/// The reading the CLI caches in `.claude.json` is not an alternative to this
/// one: measured 2026-09-14, it had not advanced in 59 minutes of continuous
/// Claude Code use, because it only refreshes when the user types `/usage`.
/// Against it, the live reply named 26 275 credits spent where the cache said
/// 19 260, under a cap the cache did not know had been raised. A number an
/// hour behind and unable to catch up is a different number, not a stale one.
///
/// The endpoint is claude.ai's own, undocumented and private, which drives the
/// same three rules the OAuth probe next door already lives by: the poll is
/// slow, a 429 backs off hard, and a failure leaves the panel on its previous
/// row rather than surfacing an error the user cannot act on. What it adds is
/// a fourth: the request needs a `Claude/<version>` product token in its
/// User-Agent. Measured — the same session with a plain Chrome agent is
/// refused at 403, and `Electron/` alone does not substitute.
actor ClaudeWebSource: SourceSignals {
    private static let host = "https://claude.ai"
    private static let organizationsPath = "/api/organizations"
    private static let prepaidPath = "prepaid/credits"
    private static let requestTimeout: TimeInterval = 15
    private static let refreshInterval: Duration = .seconds(300)
    private static let rateLimitedBackoff: Duration = .seconds(1800)

    /// Capability that names the organization a subscription meters against.
    /// An account can hold several — the measured one also had an
    /// `api_evaluation` org, which answers a different question entirely.
    private static let subscriptionCapability = "chat"

    /// Version reported when Claude.app is not installed and the session was
    /// pasted instead. Pinned rather than invented: an agent naming a version
    /// that never shipped is a worse guess than one naming an old one.
    static let fallbackAppVersion = "1.52386.6"
    private static let chromeVersion = "132.0.6834.210"

    nonisolated private let published = LockedValue(ProviderSignals())
    /// Where the session comes from. Injectable for the same reason the OAuth
    /// probe's is: reading the keychain is what can raise a system dialog, and
    /// a test of this source must be able to answer for one without putting it
    /// on a screen.
    private let sessionSource: @Sendable (Bool) async -> ClaudeCredentialsLookup
    /// The network half, injectable for the same reason: a test of the refresh
    /// contract must not reach claude.ai.
    private let fetchSource: @Sendable (String, String?) async throws -> Reading

    private var cached: String?
    /// Organization the windows belong to, kept so the ordinary poll is one
    /// request rather than two. Dropped whenever the session is.
    private var organization: String?
    private var mayInteract = false
    private var pollTask: Task<Void, Never>?
    private var firstRequest: Task<Duration, Never>?
    private var generation = 0
    private var lastReported: String?

    /// One answer from claude.ai: the windows it drew and what it has billed.
    struct Reading: Sendable, Equatable {
        let organization: String
        let windows: [UsageWindow]
        let credits: ProviderCredits?
    }

    /// Which account's session this reader spends. One reader per stored
    /// session, so nothing ever picks between them — a source built for an
    /// account reads that account's item and no other.
    let account: String

    init(
        account: String,
        sessionSource: (@Sendable (Bool) async -> ClaudeCredentialsLookup)? = nil,
        fetchSource: @escaping @Sendable (String, String?) async throws -> Reading = fetch
    ) {
        self.account = account
        self.sessionSource =
            sessionSource
            ?? { allowingInteraction in
                ClaudeWebSessionStore.load(
                    account: account, allowingInteraction: allowingInteraction)
            }
        self.fetchSource = fetchSource
    }

    nonisolated func currentSignals() -> ProviderSignals { published.load().live() }

    /// `userInitiated` says whether someone just flipped the switch. Only that
    /// start may raise the keychain dialog; the one a launch makes because the
    /// setting was already on reads silently and shows no limits if the grant
    /// has gone stale.
    func start(userInitiated: Bool, onRefresh: @Sendable @escaping () async -> Void) {
        guard pollTask == nil else { return }
        _ = begin(userInitiated: userInitiated, onRefresh: onRefresh)
    }

    /// Starts the loop and hands back the first request, so an explicit
    /// refresh stays pending until session, network and publication have all
    /// completed rather than ending on the hand-off.
    private func begin(
        userInitiated: Bool,
        onRefresh: @Sendable @escaping () async -> Void
    ) -> Task<Duration, Never> {
        mayInteract = userInitiated
        let request = Task { await refreshOnce(onRefresh: onRefresh) }
        firstRequest = request
        pollTask = Task { [weak self] in
            var delay = await request.value
            while !Task.isCancelled {
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self else { return }
                delay = await self.refreshOnce(onRefresh: onRefresh)
            }
        }
        return request
    }

    /// Stops the poll loop and drops what it had published, on the same
    /// reasoning as the OAuth probe's: the aggregator rebuilds every slice
    /// from `currentSignals()`, so a cancelled task that kept its last answer
    /// would leave the gauges up under a switch the user has turned off.
    ///
    /// `clearingState` separates the two kinds of stop. The user switching the
    /// source off wants the state gone with the windows; a poll stopping
    /// itself because the session died has to keep it, because that state is
    /// the only thing on screen offering a way back.
    func stop(clearingState: Bool = true) {
        cancelRequests()
        cached = nil
        organization = nil
        published.update {
            $0.windows = []
            $0.credits = nil
            $0.limitsObservedAt = nil
            if clearingState { $0.limitsState = .quiet }
        }
        lastReported = nil
    }

    private func cancelRequests() {
        generation &+= 1
        pollTask?.cancel()
        firstRequest?.cancel()
        pollTask = nil
        firstRequest = nil
    }

    /// Re-reads the session with the dialog allowed and polls at once,
    /// returning only once that request has finished.
    ///
    /// Deliberately not `stop()` first: that drops the published windows, and
    /// a refresh that blanks the gauges it is trying to restore reads as a
    /// failure for as long as the request takes.
    func refresh(onRefresh: @Sendable @escaping () async -> Void) async {
        cancelRequests()
        cached = nil
        lastReported = nil
        let request = begin(userInitiated: true, onRefresh: onRefresh)
        await withTaskCancellationHandler {
            _ = await request.value
        } onCancel: {
            request.cancel()
        }
    }

    /// One poll. Returns how long to wait before the next one.
    ///
    /// Internal rather than private so a test can run exactly one and assert
    /// on what it published, for the reason the probe's twin documents.
    func refreshOnce(onRefresh: @Sendable @escaping () async -> Void) async -> Duration {
        let stamp = generation
        let before = published.load()
        let delay = await readAndFetch(generation: stamp)
        guard stamp == generation else { return delay }
        if Task.isCancelled && published.load().limitsState != .refused { return delay }
        if published.load() != before { await onRefresh() }
        return delay
    }

    private enum Session {
        case ready(String)
        case wait(Duration)
    }

    private func currentSession(generation stamp: Int) async -> Session {
        if let cached { return .ready(cached) }
        let interactive = mayInteract
        mayInteract = false
        let outcome = await sessionSource(interactive)
        guard stamp == generation, !Task.isCancelled else { return .wait(Self.refreshInterval) }
        switch outcome {
        case .found(let found):
            cached = found.accessToken
            published.update { $0.limitsState = .quiet }
            return .ready(found.accessToken)
        case .absent:
            publishFailure(.signedOut)
            report("no claude.ai session imported; limits stay hidden until one is")
            return .wait(Self.refreshInterval)
        case .interactionRequired:
            publishFailure(.needsAuthorization)
            report("the claude.ai session is there and this read was not allowed to ask for it")
            return .wait(Self.refreshInterval)
        case .denied:
            publishFailure(.refused)
            report("reading the claude.ai session was refused; the source stops until restarted")
            cancelRequests()
            return .wait(Self.refreshInterval)
        case .unreadable(let status):
            publishFailure(.signedOut)
            report("the claude.ai session could not be read (status \(status))")
            return .wait(Self.refreshInterval)
        case .unreachable:
            // Not reachable from this source: the session store is Sissy's own
            // item, addressed by a name this type owns. Kept exhaustive rather
            // than defaulted so a case added later has to be answered here.
            publishFailure(.credentialUnreachable)
            report("the imported claude.ai session is not readable from here")
            return .wait(Self.refreshInterval)
        case .timedOut:
            report("reading the claude.ai session outlived its budget; retrying")
            return .wait(Self.refreshInterval)
        }
    }

    private func readAndFetch(generation stamp: Int) async -> Duration {
        let session: String
        switch await currentSession(generation: stamp) {
        case .ready(let found): session = found
        case .wait(let delay): return delay
        }
        do {
            let reading = try await fetchSource(session, organization)
            guard stamp == generation, !Task.isCancelled else { return Self.refreshInterval }
            organization = reading.organization
            published.update {
                $0.windows = reading.windows
                $0.credits = reading.credits
                $0.limitsState = .quiet
                $0.limitsObservedAt = Date()
            }
            return Self.refreshInterval
        } catch {
            guard stamp == generation, !Task.isCancelled else { return Self.refreshInterval }
            return handle(error)
        }
    }

    /// What a failed request costs, and what it says.
    ///
    /// A 401 or 403 is the session having ended, which is the one outcome the
    /// user can act on: it is published rather than merely logged, and the
    /// held copy is dropped so the next poll reads the item again instead of
    /// spending a session claude.ai has already closed. The organization goes
    /// with it — the next session may not be the same account's.
    private func handle(_ error: Error) -> Duration {
        if case ClaudeLimitsError.rateLimited = error {
            report("claude.ai answered 429; backing off for \(Self.rateLimitedBackoff)")
            return Self.rateLimitedBackoff
        }
        if case ClaudeLimitsError.badStatus(let code) = error, code == 401 || code == 403 {
            cached = nil
            organization = nil
            publishFailure(.sessionExpired)
            report("the claude.ai session was refused (status \(code)); import it again")
            return Self.refreshInterval
        }
        report("the claude.ai usage request failed: \(error.localizedDescription)")
        return Self.refreshInterval
    }

    /// Publishes why the reading is missing, and takes it down with it: a
    /// gauge left standing under a sentence explaining that there is nothing
    /// behind it is worse than no gauge.
    private func publishFailure(_ state: ProviderLimitsState) {
        published.update {
            $0.limitsState = state
            $0.windows = []
            $0.credits = nil
        }
    }

    private func report(_ message: String) {
        guard lastReported != message else { return }
        lastReported = message
        sissyLog("sissy: \(message)")
    }

    // MARK: - The wire

    /// One poll's worth of claude.ai, resolving the organization first when it
    /// is not already known.
    static func fetch(session: String, organization: String?) async throws -> Reading {
        let org =
            if let organization { organization } else {
                try await subscriptionOrganization(session: session)
            }
        let body = try await get("\(organizationsPath)/\(org)/usage", session: session)
        let observedAt = Date()
        let credits = ClaudeUsagePayload.credits(body, observedAt: observedAt)
        return Reading(
            organization: org,
            windows: ClaudeUsagePayload.windows(body),
            credits: try await withBalance(credits, org: org, session: session)
        )
    }

    /// The credits with the prepaid balance beside them.
    ///
    /// A second request, and a failing one costs the balance rather than the
    /// whole reading: the spend against the cap is already in hand and
    /// dropping it because a different endpoint was unhappy would be losing
    /// what was asked for to chase what was extra.
    private static func withBalance(
        _ credits: ProviderCredits?,
        org: String,
        session: String
    ) async throws -> ProviderCredits? {
        guard var credits, case .money(let currency, _) = credits.unit else { return credits }
        let body = try? await get("\(organizationsPath)/\(org)/\(prepaidPath)", session: session)
        credits.balanceMinor = body.flatMap {
            ClaudeUsagePayload.balance($0, currency: currency)
        }
        return credits
    }

    /// Who a session belongs to, as claude.ai answers it.
    ///
    /// Narrow on purpose: `get` stays private so the session leaves this file
    /// only through paths it owns, and a caller that wants an identity asks
    /// for an identity rather than for an arbitrary authenticated GET.
    static func account(session: String) async throws -> [String: Any] {
        try await get(accountPath, session: session)
    }

    private static let accountPath = "/api/account"

    /// The organization a subscription is metered against.
    ///
    /// An account can hold more than one, and they answer different questions:
    /// the measured one paired a `chat` organization with an `api_evaluation`
    /// organization whose usage has nothing to do with the plan. Picking by
    /// capability rather than by position is what stops the row reporting the
    /// wrong one on an account that happens to list them the other way round.
    static func subscriptionOrganization(session: String) async throws -> String {
        try subscriptionOrganization(in: await getArray(organizationsPath, session: session))
    }

    /// The selection itself, so the rule is testable without claude.ai.
    static func subscriptionOrganization(in payload: [Any]) throws -> String {
        let organizations = payload.compactMap { $0 as? [String: Any] }
        let subscription = subscriptionOrganization(among: organizations)
        guard let uuid = (subscription ?? organizations.first)?["uuid"] as? String,
            !uuid.isEmpty
        else {
            throw ClaudeLimitsError.malformedPayload
        }
        return uuid
    }

    /// The organisation itself rather than its id, for the caller that wants
    /// what is written on it. Shared with `ClaudeWebAccountProfile` so the two
    /// readers of this payload cannot come to disagree about which of an
    /// account's organisations the subscription is.
    static func subscriptionOrganization(among organizations: [[String: Any]]) -> [String: Any]? {
        organizations.first { organization in
            let capabilities = organization["capabilities"] as? [Any] ?? []
            return capabilities.contains { ($0 as? String) == subscriptionCapability }
        }
    }

    private static func get(_ path: String, session: String) async throws -> [String: Any] {
        let data = try await send(path, session: session)
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeLimitsError.malformedPayload
        }
        return body
    }

    private static func getArray(_ path: String, session: String) async throws -> [Any] {
        let data = try await send(path, session: session)
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw ClaudeLimitsError.malformedPayload
        }
        return body
    }

    private static func send(_ path: String, session: String) async throws -> Data {
        guard let url = URL(string: host + path) else { throw ClaudeLimitsError.malformedPayload }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "\(ClaudeWebSessionStore.cookieName)=\(session)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent(), forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeLimitsError.malformedPayload
        }
        if http.statusCode == 429 { throw ClaudeLimitsError.rateLimited }
        guard http.statusCode == 200 else {
            throw ClaudeLimitsError.badStatus(http.statusCode)
        }
        return data
    }

    /// The agent claude.ai answers.
    ///
    /// Measured 2026-09-14: the `Claude/<version>` product token is what gets
    /// past the edge — the same session with a plain Chrome agent is refused
    /// at 403, and an `Electron/` token does not substitute. The version is
    /// the installed app's, so an agent Sissy sends is one that exists.
    static func userAgent(appVersion: String? = installedAppVersion()) -> String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
            + "Claude/\(appVersion ?? fallbackAppVersion) Chrome/\(chromeVersion) Safari/537.36"
    }

    static func installedAppVersion(
        at url: URL = URL(fileURLWithPath: "/Applications/Claude.app/Contents/Info.plist")
    ) -> String? {
        guard let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            let version = plist["CFBundleShortVersionString"] as? String,
            !version.isEmpty
        else { return nil }
        return version
    }
}
