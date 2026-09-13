import Foundation

/// Polls the endpoint Claude Code's own `/usage` reads, so the panel can show
/// the 5-hour and weekly subscription windows next to Codex's.
///
/// Claude Code, unlike Codex, writes no limit state to disk — the numbers only
/// exist in API responses. The endpoint is undocumented, which drives three
/// rules here: the poll is slow, a 429 backs off hard (third-party pollers
/// hammering it every 30 s are a known way to earn a persistent 429), and a
/// failure leaves the panel on its previous row rather than surfacing an
/// error the user cannot act on. Its shape is measured, never inferred: the
/// buckets meter in percent and report their dollar fields as null.
actor ClaudeLimitsProbe {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let betaHeader = "oauth-2025-04-20"
    private static let requestTimeout: TimeInterval = 10
    private static let refreshInterval: Duration = .seconds(300)
    private static let rateLimitedBackoff: Duration = .seconds(1800)
    private static let keychainTimeout: Duration = .seconds(20)
    /// Scope the endpoint insists on. A token minted without it answers 403
    /// naming it, which is the one 403 a user can act on.
    static let requiredScope = "user:profile"

    /// Response key to window length. Anthropic publishes finer buckets
    /// (`seven_day_opus`, `seven_day_sonnet`); the panel shows the two that
    /// apply to every plan.
    private static let buckets: [(key: String, minutes: Int)] = [
        ("five_hour", 300),
        ("seven_day", 10_080),
    ]

    nonisolated private let windows = AtomicWindows()
    /// Why the windows are missing, when they are. Published beside them and
    /// read the same way, so the row that draws the gauges and the row that
    /// explains their absence come off one payload.
    nonisolated private let state = AtomicLimitsState()
    /// Where the CLI's token comes from. Injectable for the same reason
    /// `ClaudeCredentialsStore.loadOffPool` takes a `lookup`: reading the
    /// keychain is what can raise a system dialog, and a test of the switch
    /// that starts this probe has to be able to answer for one without
    /// putting it on a screen.
    private let credentialsSource: @Sendable (Duration, Bool) async -> ClaudeCredentialsLookup
    /// The token the user pasted, if there is one. Read first and through the
    /// same gate as the CLI's item, so the two cannot queue two dispatch
    /// threads behind one dialog.
    private let managedSource: @Sendable (Duration, Bool) async -> ClaudeCredentialsLookup
    /// The one piece of external I/O on this path. Injectable for the same
    /// reason the credential reads are: what a 401 costs — the poll stops,
    /// the row asks for a new token — cannot be asserted against a live
    /// endpoint without a dead token to hand.
    private let transport: ClaudeUsageTransport
    /// Whether the next credential read may put a dialog on screen.
    ///
    /// Set only by a `start` the user asked for, and spent on the first read
    /// that needs it. Everything after that — every poll, and every launch
    /// that merely finds the setting already on — reads silently, which is the
    /// difference between a permission asked for when a switch is flipped and
    /// a stack of dialogs waiting on a Mac nobody was sitting at.
    private var mayInteract = false
    private var pollTask: Task<Void, Never>?
    /// Last condition logged, so a poll that keeps failing the same way says
    /// so once instead of every five minutes — and a *different* failure
    /// still gets through.
    private var lastReported: String?
    /// Last credentials read from the keychain, held until they expire.
    ///
    /// The access token is good for hours while the poll runs every five
    /// minutes, so re-reading it each time asks macOS to authorize ~96 times
    /// a day for a value that changed three times. Every one of those reads
    /// is a chance to meet a keychain whose grant has gone stale — an app
    /// re-signed, or the item recreated by the CLI — and to put a dialog in
    /// front of someone who did not just ask for one.
    private var cached: ClaudeCredentials?

    init(
        credentials: @escaping @Sendable (Duration, Bool) async -> ClaudeCredentialsLookup = {
            await ClaudeCredentialsStore.loadOffPool(timeout: $0, allowingInteraction: $1)
        },
        managedToken: @escaping @Sendable (Duration, Bool) async -> ClaudeCredentialsLookup = {
            await ClaudeCredentialsStore.loadOffPool(timeout: $0, allowingInteraction: $1) {
                ClaudeTokenStore.load(allowingInteraction: $0)
            }
        },
        transport: @escaping ClaudeUsageTransport = ClaudeLimitsProbe.liveTransport
    ) {
        self.credentialsSource = credentials
        self.managedSource = managedToken
        self.transport = transport
    }

    static let liveTransport: ClaudeUsageTransport = { request in
        try await URLSession.shared.data(for: request)
    }

    /// Live windows, expired buckets dropped — a window past its reset
    /// describes a period that no longer exists, same rule the Codex reader
    /// applies to its own.
    nonisolated func currentWindows() -> [UsageWindow] { windows.live() }

    nonisolated func currentLimitsState() -> ProviderLimitsState { state.load() }

    /// Starts the poll loop. `onRefresh` fires only when the windows actually
    /// changed, so a steady state costs no emits. Idempotent.
    ///
    /// `userInitiated` says whether someone just flipped the switch. Only that
    /// start is allowed to raise the keychain dialog; the one a launch makes
    /// because the setting was already on reads silently and shows no limits
    /// if the grant has gone stale.
    func start(userInitiated: Bool, onRefresh: @Sendable @escaping () async -> Void) {
        if pollTask != nil { return }
        mayInteract = userInitiated
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

    /// Stops the poll loop and drops the windows it had published.
    ///
    /// Dropping them is the whole job. The aggregator rebuilds every slice
    /// from `currentWindows()`, so a cancelled task publishes nothing new but
    /// keeps its last answer in the frame: turning the setting off left the
    /// gauges up until each bucket outlived its own reset — five hours for the
    /// session window, a week for the other. `lastReported` goes with them so
    /// turning the setting back on logs what it found instead of deduping
    /// against a poll from before the stop, and so does the published state:
    /// a row explaining why the limits are missing, under a switch the user
    /// has just turned off, blames Sissy for doing what it was told.
    ///
    /// `clearingState` is what separates the two kinds of stop. The user
    /// switching the module off wants the state gone with the windows; a poll
    /// stopping itself because the user refused the keychain has to keep it,
    /// because that state is the only thing on screen offering a way back.
    /// Saying so with a parameter rather than with statement order matters:
    /// the two can interleave on this actor, and an order that reads right is
    /// not the same as one that cannot race.
    ///
    /// The cached token follows the same division, and has to. A token the
    /// user pasted publishes no expiry, so it never falls out of the cache on
    /// its own: a module switched off, its token removed and switched on
    /// again would otherwise keep spending a credential Sissy was told to
    /// forget. A stop the probe imposed on *itself* keeps the token instead,
    /// because dropping it would have the next read publish `.quiet` on its
    /// way to failing the same way, flickering the very row that is asking
    /// for a new one.
    func stop(clearingState: Bool = true) {
        pollTask?.cancel()
        pollTask = nil
        windows.store([])
        if clearingState {
            state.store(.quiet)
            cached = nil
        }
        lastReported = nil
    }

    /// Re-reads the credentials with the dialog allowed and polls at once.
    ///
    /// The gesture behind a user asking for their limits back, and the only
    /// other thing besides flipping the switch that may put a keychain dialog
    /// on screen. Three things stand between a running probe and a fresh read
    /// and this clears all of them: the poll task, which makes `start` a
    /// no-op while it lives; the cached token, which returns before the
    /// keychain is touched at all; and the deduped log line, so the outcome
    /// of the read the user just asked for is actually recorded.
    ///
    /// Deliberately not `stop()` first: that drops the published windows, and
    /// a refresh that blanks the gauges it is trying to restore reads as a
    /// failure for as long as the request takes.
    /// `userInitiated` is false for the one caller that is a user action but
    /// must still not ask: changing the stored token. Removing one falls the
    /// probe back to Claude Code's item, and a Settings button that nobody
    /// pointed at the keychain raising its dialog would be a third gesture
    /// where `UsageEngine.refreshProvider` says there are two. A silent read
    /// answers `.interactionRequired` instead, and the panel's notice row is
    /// what offers the permission back.
    func refresh(userInitiated: Bool = true, onRefresh: @Sendable @escaping () async -> Void) {
        pollTask?.cancel()
        pollTask = nil
        cached = nil
        lastReported = nil
        start(userInitiated: userInitiated, onRefresh: onRefresh)
    }

    /// Logs `message` the first time this condition is seen, and again only
    /// once something else has happened in between.
    private func report(_ message: String) {
        if lastReported == message { return }
        lastReported = message
        sissyLog("sissy: \(message)")
    }

    /// Which token this poll runs on, and which item it came out of.
    ///
    /// The token the user pasted wins, because pasting it is the user saying
    /// they want it used. Only its *absence* falls through to Claude Code's
    /// own item: a managed token that exists and cannot be read is an answer,
    /// and continuing to the CLI's item would raise a dialog for a permission
    /// the user had already worked around.
    ///
    /// Both reads take the same `interactive`, and spending it costs nothing
    /// when the managed item is absent — authorizing a read is what raises a
    /// dialog, and an item that is not there authorizes nothing.
    private func resolveCredentials(
        interactive: Bool
    ) async -> (ClaudeCredentialsLookup, ClaudeTokenOrigin) {
        let managed = await managedSource(Self.keychainTimeout, interactive)
        if case .absent = managed {
            return (await credentialsSource(Self.keychainTimeout, interactive), .cli)
        }
        return (managed, .managed)
    }

    /// The keychain item an outcome is about, so a message names the thing the
    /// user would have to go and find.
    private static func itemName(_ origin: ClaudeTokenOrigin) -> String {
        switch origin {
        case .cli: return ClaudeCredentialsStore.keychainService
        case .managed: return ClaudeTokenStore.keychainService
        }
    }

    /// One poll. Returns how long to wait before the next one.
    ///
    /// Internal rather than private so a test can run exactly one and assert
    /// on what it published. Waiting on the poll loop instead means waiting on
    /// the scheduler: the read is recorded before the outcome is classified,
    /// so an assertion hung off the read passes or fails by luck.
    func refreshOnce(onRefresh: @Sendable @escaping () async -> Void) async -> Duration {
        if let cached, cached.isValid() {
            return await fetchWindows(using: cached, onRefresh: onRefresh)
        }
        let credentials: ClaudeCredentials
        let interactive = mayInteract
        mayInteract = false
        let (lookup, origin) = await resolveCredentials(interactive: interactive)
        switch lookup {
        case .found(let found):
            credentials = found
            cached = found
            state.store(.quiet)
        case .absent:
            state.store(.signedOut)
            report(
                "no Claude Code credentials in the keychain under "
                    + "\(ClaudeCredentialsStore.keychainService); limits stay hidden until you "
                    + "sign into the CLI")
            return Self.refreshInterval
        case .denied:
            report(
                "keychain access to \(Self.itemName(origin)) was refused; "
                    + "Claude Code limits stay hidden. Grant it in Keychain Access, or turn "
                    + "the setting off")
            state.store(.refused)
            stop(clearingState: false)
            return Self.refreshInterval
        // Alive, deliberately. Nobody refused anything — this read was simply
        // not allowed to ask, and the grant it wants back can return without
        // Sissy doing a thing: the CLI rewrites the item, or the user allows
        // it in Keychain Access. Stopping here would make a stale grant
        // indistinguishable from a refusal, and both would need a relaunch.
        case .interactionRequired:
            state.store(.needsAuthorization)
            report(
                "the keychain will not release \(Self.itemName(origin)) "
                    + "without asking, and this read did not ask; Claude limits stay hidden "
                    + "until you switch them off and on again")
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

        if let expiresAt = credentials.expiresAt, expiresAt <= Date() {
            report(
                "the Claude Code access token expired at \(expiresAt); waiting for "
                    + "the CLI to renew it")
            return Self.refreshInterval
        }
        return await fetchWindows(using: credentials, onRefresh: onRefresh)
    }

    /// The half of a poll that needs no keychain: one request against the
    /// usage endpoint, and the backoff its answer earns.
    ///
    /// The request is a suspension point `stop()` can land in, so its answer
    /// is published only if the poll that asked for it is still wanted —
    /// otherwise a reply that arrived a moment too late would restore the
    /// windows `stop()` had just cleared. The test is the calling task's own
    /// cancellation rather than `pollTask != nil`, because a quick off/on of
    /// the setting leaves a *new* task in that property while this
    /// continuation still belongs to the cancelled one.
    private func fetchWindows(
        using credentials: ClaudeCredentials,
        onRefresh: @Sendable @escaping () async -> Void
    ) async -> Duration {
        do {
            let fetched = try await fetch(token: credentials.accessToken)
            guard !Task.isCancelled else { return Self.refreshInterval }
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
        } catch ClaudeLimitsError.unauthorized {
            return reject(credentials.origin, .unauthorized)
        } catch ClaudeLimitsError.missingScope {
            return reject(credentials.origin, .missingScope)
        } catch ClaudeLimitsError.badStatus(let code) {
            report("Claude usage endpoint returned HTTP \(code)")
            return Self.refreshInterval
        } catch {
            report("Claude usage request failed: \(error.localizedDescription)")
            return Self.refreshInterval
        }
    }

    /// What a token the endpoint will not accept costs, which is not the same
    /// thing for the two items it can come from.
    ///
    /// The CLI's token rotates on its own, so a 401 on it is a stale copy and
    /// the cure is to read the item again on the next poll. The one the user
    /// pasted does not rotate and nothing will fix it but another paste — so
    /// the poll stops rather than asking a dead token for limits every five
    /// minutes, which is how a third-party poller earns a persistent 429.
    /// `stop(clearingState:)` is what keeps both the state and the token
    /// across that stop.
    private func reject(_ origin: ClaudeTokenOrigin, _ rejection: Rejection) -> Duration {
        switch origin {
        case .managed:
            state.store(.tokenRejected)
            report(
                "the Claude token you gave Sissy \(rejection.reason); replace it in Settings › "
                    + "Providers with a fresh `claude setup-token`")
            stop(clearingState: false)
        case .cli:
            cached = nil
            report("Claude Code's own token \(rejection.reason); \(rejection.cliOutlook)")
        }
        return Self.refreshInterval
    }

    /// Why a token was turned away, and what that means for the CLI's own.
    ///
    /// The outlook is not shared: a 401 is a copy that went stale and the CLI
    /// renews it on its own, while a missing scope is baked into the token at
    /// minting and no renewal will add one. One wording for both would promise
    /// a fix that cannot arrive.
    enum Rejection {
        case unauthorized
        case missingScope

        var reason: String {
            switch self {
            case .unauthorized: return "was rejected (HTTP 401)"
            case .missingScope: return "does not carry the \(requiredScope) scope"
            }
        }

        var cliOutlook: String {
            switch self {
            case .unauthorized: return "waiting for the CLI to renew it"
            case .missingScope:
                return "which renewing it will not change; Claude limits stay hidden"
            }
        }
    }

    /// The one request this whole type makes, built in one place so the poll
    /// and the check a paste runs cannot ask the endpoint different questions
    /// — a token accepted by the second and refused by the first would be the
    /// worst outcome this feature has.
    private static func usageRequest(token: String) -> URLRequest {
        var request = URLRequest(url: usageURL, timeoutInterval: requestTimeout)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Whether the endpoint accepts a token, asked before it is stored.
    ///
    /// `claude setup-token` publishes no expiry and no scope list anywhere
    /// Sissy can read, so the endpoint is the only thing that can tell a good
    /// paste from a bad one. Running that check at the moment of pasting is
    /// what stops a mistyped or under-scoped token from becoming gauges that
    /// simply never arrive.
    static func verify(
        token: String,
        transport: ClaudeUsageTransport = ClaudeLimitsProbe.liveTransport
    ) async -> ClaudeTokenVerification {
        do {
            let (data, response) = try await transport(usageRequest(token: token))
            guard let http = response as? HTTPURLResponse else { return .accepted }
            switch http.statusCode {
            case 200:
                return parse(
                    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                ).isEmpty ? .acceptedWithoutWindows : .accepted
            case 401:
                return .rejected
            case 403 where mentionsRequiredScope(data):
                return .missingScope
            case 429:
                return .rateLimited
            default:
                return .failed("The endpoint answered HTTP \(http.statusCode).")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func fetch(token: String) async throws -> [UsageWindow] {
        let (data, response) = try await transport(Self.usageRequest(token: token))
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 { throw ClaudeLimitsError.rateLimited }
            if http.statusCode == 401 { throw ClaudeLimitsError.unauthorized }
            if http.statusCode == 403, Self.mentionsRequiredScope(data) {
                throw ClaudeLimitsError.missingScope
            }
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

    /// Whether a 403 is the one a user can act on.
    ///
    /// The endpoint answers 403 naming the scope it wanted when a token was
    /// minted without `user:profile`, which is a token to replace rather than
    /// a transient failure. Every other 403 is left as a plain bad status,
    /// because guessing at it would tell a user to re-paste a token that was
    /// never the problem.
    static func mentionsRequiredScope(_ data: Data) -> Bool {
        guard let body = String(data: data, encoding: .utf8) else { return false }
        return body.contains(requiredScope)
    }

    /// Buckets that report no `utilization`, or no reset, are dropped: a
    /// window without both halves cannot be drawn, and the plan-scoped
    /// buckets the endpoint sends alongside these two arrive that way.
    static func parse(_ payload: [String: Any]) -> [UsageWindow] {
        buckets.compactMap { bucket in
            guard let raw = payload[bucket.key] as? [String: Any],
                let resetsAt = parseReset(raw["resets_at"]),
                let usedPercent = raw["utilization"] as? Double
            else { return nil }
            return UsageWindow(
                minutes: bucket.minutes,
                usedPercent: usedPercent,
                resetsAt: resetsAt
            )
        }
    }

    /// `resets_at` is accepted both as epoch seconds and as an ISO-8601
    /// string: the endpoint is undocumented, so the parse does not bet on one.
    /// The string form is measured to carry a `+00:00` offset and microsecond
    /// precision, which only the reader's full parse accepts.
    private static func parseReset(_ raw: Any?) -> Date? {
        if let epoch = raw as? Double {
            return Date(timeIntervalSince1970: epoch)
        }
        if let text = raw as? String {
            return UsageReaderShared.parseTimestamp(text)
        }
        return nil
    }
}

/// One request against the usage endpoint. The seam the tests replace.
typealias ClaudeUsageTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

/// What the endpoint said about a token someone just pasted.
///
/// Every case is worded for the person holding the token: it either works, or
/// it names the next thing they can do about it. `acceptedWithoutWindows` is
/// deliberately not a failure — the token authenticated, and a plan that
/// publishes no buckets is an account fact rather than a bad paste.
enum ClaudeTokenVerification: Sendable, Equatable {
    case accepted
    case acceptedWithoutWindows
    case rejected
    case missingScope
    case rateLimited
    case failed(String)

    var isUsable: Bool {
        switch self {
        case .accepted, .acceptedWithoutWindows: return true
        case .rejected, .missingScope, .rateLimited, .failed: return false
        }
    }
}

enum ClaudeLimitsError: Error {
    case rateLimited
    /// The token is not accepted. Separate from `badStatus` because it is the
    /// only status whose meaning depends on which item the token came from.
    case unauthorized
    /// The token works but was minted without the scope the endpoint wants.
    case missingScope
    case badStatus(Int)
    case malformedPayload
}
