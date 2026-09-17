import Foundation

/// Asks OpenAI what a Codex account's limits are, rather than waiting for the
/// CLI to mention them.
///
/// Codex publishes its windows on its own `token_count` events, which is a
/// reading that only arrives when someone takes a turn: measured 2026-09-17,
/// the freshest rollout on this machine was 1 h 51 m old and two points behind
/// what the vendor said at that moment. That was documented as a ceiling —
/// "always one Codex turn behind" — and it is not one. The same block is at
/// `chatgpt.com/backend-api/wham/usage`, answered against the account's own
/// access token, so a poll and a refresh button both mean something.
///
/// One reader per account, which is what makes more than one account possible:
/// the account *is* the credential, so nothing here ever picks between two of
/// them. The CLI's own credential is one such reader, built with `account`
/// nil because which account that file holds is the CLI's to decide and can
/// change under Sissy at any time.
///
/// The three rules the Claude readers next door live by hold here too: the
/// poll is slow, a 429 backs off hard, and a failure leaves the panel on its
/// previous row rather than surfacing an error nobody can act on.
actor CodexUsageSource: SourceSignals {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let requestTimeout: TimeInterval = 15
    private static let refreshInterval: Duration = .seconds(300)
    /// Header OpenAI selects a workspace with. A login can hold several and
    /// they are metered separately, so a reading without it is the vendor's
    /// choice of account rather than the user's.
    private static let accountHeader = "ChatGPT-Account-Id"

    /// Which account this reader was built for, and nil for the CLI's own
    /// credential — that file answers for whichever account `codex` is signed
    /// in as, which is not this reader's to fix or to remember.
    let account: String?

    nonisolated private let published = LockedValue(ProviderSignals())
    /// The account the last reading actually came back for, published outside
    /// the actor because the row it belongs to is decided while this reader is
    /// still holding itself. Nil until one lands.
    nonisolated private let observed = LockedValue<String?>(nil)

    /// Where the credential comes from. Injectable for the reason the Claude
    /// readers' is: the keychain is what can raise a dialog, and a test of the
    /// polling contract must be able to answer for one without a keychain.
    private let credentialSource: @Sendable (Bool) async -> CodexCredentialReading
    /// The network half, injectable so a test of the refresh contract never
    /// reaches OpenAI.
    private let fetchSource: @Sendable (CodexCredential) async throws -> CodexUsagePayload.Reading
    /// Workspace name recorded when the account was linked, which the reply
    /// does not carry: OpenAI names the account it answered for by id only.
    private let workspace: String?

    private var retired = false
    private var mayInteract = false
    private var pollTask: Task<Void, Never>?
    private var firstRequest: Task<Duration, Never>?
    private var generation = 0
    private var lastReported: String?

    init(
        account: String? = nil,
        workspace: String? = nil,
        credentialSource: @escaping @Sendable (Bool) async -> CodexCredentialReading,
        fetchSource:
            @escaping @Sendable (CodexCredential) async throws ->
            CodexUsagePayload.Reading = fetch
    ) {
        self.account = account
        self.workspace = workspace
        self.credentialSource = credentialSource
        self.fetchSource = fetchSource
    }

    nonisolated func currentSignals() -> ProviderSignals { published.load().live() }

    /// Whose reading this is: the account the reader was built for, or the one
    /// the CLI's file turned out to name.
    nonisolated var observedAccount: String? { account ?? observed.load() }

    func start(userInitiated: Bool, onRefresh: @Sendable @escaping () async -> Void) {
        guard !retired, pollTask == nil else { return }
        _ = begin(userInitiated: userInitiated, onRefresh: onRefresh)
    }

    /// Starts the loop and hands back the first request, so an explicit
    /// refresh stays pending until credential, network and publication have
    /// all completed rather than ending on the hand-off.
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

    /// Stops the loop and drops what it published, because the aggregator
    /// rebuilds every slice from `currentSignals()` and a cancelled task that
    /// kept its answer would leave gauges up for a reader that is gone.
    ///
    /// The rollout's own windows are unaffected: they are the adapter's, and
    /// this reader stopping is what puts the row back on them.
    func stop(clearingState: Bool = true) {
        cancelRequests()
        observed.store(nil)
        published.update {
            $0.windows = []
            $0.credits = nil
            $0.account = nil
            $0.plan = nil
            $0.limitsObservedAt = nil
            if clearingState { $0.limitsState = .quiet }
        }
        lastReported = nil
    }

    /// Stops this reader for good, for an account that is no longer linked.
    /// Distinct from `stop()` for the reason `ClaudeWebSource.retire` is: a
    /// rebuild suspends, so a start that read the old set must not give a
    /// discarded reader a poll loop nothing holds.
    func retire() {
        retired = true
        stop()
    }

    private func cancelRequests() {
        generation &+= 1
        pollTask?.cancel()
        firstRequest?.cancel()
        pollTask = nil
        firstRequest = nil
    }

    /// Re-reads the credential and polls at once, returning only once that
    /// request has finished. Deliberately not `stop()` first: that drops the
    /// windows, and a refresh that blanks the gauges it is restoring reads as
    /// a failure for as long as the request takes.
    func refresh(onRefresh: @Sendable @escaping () async -> Void) async {
        if case .rateLimited(let until) = published.load().limitsState, until > Date() { return }
        cancelRequests()
        lastReported = nil
        let request = begin(userInitiated: true, onRefresh: onRefresh)
        await withTaskCancellationHandler {
            _ = await request.value
        } onCancel: {
            request.cancel()
        }
    }

    /// One poll. Returns how long to wait before the next one. Internal rather
    /// than private so a test can run exactly one and assert what it published.
    func refreshOnce(onRefresh: @Sendable @escaping () async -> Void) async -> Duration {
        let stamp = generation
        let before = published.load()
        let delay = await readAndFetch(generation: stamp)
        guard stamp == generation, !Task.isCancelled else { return delay }
        if published.load() != before { await onRefresh() }
        return delay
    }

    private enum Credential {
        case ready(CodexCredential)
        case wait(Duration)
    }

    /// Read on every poll rather than held.
    ///
    /// `ClaudeWebSource` holds its session because reading it can raise a
    /// dialog; neither credential here can — one is a file, the other is an
    /// item Sissy wrote — and holding one has a cost that outweighs the read.
    /// The CLI's `auth.json` is rewritten by `codex login`, and its tokens
    /// live ten days: a reader that kept the first one it saw would go on
    /// asking OpenAI about the account the user *left*, under the name the
    /// tail had already moved on to, until that token expired. Two accounts on
    /// one row, for up to ten days.
    private func currentCredential(generation stamp: Int) async -> Credential {
        let interactive = mayInteract
        mayInteract = false
        let outcome = await credentialSource(interactive)
        guard stamp == generation, !Task.isCancelled else { return .wait(Self.refreshInterval) }
        switch outcome {
        case .found(let found):
            published.update {
                if $0.limitsState.isAnsweredByACredentialRead { $0.limitsState = .quiet }
            }
            // An expired token keeps the previous reading rather than blanking
            // it: the credential is there and something else renews it — the
            // CLI on its own runs, or `CodexOAuth` for an account Sissy owns —
            // so the honest row is the last reading with its age on it.
            guard !found.isExpired() else {
                report("the Codex access token has expired; waiting for it to be renewed")
                return .wait(Self.refreshInterval)
            }
            observed.store(found.userId)
            return .ready(found)
        case .missing:
            publishFailure(.signedOut)
            report("no Codex credential to read the limits with")
        case .signedOut:
            publishFailure(.signedOut)
            report("Codex is signed out, or running on an API key; there are no limits to read")
        case .needsAuthorization:
            publishFailure(.needsAuthorization)
            report("the Codex credential is there and this read was not allowed to ask for it")
        case .refused:
            publishFailure(.refused)
            report("reading the Codex credential was refused; the source stops until restarted")
            cancelRequests()
        case .expired:
            publishFailure(.sessionExpired)
            report("the Codex credential is spent and could not be renewed; link it again")
        case .unreadable(let why):
            report("the Codex credential could not be read: \(why)")
        }
        return .wait(Self.refreshInterval)
    }

    private func readAndFetch(generation stamp: Int) async -> Duration {
        let credential: CodexCredential
        switch await currentCredential(generation: stamp) {
        case .ready(let found): credential = found
        case .wait(let delay): return delay
        }
        do {
            let reading = try await fetchSource(credential)
            guard stamp == generation, !Task.isCancelled else { return Self.refreshInterval }
            if let named = reading.accountId, let asked = credential.accountId, named != asked {
                report("OpenAI answered for a different account than the one asked for")
            }
            publish(reading)
            return Self.refreshInterval
        } catch {
            guard stamp == generation, !Task.isCancelled else { return Self.refreshInterval }
            return handle(error)
        }
    }

    /// What the row takes from one reply.
    ///
    /// The workspace's name comes from the link rather than from the reply,
    /// which names the account by id only — and it decorates the address the
    /// reply does carry, because an account line with an organisation and no
    /// address is the half nobody recognises.
    private func publish(_ reading: CodexUsagePayload.Reading) {
        published.update {
            $0.windows = reading.windows
            $0.credits = reading.credits
            $0.plan = reading.plan ?? $0.plan
            $0.account = ProviderAccount(
                email: reading.account?.email, organization: workspace)
            $0.limitsState = .quiet
            $0.limitsObservedAt = Date()
        }
    }

    /// What a failed request costs, and what it says.
    ///
    /// A 401 is the credential having died, which is the one outcome the user
    /// can act on: the held copy is dropped so the next poll reads it again
    /// rather than spending a token OpenAI has retired. The windows stay,
    /// because the last reading and its age are still true and this row's
    /// other source — the CLI's own turns — is still writing them.
    private func handle(_ error: Error) -> Duration {
        if case UsageRequestError.rateLimited(let retryAfter) = error {
            let backoff = UsageRequestError.backoffSeconds(retryAfter: retryAfter)
            let until = Date().addingTimeInterval(backoff)
            published.update { $0.limitsState = .rateLimited(until: until) }
            report("OpenAI answered 429; backing off until \(until)")
            return .seconds(backoff)
        }
        if case UsageRequestError.badStatus(let code) = error, code == 401 || code == 403 {
            published.update { $0.limitsState = .sessionExpired }
            report("the Codex credential was refused (status \(code)); sign in again")
            return Self.refreshInterval
        }
        report("the Codex usage request failed: \(error.localizedDescription)")
        return Self.refreshInterval
    }

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

    /// One poll's worth of OpenAI.
    ///
    /// No product token and no cookie: measured 2026-09-17, the endpoint
    /// answers 200 to a bearer token under any User-Agent, which is what
    /// separates it from claude.ai's usage route and is why this reader needs
    /// no browser to run.
    static func fetch(_ credential: CodexCredential) async throws -> CodexUsagePayload.Reading {
        var request = URLRequest(url: usageURL, timeoutInterval: requestTimeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId = credential.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: accountHeader)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageRequestError.malformedPayload
        }
        if http.statusCode == 429 {
            throw UsageRequestError.rateLimited(retryAfter: UsageRequestError.retryAfter(http))
        }
        guard http.statusCode == 200 else { throw UsageRequestError.badStatus(http.statusCode) }
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageRequestError.malformedPayload
        }
        return CodexUsagePayload.reading(body, observedAt: Date())
    }
}
