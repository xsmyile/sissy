import Foundation

/// Renews a linked Codex account's credential and files the renewal, as one
/// operation nothing a caller does can interrupt.
///
/// OpenAI rotates the refresh token on every renewal, so the moment the token
/// endpoint answers, the item in `CodexAccountStore` holds a token that has
/// been spent. Three things used to lose the new one, and each is closed here:
///
/// - **A cancelled caller.** The Refresh button, a provider toggle and a quit
///   all cancel the reader that asked, and the cancellation reached the
///   request, so the reply was thrown away after the vendor had rotated. The
///   renewal is an unstructured task this actor owns, which a caller awaits
///   and cannot cancel; it is bounded by the token request's own timeout.
/// - **Two callers at once.** A poll and a Refresh redeemed the same one-time
///   token concurrently. Renewals are serialised per account, and a caller
///   that finds one in flight awaits that one rather than starting a second.
/// - **A save that fails.** The renewal is kept in memory and handed to every
///   caller that asks while the save is retried with bounded exponential
///   backoff and jitter, and every poll that finds it still unsaved starts a
///   fresh round.
///
/// The save is the first thing that happens after the reply, with no other
/// suspension in between. What remains is a crash, a force quit or a power
/// loss between the vendor's reply and the keychain write, or while a failed
/// save is still being retried: the renewal lived only in this process, the
/// item still holds the spent token, and the next launch reads the link as
/// ended. No ordering can close that without writing the secret somewhere
/// less protected than the keychain first.
///
/// A token OpenAI refused before its expiry is renewed through
/// `renewRefused`, once per refused token: the vendor can revoke an access
/// token early while the refresh token behind it is still good, and reading
/// that as an ended link sent the user to link an account that needed nothing.
///
/// Whether a failed renewal ends the link is `CodexOAuth.RenewalFailure`'s
/// answer. Only a grant the endpoint rejected does; anything else defers the
/// next attempt, and the reader keeps its last reading meanwhile.
actor CodexRenewal {
    typealias Load =
        @Sendable (_ account: String, _ allowingInteraction: Bool) ->
        CodexCredentialReading
    typealias Save = @Sendable (_ credential: CodexCredential, _ account: String) throws -> Void
    typealias Renew = @Sendable (CodexCredential) async throws -> CodexCredential
    typealias Pause = @Sendable (Duration) async throws -> Void

    static let shared = CodexRenewal()

    /// How many times one round retries a save that failed, after the first.
    static let saveAttempts = 5
    private static let saveRetryBase: TimeInterval = 1
    private static let saveRetryCeiling: TimeInterval = 30
    /// The first wait after a renewal that could not reach an answer. Below
    /// the poll interval, so an ordinary poll is the retry until failures
    /// accumulate.
    private static let deferralBase: TimeInterval = 60
    /// How far either side of the nominal wait a retry may land.
    static let jitterSpread: ClosedRange<Double> = 0.8...1.2

    private let load: Load
    private let save: Save
    private let renew: Renew
    private let pause: Pause
    private let jitter: @Sendable () -> Double
    private let now: @Sendable () -> Date

    private var inFlight: [String: Task<CodexCredentialReading, Never>] = [:]
    /// Renewals the keychain has not taken yet. They are newer than the item
    /// and the only copy of the rotated refresh token, so they are what a
    /// caller is handed.
    private var unsaved: [String: CodexCredential] = [:]
    private var saving: [String: Task<Void, Never>] = [:]
    private var deferrals: [String: (until: Date, count: Int)] = [:]
    /// Bumped by `forget`, so a renewal or a save retry that began for an
    /// account since unlinked or linked again files nothing.
    private var generations: [String: Int] = [:]

    init(
        load: @escaping Load = { CodexAccountStore.load(account: $0, allowingInteraction: $1) },
        save: @escaping Save = { try CodexAccountStore.save($0, account: $1) },
        renew: @escaping Renew = { try await CodexOAuth.refresh($0) },
        pause: @escaping Pause = { try await Task.sleep(for: $0) },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: CodexRenewal.jitterSpread) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.load = load
        self.save = save
        self.renew = renew
        self.pause = pause
        self.jitter = jitter
        self.now = now
    }

    /// The credential a reader should poll with, renewed if it is spent.
    func supply(account: String, allowingInteraction: Bool) async -> CodexCredentialReading {
        let current = held(account: account, allowingInteraction: allowingInteraction)
        guard case .found(let credential) = current, credential.isExpired(at: now()) else {
            return current
        }
        return await renew(credential, account: account)
    }

    /// The credential to read again with after OpenAI refused `refused`,
    /// renewed whatever its expiry says.
    ///
    /// Keyed on the refused token rather than on the call: a renewal that
    /// landed since, from this reader or another of the same account, is
    /// handed over as it is, because redeeming again would spend the grant
    /// that renewal was just given.
    func renewRefused(account: String, refused: CodexCredential) async -> CodexCredentialReading {
        if let running = inFlight[account] { return await running.value }
        let current = held(account: account, allowingInteraction: false)
        guard case .found(let credential) = current,
            credential.accessToken == refused.accessToken
        else { return current }
        return await renew(credential, account: account)
    }

    /// A renewal the keychain has not taken yet outranks the item, which
    /// still holds the refresh token that renewal spent.
    private func held(account: String, allowingInteraction: Bool) -> CodexCredentialReading {
        guard let held = unsaved[account] else { return load(account, allowingInteraction) }
        scheduleSave(account: account)
        return .found(held)
    }

    private func renew(_ credential: CodexCredential, account: String) async -> CodexCredentialReading {
        if let running = inFlight[account] { return await running.value }
        if let deferral = deferrals[account], deferral.until > now() {
            return .unreadable("the Codex renewal is deferred until \(deferral.until)")
        }
        let generation = generations[account, default: 0]
        let renewal = Task {
            await self.renewAndFile(credential, account: account, generation: generation)
        }
        inFlight[account] = renewal
        return await renewal.value
    }

    /// Drops everything held for an account that is being unlinked or linked
    /// again, so nothing renewed for the old link is filed over the new one or
    /// re-creates an item the user deleted.
    func forget(account: String) {
        generations[account, default: 0] += 1
        inFlight[account] = nil
        unsaved[account] = nil
        deferrals[account] = nil
        saving[account]?.cancel()
        saving[account] = nil
    }

    /// Waits for the save retries running for an account, which is what a
    /// test asserts the outcome of.
    func settle(account: String) async {
        await saving[account]?.value
    }

    /// A reply that lands after `forget` answers for a link that no longer
    /// exists, whether it renewed the grant or refused it, so it touches
    /// nothing the replacement holds: read as `.expired` or as a deferral it
    /// ended or held back a link the user had just made.
    private func renewAndFile(
        _ credential: CodexCredential, account: String, generation: Int
    ) async -> CodexCredentialReading {
        defer {
            if generations[account, default: 0] == generation { inFlight[account] = nil }
        }
        let renewed: Result<CodexCredential, Error>
        do {
            renewed = .success(try await renew(credential))
        } catch {
            renewed = .failure(error)
        }
        guard generations[account, default: 0] == generation else {
            return .unreadable("the Codex account was unlinked or relinked while its sign-in was renewed")
        }
        switch renewed {
        case .success(let fresh):
            return file(fresh, account: account)
        case .failure(CodexOAuth.RenewalFailure.rejected):
            deferrals[account] = nil
            return .expired
        case .failure(CodexOAuth.RenewalFailure.deferred(let retryAfter)):
            return postpone(account: account, retryAfter: retryAfter)
        case .failure:
            return postpone(account: account, retryAfter: nil)
        }
    }

    /// A save that lands supersedes any renewal still held unsaved: that one
    /// carries a refresh token this renewal has spent, so handing it over or
    /// filing it on retry would hand over a dead link.
    private func file(_ renewed: CodexCredential, account: String) -> CodexCredentialReading {
        deferrals[account] = nil
        do {
            try save(renewed, account)
            unsaved[account] = nil
        } catch {
            sissyLog("sissy: a renewed Codex credential could not be filed (\(error)); retrying")
            unsaved[account] = renewed
            scheduleSave(account: account)
        }
        return .found(renewed)
    }

    private func postpone(account: String, retryAfter: TimeInterval?) -> CodexCredentialReading {
        let count = (deferrals[account]?.count ?? 0) + 1
        let wait =
            retryAfter
            ?? Self.backoff(
                attempt: count, base: Self.deferralBase,
                ceiling: UsageRequestError.retryAfterCeiling, jitter: jitter())
        let until = now().addingTimeInterval(wait)
        deferrals[account] = (until: until, count: count)
        sissyLog("sissy: the Codex sign-in could not be renewed yet; asking again after \(until)")
        return .unreadable("the Codex renewal did not get an answer")
    }

    private func scheduleSave(account: String) {
        guard saving[account] == nil else { return }
        let generation = generations[account, default: 0]
        saving[account] = Task {
            await self.retrySave(account: account, generation: generation)
        }
    }

    private func retrySave(account: String, generation: Int) async {
        defer {
            if generations[account, default: 0] == generation { saving[account] = nil }
        }
        for attempt in 1...Self.saveAttempts {
            let wait = Self.backoff(
                attempt: attempt, base: Self.saveRetryBase, ceiling: Self.saveRetryCeiling,
                jitter: jitter())
            do { try await pause(.seconds(wait)) } catch { return }
            guard generations[account, default: 0] == generation, let held = unsaved[account]
            else { return }
            do {
                try save(held, account)
                unsaved[account] = nil
                sissyLog("sissy: the renewed Codex credential was filed on retry \(attempt)")
                return
            } catch {
                sissyLog("sissy: retry \(attempt) could not file the renewed Codex credential")
            }
        }
    }

    /// `base` doubled per attempt, capped, and spread by `jitter` so readers
    /// that failed together do not retry together.
    static func backoff(
        attempt: Int, base: TimeInterval, ceiling: TimeInterval, jitter: Double
    ) -> TimeInterval {
        let doubled = base * pow(2, Double(max(attempt - 1, 0)))
        return min(doubled, ceiling) * jitter
    }
}
