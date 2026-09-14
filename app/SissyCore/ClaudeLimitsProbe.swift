import Foundation

/// Polls the endpoint Claude Code's own `/usage` reads, so the panel can show
/// the 5-hour and weekly subscription windows next to Codex's. The credits the
/// CLI caches for itself are a separate source — `ClaudeProfileSource` reads
/// those off disk, with no grant to lapse and no network.
///
/// The endpoint is undocumented, which drives three rules here: the poll is
/// slow, a 429 backs off hard (third-party pollers hammering it every 30 s are
/// a known way to earn a persistent 429), and a failure leaves the panel on its
/// previous row rather than surfacing an error the user cannot act on. Its
/// shape is measured, never inferred: the buckets meter in percent and report
/// their dollar fields as null.
actor ClaudeLimitsProbe: SourceSignals {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let betaHeader = "oauth-2025-04-20"
    private static let requestTimeout: TimeInterval = 10
    private static let refreshInterval: Duration = .seconds(300)
    private static let rateLimitedBackoff: Duration = .seconds(1800)
    private static let keychainTimeout: Duration = .seconds(20)

    /// Windows, why they are missing when they are, and when the last
    /// successful reading landed — published together so the row that draws
    /// the gauges and the row that explains their absence come off one value.
    nonisolated private let published = LockedValue(ProviderSignals())
    /// Where the CLI's token comes from. Injectable for the same reason
    /// `ClaudeCredentialsStore.loadOffPool` takes a `lookup`: reading the
    /// keychain is what can raise a system dialog, and a test of the switch
    /// that starts this probe has to be able to answer for one without
    /// putting it on a screen.
    private let credentialsSource: @Sendable (Duration, Bool) async -> ClaudeCredentialsLookup
    /// The network half, injectable for the same reason: a test of the refresh
    /// contract must not reach Anthropic to observe it.
    private let fetchSource: @Sendable (String) async throws -> [UsageWindow]
    /// Whether the next credential read may put a dialog on screen.
    ///
    /// Set only by a `start` the user asked for, and spent on the first read
    /// that needs it. Everything after that — every poll, and every launch
    /// that merely finds the setting already on — reads silently, which is the
    /// difference between a permission asked for when a switch is flipped and
    /// a stack of dialogs waiting on a Mac nobody was sitting at.
    private var mayInteract = false
    private var pollTask: Task<Void, Never>?
    /// The request a refresh awaits, so "refreshing" ends when Claude has
    /// answered rather than when the task was handed off.
    private var firstRequest: Task<Duration, Never>?
    /// Bumped by every cancellation, so a request in flight when the probe was
    /// stopped or restarted cannot publish over the run that replaced it.
    private var generation = 0
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

    /// `credentials` leads so a trailing closure still names the keychain: it
    /// is the half nearly every test answers for, and the half that decides
    /// whether macOS is asked anything at all.
    init(
        credentials: @escaping @Sendable (Duration, Bool) async -> ClaudeCredentialsLookup = {
            await ClaudeCredentialsStore.loadOffPool(timeout: $0, allowingInteraction: $1)
        },
        fetch: @escaping @Sendable (String) async throws -> [UsageWindow] = {
            try await ClaudeLimitsProbe.fetch(token: $0)
        }
    ) {
        credentialsSource = credentials
        fetchSource = fetch
    }

    /// Live windows, expired buckets dropped — a window past its reset
    /// describes a period that no longer exists, same rule the Codex reader
    /// applies to its own.
    nonisolated func currentSignals() -> ProviderSignals { published.load().live() }

    /// Starts the poll loop. `onRefresh` fires whenever the published reading
    /// changes — a new set of windows, or a new reason they are missing — so a
    /// steady state costs no emits. Idempotent.
    ///
    /// `userInitiated` says whether someone just flipped the switch. Only that
    /// start is allowed to raise the keychain dialog; the one a launch makes
    /// because the setting was already on reads silently and shows no limits
    /// if the grant has gone stale.
    func start(userInitiated: Bool, onRefresh: @Sendable @escaping () async -> Void) {
        guard pollTask == nil else { return }
        _ = begin(userInitiated: userInitiated, onRefresh: onRefresh)
    }

    /// Starts the loop and hands back the first request, so an explicit
    /// refresh stays pending until credentials, network and publication have
    /// all completed rather than ending on the hand-off.
    private func begin(userInitiated: Bool, onRefresh: @Sendable @escaping () async -> Void) -> Task<
        Duration, Never
    > {
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

    /// Stops the poll loop and drops the windows it had published.
    ///
    /// Dropping them is the whole job. The aggregator rebuilds every slice
    /// from `currentSignals()`, so a cancelled task publishes nothing new but
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
    func stop(clearingState: Bool = true) {
        cancelRequests()
        cached = nil
        published.update {
            $0.windows = []
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

    /// Re-reads the credentials with the dialog allowed and polls at once,
    /// returning only once that request has finished.
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

    /// Logs `message` the first time this condition is seen, and again only
    /// once something else has happened in between.
    private func report(_ message: String) {
        guard lastReported != message else { return }
        lastReported = message
        sissyLog("sissy: \(message)")
    }

    /// One poll. Returns how long to wait before the next one.
    ///
    /// `onRefresh` fires on any change to the published reading, not only on
    /// new windows: an authorization that lapsed is a change the panel has to
    /// show, and it arrives on a day where no token event will follow it. A
    /// failed request publishes nothing, which is what preserves the age of
    /// the last successful reading beside the windows it produced.
    ///
    /// Internal rather than private so a test can run exactly one and assert
    /// on what it published. Waiting on the poll loop instead means waiting on
    /// the scheduler: the read is recorded before the outcome is classified,
    /// so an assertion hung off the read passes or fails by luck.
    func refreshOnce(onRefresh: @Sendable @escaping () async -> Void) async -> Duration {
        let stamp = generation
        let before = published.load()
        let delay = await readAndFetch(generation: stamp)
        guard stamp == generation else { return delay }
        if Task.isCancelled && published.load().limitsState != .refused { return delay }
        if published.load() != before { await onRefresh() }
        return delay
    }

    /// A token to spend, or the wait its absence earns.
    private enum Credentials {
        case ready(ClaudeCredentials)
        case wait(Duration)
    }

    /// The keychain half of a poll, and the whole of what decides whether
    /// macOS is asked anything.
    ///
    /// A held token is spent without touching the keychain at all: it is good
    /// for hours while the poll runs every five minutes, and every read is
    /// another chance to meet a grant that has gone stale.
    ///
    /// The read is a suspension a `stop()` or a second `refresh` can land in,
    /// which is what `stamp` guards. The generation is checked rather than
    /// `pollTask != nil`, because a quick off/on of the setting leaves a *new*
    /// task in that property while this continuation still belongs to the
    /// cancelled one.
    private func currentCredentials(generation stamp: Int) async -> Credentials {
        if let held = cached, held.isValid() { return .ready(held) }
        let interactive = mayInteract
        mayInteract = false
        let outcome = await credentialsSource(Self.keychainTimeout, interactive)
        guard stamp == generation, !Task.isCancelled else { return .wait(Self.refreshInterval) }
        switch outcome {
        case .found(let found):
            cached = found
            published.update { $0.limitsState = .quiet }
            if let expiresAt = found.expiresAt, expiresAt <= Date() {
                report(
                    "the Claude Code access token expired at \(expiresAt); waiting for "
                        + "the CLI to renew it")
                return .wait(Self.refreshInterval)
            }
            return .ready(found)
        case .absent:
            publishFailure(.signedOut)
            report(
                "no Claude Code credentials in the keychain under "
                    + "\(ClaudeCredentialsStore.keychainService); limits stay hidden until "
                    + "you sign into the CLI")
        case .denied:
            publishFailure(.refused)
            report(
                "keychain access to \(ClaudeCredentialsStore.keychainService) was refused; "
                    + "Claude Code limits stay hidden. Grant it in Keychain Access, or turn "
                    + "the setting off")
            // Alone among the failures, this one stops the loop: the user said
            // no, and re-asking them every five minutes is harassment.
            pollTask?.cancel()
            pollTask = nil
        // Alive, deliberately. Nobody refused anything — this read was simply
        // not allowed to ask, and the grant it wants back can return without
        // Sissy doing a thing: the CLI rewrites the item, or the user allows it
        // in Keychain Access. Stopping here would make a stale grant
        // indistinguishable from a refusal, and both would then need a relaunch.
        case .interactionRequired:
            publishFailure(.needsAuthorization)
            report(
                "the keychain will not release \(ClaudeCredentialsStore.keychainService) "
                    + "without asking, and this read did not ask; Claude limits stay hidden "
                    + "until you switch them off and on again")
        case .unreadable(let status):
            report("could not read Claude credentials (OSStatus \(status))")
        case .timedOut:
            report(
                "the keychain did not answer within \(Self.keychainTimeout); Claude limits "
                    + "are waiting on an authorization prompt")
        }
        return .wait(Self.refreshInterval)
    }

    /// One request against the usage endpoint, and the backoff its answer
    /// earns.
    ///
    /// The request is the other suspension `stamp` guards: a reply that
    /// arrived a moment too late would restore windows a `stop()` had just
    /// cleared.
    private func readAndFetch(generation stamp: Int) async -> Duration {
        let credentials: ClaudeCredentials
        switch await currentCredentials(generation: stamp) {
        case .ready(let found): credentials = found
        case .wait(let delay): return delay
        }
        do {
            let windows = try await fetchSource(credentials.accessToken)
            guard stamp == generation, !Task.isCancelled else { return Self.refreshInterval }
            published.update {
                $0.windows = windows
                $0.limitsState = .quiet
                $0.limitsObservedAt = Date()
            }
            return Self.refreshInterval
        } catch {
            guard stamp == generation, !Task.isCancelled else { return Self.refreshInterval }
            if case ClaudeLimitsError.rateLimited = error {
                report(
                    "the Claude usage endpoint answered 429; backing off for "
                        + "\(Self.rateLimitedBackoff)")
                return Self.rateLimitedBackoff
            }
            // The token was refused rather than the request: drop it so the
            // next poll reads the keychain again instead of retrying a
            // credential the CLI has already rotated.
            if case ClaudeLimitsError.badStatus(let code) = error, code == 401 || code == 403 {
                self.cached = nil
            }
            report("the Claude usage request failed: \(error.localizedDescription)")
            return Self.refreshInterval
        }
    }

    /// Publishes why the windows are missing, and takes them down with it: a
    /// gauge left standing under a sentence explaining that there is no
    /// reading behind it is worse than no gauge.
    private func publishFailure(_ state: ProviderLimitsState) {
        published.update {
            $0.limitsState = state
            $0.windows = []
        }
    }

    private static func fetch(token: String) async throws -> [UsageWindow] {
        var request = URLRequest(url: usageURL, timeoutInterval: requestTimeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeLimitsError.malformedPayload }
        if http.statusCode == 429 { throw ClaudeLimitsError.rateLimited }
        guard http.statusCode == 200 else { throw ClaudeLimitsError.badStatus(http.statusCode) }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeLimitsError.malformedPayload
        }
        return parse(payload)
    }

    /// The two windows the panel draws, off the body every Claude usage
    /// source answers with. The parse itself lives in `ClaudeUsagePayload`,
    /// which claude.ai and the CLI's own cache read through too.
    static func parse(_ payload: [String: Any]) -> [UsageWindow] {
        ClaudeUsagePayload.windows(payload)
    }
}

enum ClaudeLimitsError: Error {
    case rateLimited
    case badStatus(Int)
    case malformedPayload
}
