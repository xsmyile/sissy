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
actor CodexUsageSource: SourceSignals, LimitsPolling {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let requestTimeout: TimeInterval = 15
    static let refreshInterval: Duration = .seconds(300)
    static let vendor = "OpenAI"
    static var limitsState: WritableKeyPath<ProviderSignals, ProviderLimitsState> {
        \.limitsState
    }
    /// Header OpenAI selects a workspace with. A login can hold several and
    /// they are metered separately, so a reading without it is the vendor's
    /// choice of account rather than the user's.
    private static let accountHeader = "ChatGPT-Account-Id"

    /// Which account this reader was built for, and nil for the CLI's own
    /// credential — that file answers for whichever account `codex` is signed
    /// in as, which is not this reader's to fix or to remember.
    let account: String?

    nonisolated let published = LockedValue(ProviderSignals())
    /// The account the last reading actually came back for, published outside
    /// the actor because the row it belongs to is decided while this reader is
    /// still holding itself. Nil until one lands.
    nonisolated private let observed = LockedValue<String?>(nil)

    /// Where the credential comes from. Injectable for the reason the Claude
    /// readers' is: the keychain is what can raise a dialog, and a test of the
    /// polling contract must be able to answer for one without a keychain.
    private let credentialSource: @Sendable (Bool) async -> CodexCredentialReading
    /// How a credential OpenAI refused is renewed before the row gives up on
    /// it, and nil for the CLI's own, which only `codex login` may renew.
    private let renewRefused: (@Sendable (CodexCredential) async -> CodexCredentialReading)?
    /// The network half, injectable so a test of the refresh contract never
    /// reaches OpenAI.
    private let fetchSource: @Sendable (CodexCredential) async throws -> CodexUsagePayload.Reading
    /// The list that dates this account's resets, injectable for the reason
    /// the usage fetch is.
    private let creditsSource: @Sendable (CodexCredential) async throws -> [CodexResetCredits.Credit]
    /// The spend, injectable so a test of its retry contract never spends one.
    private let consumeSource:
        @Sendable (CodexCredential, String, String?) async throws -> CodexResetCredits.Answer
    /// Workspace name recorded when the account was linked, which the reply
    /// does not carry: OpenAI names the account it answered for by id only.
    let workspace: String?
    /// Where a refusal is written down so the next run honours it, keyed by
    /// this reader's own credential.
    let backoff: LimitsBackoffSlot?

    private var retired = false
    var loop = LimitsLoop()
    /// The access token a renewal handed over that OpenAI refused as well.
    /// The next poll reads that same token back from the keychain, and
    /// renewing it on every refusal rotated the grant once a poll for as long
    /// as the vendor kept refusing; a different token, from a relink or the
    /// CLI, is renewed as any other.
    private var refusedAfterRenewal: String?
    /// The reset a press spends, the soonest to lapse, as the last list named
    /// it. Nil sends none and lets OpenAI pick, which its own CLI also does.
    private var nextCredit: String?
    /// The spend whose answer never arrived. Every press sends it again until
    /// OpenAI answers it, because the vendor redeems one request id once: a
    /// second press that minted its own could spend a second reset beside an
    /// attempt that may already have landed. Held here rather than by the
    /// page, which navigating away from is enough to lose.
    private var unanswered: (requestID: String, creditID: String?)?

    init(
        account: String? = nil,
        workspace: String? = nil,
        credentialSource: @escaping @Sendable (Bool) async -> CodexCredentialReading,
        renewRefused: (@Sendable (CodexCredential) async -> CodexCredentialReading)? = nil,
        fetchSource:
            @escaping @Sendable (CodexCredential) async throws ->
            CodexUsagePayload.Reading = fetch,
        creditsSource:
            @escaping @Sendable (CodexCredential) async throws -> [CodexResetCredits.Credit] =
            CodexResetCredits.fetchCredits,
        consumeSource:
            @escaping @Sendable (CodexCredential, String, String?) async throws ->
            CodexResetCredits.Answer = {
                try await CodexResetCredits.consume($0, requestID: $1, creditID: $2)
            },
        backoff: LimitsBackoffSlot? = nil
    ) {
        self.account = account
        self.workspace = workspace
        self.backoff = backoff
        self.credentialSource = credentialSource
        self.renewRefused = renewRefused
        self.fetchSource = fetchSource
        self.creditsSource = creditsSource
        self.consumeSource = consumeSource
    }

    nonisolated func currentSignals() -> ProviderSignals { published.load().live() }

    /// Whose reading this is: the account the reader was built for, or the one
    /// the CLI's file turned out to name.
    nonisolated var observedAccount: String? { account ?? observed.load() }

    func start(userInitiated: Bool, onRefresh: @Sendable @escaping () async -> Void) {
        guard !retired, loop.pollTask == nil else { return }
        _ = begin(userInitiated: userInitiated, onRefresh: onRefresh)
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
        nextCredit = nil
        published.update {
            $0.windows = []
            $0.credits = nil
            $0.resets = nil
            $0.account = nil
            $0.plan = nil
            $0.limitsObservedAt = nil
            if clearingState { $0.limitsState = .quiet }
        }
        loop.lastReported = nil
    }

    /// Stops this reader for good, for an account that is no longer linked.
    /// Distinct from `stop()` for the reason `ClaudeWebSource.retire` is: a
    /// rebuild suspends, so a start that read the old set must not give a
    /// discarded reader a poll loop nothing holds.
    func retire() {
        retired = true
        stop()
    }

    /// Re-reads the credential and polls at once, returning only once that
    /// request has finished. Deliberately not `stop()` first, for the reason
    /// `restart` carries.
    ///
    /// `userInitiated` is what lets the credential read ask for the keychain.
    /// A reader retired while a caller was suspended stays retired: this is
    /// the other place a poll loop is started, and one started here would
    /// poll for an account nothing holds any more.
    func refresh(
        userInitiated: Bool = true, onRefresh: @Sendable @escaping () async -> Void
    ) async {
        guard !retired else { return }
        await restart(userInitiated: userInitiated, onRefresh: onRefresh)
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
        let outcome = await credentialSource(takeInteraction())
        guard isCurrent(stamp) else { return .wait(Self.refreshInterval) }
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
            halt()
        case .expired:
            publishFailure(.sessionExpired)
            report("the Codex credential is spent and could not be renewed; link it again")
        case .unreadable(let why):
            report("the Codex credential could not be read: \(why)")
        }
        return .wait(Self.refreshInterval)
    }

    func readAndFetch(generation stamp: Int) async -> Duration {
        if let wait = await recordedBackoff(generation: stamp) { return wait }
        let credential: CodexCredential
        switch await currentCredential(generation: stamp) {
        case .ready(let found): credential = found
        case .wait(let delay): return delay
        }
        do {
            return try await read(with: credential, generation: stamp)
        } catch {
            guard isCurrent(stamp) else { return Self.refreshInterval }
            guard Self.isRefusal(error), let renewRefused,
                credential.accessToken != refusedAfterRenewal
            else { return await handle(error) }
            return await renewAndReadAgain(
                refused: credential, renewing: renewRefused, generation: stamp)
        }
    }

    private func read(with credential: CodexCredential, generation stamp: Int) async throws
        -> Duration
    {
        var reading = try await fetchSource(credential)
        guard isCurrent(stamp) else { return Self.refreshInterval }
        if let named = reading.accountId, let asked = credential.accountId, named != asked {
            report("OpenAI answered for a different account than the one asked for")
        }
        let dated = await dated(reading.resets, with: credential)
        guard isCurrent(stamp) else { return Self.refreshInterval }
        reading.resets = dated.resets
        nextCredit = dated.nextCredit
        publish(reading)
        await backoff?.record(nil)
        return Self.refreshInterval
    }

    /// The count with the soonest reset's date and name laid on, and the
    /// count alone when the list could not be read: the count is the answer
    /// the row needs, the date is a caption.
    ///
    /// Asked only while the account holds one, which is what keeps the second
    /// request off the poll of every account that never had any. The reset a
    /// press would spend comes back beside it rather than being set here, so
    /// a poll a newer one has superseded cannot name it.
    private func dated(_ resets: LimitResets?, with credential: CodexCredential) async
        -> (resets: LimitResets?, nextCredit: String?)
    {
        guard var resets, resets.available > 0 else { return (resets, nil) }
        do {
            let next = try await creditsSource(credential).first
            resets.nextExpiry = next?.expiresAt
            resets.title = next?.title
            return (resets, next?.id)
        } catch {
            report("the Codex reset list could not be read: \(error)")
            return (resets, nil)
        }
    }

    // MARK: - Spending a reset

    /// Spends one of this account's resets, then reads the account again so
    /// the windows the vendor just cleared reach the panel with the answer.
    ///
    /// The credential is read the way a poll reads it and never with
    /// interaction, because a spend is not the moment to put a dialog up.
    /// Nothing here moves the row's limits state either: a spend that failed
    /// is the press's answer, and the page words it beside the button rather
    /// than as a notice about the limits. A spend that landed takes one off
    /// the count at once, as OpenAI's desktop client does, so the button does
    /// not outlive the reset it spent when the read after it cannot run.
    func useReset(onRefresh: @Sendable @escaping () async -> Void) async -> LimitResetOutcome {
        guard !retired else { return .unavailable }
        guard case .found(let credential) = await credentialSource(false),
            !credential.isExpired()
        else { return .unavailable }
        let attempt = unanswered ?? (requestID: UUID().uuidString, creditID: nextCredit)
        unanswered = attempt
        let outcome: LimitResetOutcome
        do {
            outcome = LimitResetOutcome(
                try await consumeSource(credential, attempt.requestID, attempt.creditID))
            unanswered = nil
        } catch {
            if Self.isRefusal(error) {
                unanswered = nil
                outcome = .refused
            } else {
                outcome = .unconfirmed
            }
            report("spending a Codex reset did not get an answer: \(error)")
        }
        if outcome == .reset { published.update { $0.resets = $0.resets?.spendingOne() } }
        await refresh(userInitiated: false, onRefresh: onRefresh)
        return outcome
    }

    /// One renewal and one read, and never a second of either: a renewed
    /// token OpenAI refuses too is a link that has ended, and renewing again
    /// would spend the grant on every poll. That token is remembered as
    /// `refusedAfterRenewal`, so a later poll reading it back does not renew
    /// it either.
    ///
    /// A renewal that could not reach an answer keeps the row as it was.
    /// It says nothing about the grant, and the next poll asks again once the
    /// renewal's own backoff allows.
    private func renewAndReadAgain(
        refused: CodexCredential,
        renewing: @Sendable (CodexCredential) async -> CodexCredentialReading,
        generation stamp: Int
    ) async -> Duration {
        let outcome = await renewing(refused)
        guard isCurrent(stamp) else { return Self.refreshInterval }
        switch outcome {
        case .found(let renewed):
            do {
                return try await read(with: renewed, generation: stamp)
            } catch {
                guard isCurrent(stamp) else { return Self.refreshInterval }
                if Self.isRefusal(error) { refusedAfterRenewal = renewed.accessToken }
                return await handle(error)
            }
        case .expired:
            published.update { $0.limitsState = .sessionExpired }
            report("the Codex credential was refused and its renewal was rejected; link it again")
        case .unreadable, .missing, .signedOut, .needsAuthorization, .refused:
            report("the Codex credential was refused and could not be renewed yet")
        }
        return Self.refreshInterval
    }

    private static func isRefusal(_ error: Error) -> Bool {
        guard case UsageRequestError.badStatus(let code) = error else { return false }
        return refusalStatuses.contains(code)
    }

    private static let refusalStatuses: Set<Int> = [401, 403]

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
            $0.resets = reading.resets
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
    /// rather than spending a token OpenAI has retired. For a linked account
    /// it reaches here only once `renewAndReadAgain` has renewed the token
    /// and been refused again. The windows stay,
    /// because the last reading and its age are still true and this row's
    /// other source — the CLI's own turns — is still writing them.
    ///
    /// Who acts on it depends on whose credential it is. A linked account's
    /// is Sissy's, and linking again replaces it. The CLI's is `codex
    /// login`'s, so its refusal is `credentialRefused`: linking would add a
    /// second account and leave this row refused.
    private func handle(_ error: Error) async -> Duration {
        if let wait = await backOff(after: error) { return wait }
        if case UsageRequestError.badStatus(let code) = error, Self.refusalStatuses.contains(code) {
            let refused: ProviderLimitsState = account == nil ? .credentialRefused : .sessionExpired
            published.update { $0.limitsState = refused }
            report("the Codex credential was refused (status \(code)); sign in again")
            return Self.refreshInterval
        }
        report("the Codex usage request failed: \(error)")
        return Self.refreshInterval
    }

    private func publishFailure(_ state: ProviderLimitsState) {
        nextCredit = nil
        published.update {
            $0.limitsState = state
            $0.windows = []
            $0.credits = nil
            $0.resets = nil
        }
    }

    // MARK: - The wire

    /// One poll's worth of OpenAI.
    ///
    /// No product token and no cookie: measured 2026-09-17, the endpoint
    /// answers 200 to a bearer token under any User-Agent, which is what
    /// separates it from claude.ai's usage route and is why this reader needs
    /// no browser to run.
    static func fetch(_ credential: CodexCredential) async throws -> CodexUsagePayload.Reading {
        let body = try await UsageRequestError.object(
            answering: request(usageURL, credential: credential))
        return CodexUsagePayload.reading(body, observedAt: Date())
    }

    /// A request to one of OpenAI's Codex routes, carrying the credential and
    /// the workspace it is asked for.
    static func request(_ url: URL, credential: CodexCredential) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId = credential.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: accountHeader)
        }
        return request
    }
}
