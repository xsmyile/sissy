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
actor ClaudeLimitsProbe: SourceSignals, LimitsPolling {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let betaHeader = "oauth-2025-04-20"
    private static let requestTimeout: TimeInterval = 10
    static let refreshInterval: Duration = .seconds(300)
    static let vendor = "the Claude usage endpoint"
    static var limitsState: WritableKeyPath<AttributedReading, ProviderLimitsState> {
        \.signals.limitsState
    }
    private static let keychainTimeout: Duration = .seconds(20)

    /// Windows, why they are missing when they are, and when the last
    /// successful reading landed — published together so the row that draws
    /// the gauges and the row that explains their absence come off one value.
    ///
    /// The token they were read with rides in the same value, so a reader
    /// can never pair one token's windows with another token's fingerprint.
    nonisolated let published = LockedValue(AttributedReading())

    /// What the probe published, and which credential it was read with.
    struct AttributedReading: Sendable, Equatable {
        var signals = ProviderSignals()
        /// `ClaudeCredentialBlob.fingerprint(of:)` of the access token the
        /// windows and credits were fetched with, nil while there are none.
        ///
        /// The probe cannot name the account a token belongs to, and the
        /// registry that can reads the slot on a clock of its own. This is
        /// what `ClaudeCodeSignals` matches against the registry's
        /// `activeCredential` before laying the reading under its name.
        var credential: String?
    }
    /// Where the CLI's token comes from, under the budget the caller sets.
    ///
    /// Injectable for the same reason `ClaudeCredentialsStore.loadOffPool`
    /// takes a `lookup`: the read is the one piece of external I/O here, and a
    /// test of the loop this probe runs has to answer for it without a
    /// keychain. It takes no interaction flag, because nothing this probe
    /// reads can ask the user anything — `ClaudeCodeCredentials` reads the
    /// CLI's own keychain item through `/usr/bin/security` and falls back to
    /// its file, and neither raises a dialog.
    private let credentialsSource: @Sendable (Duration) async -> ClaudeCredentialsLookup
    /// The network half, injectable for the same reason: a test of the refresh
    /// contract must not reach Anthropic to observe it.
    private let fetchSource: @Sendable (String) async throws -> Reading
    /// Where a refusal is written down so the next run honours it. Nil is a
    /// probe that forgets its block when the process ends, which is every
    /// test that has no opinion about one.
    let backoff: LimitsBackoffSlot?

    /// One answer from the usage endpoint: the windows it drew and what it has
    /// billed against the spend cap.
    ///
    /// The credits ride along rather than being read from the CLI's cached
    /// copy, because that copy only advances when someone types `/usage` and
    /// it is not invalidated when the CLI signs into a different account —
    /// measured 2026-09-15, a config file naming one account still carried the
    /// previous one's spend, in the previous one's currency. A live window
    /// beside a cached figure from another account is two readings on one row.
    struct Reading: Sendable, Equatable {
        let windows: [UsageWindow]
        let credits: ProviderCredits?
    }
    var loop = LimitsLoop()

    /// `credentials` leads so a trailing closure still names the read: it is
    /// the half nearly every test answers for.
    ///
    /// It carries no default. The one this had resolved to an in-process
    /// `SecItemCopyMatching`, which every caller in the app overrode and which
    /// is the only read on this path that could ever raise the legacy
    /// keychain's Allow/Deny panel — a default nothing takes is a dialog
    /// waiting for the first caller that forgets to.
    init(
        credentials: @escaping @Sendable (Duration) async -> ClaudeCredentialsLookup,
        fetch: @escaping @Sendable (String) async throws -> Reading = {
            try await ClaudeLimitsProbe.fetch(token: $0)
        },
        backoff: LimitsBackoffSlot? = nil
    ) {
        credentialsSource = credentials
        fetchSource = fetch
        self.backoff = backoff
    }

    /// Live windows, expired buckets dropped — a window past its reset
    /// describes a period that no longer exists, same rule the Codex reader
    /// applies to its own.
    nonisolated func currentSignals() -> ProviderSignals { published.load().signals.live() }

    /// The live signals with the credential they were read with.
    nonisolated func currentReading() -> AttributedReading {
        var reading = published.load()
        reading.signals = reading.signals.live()
        return reading
    }

    /// Starts the poll loop. `onRefresh` fires whenever the published reading
    /// changes — a new set of windows, or a new reason they are missing — so a
    /// steady state costs no emits. Idempotent.
    ///
    /// It takes no `userInitiated`: the reads this probe makes cannot ask the
    /// user for anything, so a start the user asked for and a start a launch
    /// made do exactly the same thing.
    func start(onRefresh: @Sendable @escaping () async -> Void) {
        guard loop.pollTask == nil else { return }
        _ = begin(userInitiated: false, onRefresh: onRefresh)
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
        published.update {
            $0.signals.windows = []
            $0.signals.credits = nil
            $0.credential = nil
            if clearingState { $0.signals.limitsState = .quiet }
        }
        loop.lastReported = nil
    }

    /// Re-reads the CLI's credential and polls at once, returning only once
    /// that request has finished.
    ///
    /// The gesture behind a user asking for their limits back. The read asks
    /// macOS for nothing, as every read this probe makes: the credential comes
    /// from the CLI's file or through `/usr/bin/security`. Two things stand
    /// between a running probe and a fresh read and this clears both: the
    /// poll task, which makes `start` a no-op while it lives, and the deduped
    /// log line, so the outcome of the read the user just asked for is
    /// actually recorded.
    ///
    /// Deliberately not `stop()` first, for the reason `restart` carries.
    func refresh(onRefresh: @Sendable @escaping () async -> Void) async {
        await restart(userInitiated: false, onRefresh: onRefresh)
    }

    /// A token to spend, or the wait its absence earns.
    private enum Credentials {
        case ready(ClaudeCredentials)
        case wait(Duration)
    }

    /// The credential half of a poll, and the whole of what decides whether
    /// macOS is asked anything.
    ///
    /// Every poll reads it again, and it deliberately holds nothing between
    /// them. The token names the account, so a held one goes on answering for
    /// whoever was signed in when it was read: a `/login` elsewhere leaves the
    /// windows of the account the user just left under the name of the one
    /// they just joined, for as long as the old token lives — measured
    /// 2026-09-16, eight hours, because nothing short of the vendor refusing
    /// it says it is the wrong one. What the hold used to buy is gone anyway.
    /// It was written when this read was `SecItemCopyMatching`, which could
    /// raise the legacy keychain panel and earn a grant that a token rotation
    /// invalidated; the engine now injects `ClaudeCodeCredentials.load`, which
    /// asks macOS for nothing. It is a `/usr/bin/security` spawn, read in the
    /// CLI's own order so the token spent here is the one the account
    /// registry identified, and still only once every five minutes.
    ///
    /// The read is a suspension a `stop()` or a second `refresh` can land in,
    /// which is what `stamp` guards, through `isCurrent(_:)`.
    private func currentCredentials(generation stamp: Int) async -> Credentials {
        let outcome = await credentialsSource(Self.keychainTimeout)
        guard isCurrent(stamp) else { return .wait(Self.refreshInterval) }
        switch outcome {
        case .found(let found):
            published.update {
                if $0.signals.limitsState.isAnsweredByACredentialRead { $0.signals.limitsState = .quiet }
            }
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
                "no stored Claude Code login in the keychain or beside the config; limits "
                    + "stay hidden until the CLI keeps one")
        // Neither can arise here, and saying so is the point. Both are answers
        // macOS gives an in-process `SecItemCopyMatching`; this probe reads the
        // CLI's own item through `/usr/bin/security` or its file, neither of
        // which asks the user anything, so there is nobody to refuse and no
        // grant to go stale. They report rather than publish a state, because
        // a notice telling someone to grant access names a dialog that cannot
        // happen — and `.denied` no longer stops the loop, which it did only
        // to avoid re-asking a question this reader never puts.
        case .denied, .interactionRequired:
            report("the Claude Code credential read answered an outcome it cannot produce")
        case .unreadable(let status):
            report("could not read Claude credentials (OSStatus \(status))")
        case .timedOut:
            report(
                "the Claude Code credential did not come back within "
                    + "\(Self.keychainTimeout); its limits keep their last reading")
        }
        return .wait(Self.refreshInterval)
    }

    /// Drops the block, on the row and in the record.
    ///
    /// For the account switch, which is the one event that makes a refusal
    /// stop being this reader's: the endpoint authenticates a credential, the
    /// block was earned by the one that has just been replaced, and the next
    /// request spends a different token. Without it a switch made inside a
    /// block met no limits at all until the deadline passed — and with the
    /// record on disk, past the relaunch too.
    func clearBackoff() async {
        published.update {
            if case .rateLimited = $0.signals.limitsState { $0.signals.limitsState = .quiet }
        }
        await backoff?.record(nil)
    }

    /// One request against the usage endpoint, and the backoff its answer
    /// earns.
    ///
    /// A 401 or 403 is published rather than merely logged, and it takes the
    /// windows with it. It is the one failure here that says the reading on
    /// screen is *wrong* rather than old: a refused token is precisely the
    /// case where those windows are known to be another account's, and they
    /// would otherwise have stood until each outlived its own reset — up to a
    /// week for the weekly bucket. The two readers that ask a vendor for the
    /// same thing already answer this way; this one was the last that did
    /// not.
    ///
    /// The request is the other suspension `stamp` guards: a reply that
    /// arrived a moment too late would restore windows a `stop()` had just
    /// cleared.
    func readAndFetch(generation stamp: Int) async -> Duration {
        if let wait = await recordedBackoff(generation: stamp) { return wait }
        let credentials: ClaudeCredentials
        switch await currentCredentials(generation: stamp) {
        case .ready(let found): credentials = found
        case .wait(let delay): return delay
        }
        do {
            let reading = try await fetchSource(credentials.accessToken)
            guard isCurrent(stamp) else { return Self.refreshInterval }
            published.update {
                $0.signals.windows = reading.windows
                $0.signals.credits = reading.credits
                $0.signals.limitsState = .quiet
                $0.signals.limitsObservedAt = Date()
                $0.credential = ClaudeCredentialBlob.fingerprint(of: credentials.accessToken)
            }
            await backoff?.record(nil)
            return Self.refreshInterval
        } catch {
            guard isCurrent(stamp) else { return Self.refreshInterval }
            if let wait = await backOff(after: error) { return wait }
            if case UsageRequestError.badStatus(let code) = error, code == 401 || code == 403 {
                publishFailure(.credentialRefused)
                report(
                    "the Claude Code credential was refused (status \(code)); its limits stay "
                        + "hidden until the CLI renews it")
                return Self.refreshInterval
            }
            report("the Claude usage request failed: \(error)")
            return Self.refreshInterval
        }
    }

    /// Publishes why the windows are missing, and takes them down with it: a
    /// gauge left standing under a sentence explaining that there is no
    /// reading behind it is worse than no gauge.
    ///
    /// The observation stamp goes with them, because it is the moment *this
    /// reading* was taken and there is no longer a reading. Keeping it left a
    /// reader competing on the freshness of an answer it had already
    /// withdrawn: `ClaudeCodeSignals.answering` ranks the CLI's credential
    /// over the claude.ai session and only compares stamps once the ranked
    /// reader has something to explain, so a probe refused at 15:20 whose
    /// last good reading was 15:12 outranked a session that had read at
    /// 15:10 — and won the row with no windows on it at all, discarding the
    /// session's. A reader with nothing to show is not in that comparison,
    /// which is the same rule that keeps one who has never read out of it.
    ///
    /// A 429 deliberately does not come through here: that reading is still
    /// the last true one and its age is the point.
    private func publishFailure(_ state: ProviderLimitsState) {
        published.update {
            $0.signals.limitsState = state
            $0.signals.windows = []
            $0.signals.credits = nil
            $0.signals.limitsObservedAt = nil
            $0.credential = nil
        }
    }

    private static func fetch(token: String) async throws -> Reading {
        var request = URLRequest(url: usageURL, timeoutInterval: requestTimeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return parse(try await UsageRequestError.object(answering: request), observedAt: Date())
    }

    /// The windows the panel draws and the spend beside them, off the body
    /// every Claude usage source answers with. The parse itself lives in
    /// `ClaudeUsagePayload`, which claude.ai and the CLI's own cache read
    /// through too.
    static func parse(_ payload: [String: Any], observedAt: Date = Date()) -> Reading {
        Reading(
            windows: ClaudeUsagePayload.windows(payload),
            credits: ClaudeUsagePayload.credits(payload, observedAt: observedAt)
        )
    }
}
