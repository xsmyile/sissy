import Foundation

/// Keeps track of which Claude Code account is signed in, and of every account
/// it has seen signed in.
///
/// The CLI's keychain slots hold whichever account is active and are rewritten
/// with a rotated token on every refresh, so they cannot be an account list.
/// What can is this: Sissy watches the active credential, and each time it
/// turns out to be one it has not identified (a `/login`, or simply the CLI
/// rotating a token) it asks Anthropic who the token belongs to and files the
/// answer's name, never the credential. Sissy only observes: nothing here
/// writes to the CLI's slots or its config.
///
/// Every keychain read is a `/usr/bin/security` process run on this actor and
/// waited for synchronously, each bounded by `ClaudeKeychainCLI`'s watchdog at
/// 5 s. So a keychain that stalls holds the actor for up to 5 s a call, and
/// what queues behind it is the account watch's `captureActive()`. The app
/// never does: it reads `currentSnapshot()`, which is nonisolated.
actor ClaudeAccountRegistry {
    /// What the app reads: who is known and who is active.
    struct Snapshot: Sendable, Equatable {
        var accounts: [ClaudeAccountIdentity] = []
        var activeUUID: String?
        /// Whether an index that would not read was set aside, so the page can
        /// say why accounts it used to list are missing.
        var indexSetAside = false
        /// `ClaudeCredentialBlob.fingerprint(of:)` of the access token that
        /// was identified as `activeUUID`, and nil when none was this run.
        ///
        /// What lets a limits reading be matched to the name on the row. The
        /// probe and this registry read the same slot on two clocks, so a
        /// `/login` that lands between them has the probe spending the new
        /// account's token while this still names the old one; a reading is
        /// laid under `activeUUID` only when it was read with this token.
        var activeCredential: String?
    }

    private let store: ClaudeAccountStore
    private let slot: ClaudeCLISlot
    /// Resolves a token to its owner. Injected so a test can exercise the
    /// capture without reaching Anthropic — the network is the only part of
    /// this that cannot be stood in for by the keychain.
    private let identify: @Sendable (String) async throws -> ClaudeAccountIdentity
    private let now: @Sendable () -> Date
    /// Access token of the credential last seen active, so a poll that finds
    /// it unchanged costs nothing. Only a token Sissy has not already filed
    /// buys a request.
    private var lastSeenToken: String?
    /// The expired token already logged. The profile endpoint answers one with
    /// a 401, and asking it on every watch cost about 30 refused requests an
    /// hour for as long as the slot held one, each logged. So it is not asked
    /// (`ClaudeLimitsProbe` gates on the same field) and it is named once.
    private var lastExpiredToken: String?
    /// The token the profile endpoint last refused with a 401 or a 403. An
    /// expiry says nothing about a revoked token, which cost the same request
    /// on every watch, so the refusal itself is remembered, until the slot holds
    /// a different token. In memory only: a relaunch asks once more.
    private var refusedToken: String?
    private static let refusalStatuses: Set<Int> = [401, 403]
    /// Whether a `captureActive()` is running, suspended on the vendor or not.
    private var capturing = false
    /// When the profile endpoint may be asked again after it answered 429.
    ///
    /// The endpoint is undocumented and the watch polls every two minutes, so
    /// a credential it will not identify was otherwise asked about again on
    /// every tick for as long as the refusal lasted. The wait is the one
    /// `UsageRequestError.backoffSeconds(retryAfter:)` gives every other
    /// reader, and it lives in memory only: a relaunch costs one request.
    private var identifyRefusedUntil: Date?
    nonisolated private let published = LockedValue(Snapshot())

    /// A registry that knows nothing and learns nothing: no keychain, no
    /// network, no index on disk. The default everywhere an engine is built
    /// without one. Its index sits in a directory nobody creates, so it reads
    /// as absent and no write to it can land.
    static func inert() -> ClaudeAccountRegistry {
        let nowhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-inert-\(UUID().uuidString)", isDirectory: true)
        let store = ClaudeAccountStore(indexURL: ClaudeAccountStore.defaultURL(in: nowhere))
        return ClaudeAccountRegistry(store: store, slot: .inert) { _ in
            throw UsageRequestError.malformedPayload
        }
    }

    init(
        store: ClaudeAccountStore,
        slot: ClaudeCLISlot,
        identify: @escaping @Sendable (String) async throws -> ClaudeAccountIdentity = {
            try await ClaudeAccountProfile.resolve(token: $0)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.slot = slot
        self.now = now
        self.identify = identify
        let index = Self.loadIndex(store) ?? ClaudeAccountStore.Index()
        published.update {
            $0 = Snapshot(
                accounts: index.accounts, activeUUID: index.activeUUID,
                indexSetAside: store.hasSetAsideIndex())
        }
    }

    nonisolated func currentSnapshot() -> Snapshot { published.load() }

    /// Reads the active credential and names its account when it is one Sissy
    /// has not identified. Cheap when nothing has changed, which is the
    /// ordinary case.
    ///
    /// Answers whether the published snapshot moved, so the caller can emit on
    /// the one event that produces no token of its own — someone signing into
    /// a different account in a terminal Sissy is not watching.
    ///
    /// A slot that holds nothing clears the active account, because a CLI
    /// that has been signed out is on no account and a badge saying otherwise
    /// outlived every `/logout`. A slot that cannot be read changes nothing:
    /// it says nothing about who is signed in.
    ///
    /// One at a time. A capture that arrives while another is waiting on the
    /// vendor answers false at once rather than identifying the same token
    /// behind it; the one in flight publishes what it finds.
    @discardableResult
    func captureActive() async -> Bool {
        guard !capturing else { return false }
        capturing = true
        defer { capturing = false }
        let before = published.load()
        publishIndex()
        let current: (name: ClaudeCLISlot.Name, data: Data)?
        do {
            current = try slot.current()
        } catch {
            sissyLog("sissy: could not read Claude Code's credential: \(error)")
            return published.load() != before
        }
        guard let current else {
            lastSeenToken = nil
            let shown = published.load()
            if shown.activeUUID != nil || shown.activeCredential != nil { setActive(nil, cause: .signedOut) }
            return published.load() != before
        }
        guard let parsed = ClaudeCredentialBlob.credentials(in: current.data),
            parsed.accessToken != lastSeenToken
        else { return published.load() != before }
        if let expiresAt = parsed.expiresAt, expiresAt <= now() {
            if parsed.accessToken != lastExpiredToken {
                lastExpiredToken = parsed.accessToken
                sissyLog(
                    "sissy: the Claude credential in \(current.name.label) has expired; "
                        + "waiting for it to renew")
            }
            return published.load() != before
        }
        guard parsed.accessToken != refusedToken else { return published.load() != before }
        await file(parsed.accessToken, from: current.name)
        return published.load() != before
    }

    /// Identifies an access token and files the account it belongs to. A token
    /// the vendor will not answer for — expired, offline, an account that has
    /// been removed — is left alone rather than filed under a guess, and the
    /// next poll tries again. A refusal is logged with the name the token came
    /// from.
    ///
    /// Marking it active waits on the slot still holding it once the
    /// identification is back. That is a network turn, and a `/login` landing
    /// in it has put another account in the slot.
    ///
    /// A task cancelled in that turn writes nothing. It is the watcher of an
    /// engine being stopped, and an engine is rebuilt on every provider
    /// toggle, so one resuming after its replacement started wrote the
    /// index behind the new one's back.
    private func file(_ accessToken: String, from name: ClaudeCLISlot.Name) async {
        if let until = identifyRefusedUntil, until > now() { return }
        let identity: ClaudeAccountIdentity
        do {
            identity = try await identify(accessToken)
            identifyRefusedUntil = nil
        } catch {
            if case UsageRequestError.rateLimited(let retryAfter) = error {
                identifyRefusedUntil = now().addingTimeInterval(
                    UsageRequestError.backoffSeconds(retryAfter: retryAfter))
            }
            if case UsageRequestError.badStatus(let code) = error,
                Self.refusalStatuses.contains(code)
            {
                refusedToken = accessToken
            }
            sissyLog("sissy: could not identify the Claude credential in \(name.label): \(error)")
            return
        }
        guard !Task.isCancelled, Self.loadIndex(store) != nil else { return }
        do {
            try store.remember(identity)
        } catch {
            sissyLog("sissy: could not record the Claude account \(identity.uuid): \(error)")
            return
        }
        guard let still = try? slot.current()?.data,
            ClaudeCredentialBlob.credentials(in: still)?.accessToken == accessToken
        else {
            publishIndex()
            return
        }
        lastSeenToken = accessToken
        setActive(identity.uuid, cause: .seenInSlot)
    }

    /// The index, with one that will not read set aside so the captures after
    /// it can start a new one. Nil when it would not read and could not be
    /// moved either, which leaves the file where it is and every write here
    /// refused.
    private static func loadIndex(_ store: ClaudeAccountStore) -> ClaudeAccountStore.Index? {
        do {
            return try store.loadIndex()
        } catch let unreadable {
            do {
                let aside = try store.setAsideIndex()
                sissyLog(
                    "sissy: the Claude account index would not read (\(unreadable)); kept it as "
                        + aside.lastPathComponent)
                return ClaudeAccountStore.Index()
            } catch {
                let moved = error as NSError
                sissyLog(
                    "sissy: the Claude account index would not read (\(unreadable)) and could "
                        + "not be moved (\(moved.domain) \(moved.code))")
                return nil
            }
        }
    }

    /// What moved the active account, which is what the log line says.
    private enum ActiveCause: String {
        case seenInSlot = "found in the CLI's credential"
        case signedOut = "the CLI's credential is empty"
    }

    /// Records the active account, and logs it whenever it moves.
    private func setActive(_ uuid: String?, cause: ActiveCause) {
        guard var index = Self.loadIndex(store) else { return }
        if index.activeUUID != uuid {
            sissyLog(
                "sissy: Claude Code is signed in as \(uuid ?? "nobody"), "
                    + "was \(index.activeUUID ?? "nobody") (\(cause.rawValue))")
        }
        index.activeUUID = uuid
        do {
            try store.saveIndex(index)
        } catch {
            sissyLog("sissy: could not record the active Claude account: \(error)")
        }
        publish(index)
    }

    private func publishIndex() {
        guard let index = Self.loadIndex(store) else {
            published.update { $0.indexSetAside = store.hasSetAsideIndex() }
            return
        }
        publish(index)
    }

    private func publish(_ index: ClaudeAccountStore.Index) {
        published.update {
            $0 = Snapshot(
                accounts: index.accounts, activeUUID: index.activeUUID,
                indexSetAside: store.hasSetAsideIndex(),
                activeCredential: index.activeUUID == nil
                    ? nil : lastSeenToken.map(ClaudeCredentialBlob.fingerprint(of:)))
        }
    }
}
