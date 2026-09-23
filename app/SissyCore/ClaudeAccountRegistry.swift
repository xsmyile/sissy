import Foundation

/// Keeps track of which Claude Code account is signed in, archives every one
/// it sees, and switches between them.
///
/// The CLI's keychain slots hold whichever account is active and are rewritten
/// with a rotated token on every refresh, so they cannot be an account list and
/// cannot be an archive. What can is this: Sissy watches the active credential,
/// and each time it turns out to be one it has not archived — a switch, a
/// `/login`, or simply the CLI rotating a token — it asks Anthropic who the
/// token belongs to and files a copy under that account. An account therefore
/// becomes switchable the first time it is used on this Mac, and stays
/// switchable afterwards without the user configuring a directory, an alias or
/// `CLAUDE_CONFIG_DIR`.
///
/// The one thing it cannot do is offer an account that has never signed in
/// here: there is no credential to archive, and no login flow of Sissy's own.
/// That first `/login` is the user's, once per account.
///
/// Every keychain read and write is a `/usr/bin/security` process run on this
/// actor and waited for synchronously, each bounded by `ClaudeKeychainCLI`'s
/// watchdog at 5 s. That is deliberate. A switch reads every name, reads them
/// again, and writes; the second read and the write must have no suspension
/// point between them, or a capture could run in the gap and the write would
/// land over a credential nothing has archived. So a keychain that stalls
/// holds the actor for up to 5 s a call, and what queues behind it is
/// `activate(uuid:)` and the account watch's `captureActive()`. The app never
/// does: it reads `currentSnapshot()`, which is nonisolated.
actor ClaudeAccountRegistry {
    /// What the app reads: who is known, who is active, and which of them a
    /// switch can reach.
    struct Snapshot: Sendable, Equatable {
        var accounts: [ClaudeAccountIdentity] = []
        var activeUUID: String?
        /// Accounts whose archived credential is in the keychain and still
        /// able to sign the CLI in.
        ///
        /// Not the index: an index entry is a name Sissy has seen, and the
        /// secret behind it can be missing — a different build's namespace, a
        /// keychain item removed by hand. Offering `Use in CLI` off the index
        /// alone put the control on an account whose click could only fail.
        var switchable: Set<String> = []
        /// Accounts whose archived refresh token has expired, which only a
        /// `claude /login` as that account can renew.
        var needsLogin: Set<String> = []
        /// Whether an index that would not read was set aside, so the switcher
        /// can say why accounts it used to list are missing.
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

    /// Why a switch did not happen. Each is a different sentence to the user,
    /// because each is a different thing to do: an account Sissy holds
    /// nothing for, a slot whose owner it cannot establish, a keychain that
    /// refused or could not be asked, a mirror file it could not write, and
    /// a switch that could not be undone after one of those.
    enum Failure: Error, Equatable {
        case notArchived
        /// The account in one of the CLI's names could not be identified, or
        /// the CLI has no name to write to.
        case activeAccountUnknown
        /// One of the CLI's names could not be read, or holds bytes that are
        /// not a credential blob.
        case slotUnreadable
        /// The CLI rewrote its credential while the switch was verifying it.
        case slotChanged
        case keychain(Int32)
        /// The keychain could not be asked at all: locked, `security` would
        /// not start, or it did not answer in time.
        case keychainUnavailable
        /// The `.credentials.json` beside the keychain items would not take
        /// the write.
        case mirrorWrite
        /// A write failed and putting back what was there before failed too,
        /// so the CLI's names no longer agree on one account.
        case partialSwitch
        /// The archived credential's refresh token has expired.
        case needsLogin
        /// The account index would not read and could not be set aside.
        case indexUnreadable
    }

    /// What each of the CLI's names held when it was read, by name.
    private typealias Held = [ClaudeCLISlot.Name: Data]

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
    /// Whether the keychain has been asked which archived accounts it holds.
    /// Deferred to the first capture rather than asked at construction,
    /// which runs on whatever thread builds the engine.
    private var reconciled = false
    /// Whether a `captureActive()` is running, suspended on the vendor or not.
    private var capturing = false
    nonisolated private let published = LockedValue(Snapshot())

    /// A registry that knows nothing and learns nothing: no keychain, no
    /// network, no index on disk. The default everywhere an engine is built
    /// without one. Its index sits in a directory nobody creates, so it reads
    /// as absent and no write to it can land.
    static func inert() -> ClaudeAccountRegistry {
        let nowhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-inert-\(UUID().uuidString)", isDirectory: true)
        var store = ClaudeAccountStore(indexURL: ClaudeAccountStore.defaultURL(in: nowhere))
        store.secrets = .none
        return ClaudeAccountRegistry(store: store, slot: .inert) { _ in
            throw ClaudeAccountProfile.Failure.malformedPayload
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
                needsLogin: Self.expired(index, now: now()),
                indexSetAside: store.hasSetAsideIndex())
        }
    }

    nonisolated func currentSnapshot() -> Snapshot { published.load() }

    /// Reads the active credential and archives it when it is one Sissy has
    /// not seen. Cheap when nothing has changed, which is the ordinary case.
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
    /// Every poll also asks whether an archived refresh token has died since
    /// the last publish. Nothing in the slot moves when it does, so returning
    /// on an unchanged token left `Use in CLI` on an account whose click
    /// could only fail.
    ///
    /// One at a time. A capture that arrives while another is waiting on the
    /// vendor answers false at once rather than identifying the same token
    /// behind it; the one in flight publishes what it finds. A switch does not
    /// go through this gate, because it must not wait on a poll's network
    /// turn and must not proceed without having offered the slot to a capture.
    @discardableResult
    func captureActive() async -> Bool {
        guard !capturing else { return false }
        capturing = true
        defer { capturing = false }
        return await refreshActive()
    }

    @discardableResult
    private func refreshActive() async -> Bool {
        let before = published.load()
        if !reconciled {
            reconciled = true
            publishIndex()
        } else {
            republishIfExpiryPassed()
        }
        let current: Data?
        do {
            current = try slot.current()?.data
        } catch {
            sissyLog("sissy: could not read Claude Code's credential: \(error)")
            return published.load() != before
        }
        guard let current else {
            lastSeenToken = nil
            let shown = published.load()
            if shown.activeUUID != nil || shown.activeCredential != nil { setActive(nil) }
            return published.load() != before
        }
        guard let parsed = ClaudeCredentialBlob.credentials(in: current),
            parsed.accessToken != lastSeenToken
        else { return published.load() != before }
        await file(credential: current, markActive: true)
        return published.load() != before
    }

    /// Makes an archived account the one Claude Code starts as.
    ///
    /// Writes the CLI's own slots and nothing else, which is safe precisely
    /// because they are no longer where the account lives: whatever this
    /// overwrites, Sissy still holds. Only the account half is written, merged
    /// into what each name holds now, so the MCP logins and every other key
    /// the CLI keeps beside it stay exactly as live.
    ///
    /// Nothing is overwritten that Sissy has not archived first, and that is
    /// one rule for every name, the `.credentials.json` mirror included. The
    /// name the CLI is reading earns it by the capture in front of the test: a
    /// slot this accepts is one whose archive is the same credential, so the
    /// write that follows cannot be a downgrade. Any other name holding
    /// something else earns it by being archived here, because an earlier
    /// build wrote one of a pair and left the other on the account it
    /// switched away from. A name that cannot be read is not a name with
    /// nothing in it, so it refuses the switch rather than being skipped:
    /// skipping it is how a mirror nobody looked at came to be overwritten
    /// with an account that was never archived.
    ///
    /// The slots are read once more between the last identification and the
    /// write, because every reading above it sits behind a network round trip
    /// and the CLI rotates on its own schedule. A slot that moved in that
    /// window holds a credential nothing has archived, so the switch is
    /// abandoned rather than completed over it.
    ///
    /// The write reaches several names and cannot be atomic across them, so
    /// each name's previous bytes are held until the last write lands. A
    /// failure puts every name already written back as it was and reports the
    /// write that failed; only a put-back that fails too is `partialSwitch`.
    ///
    /// A credential Sissy cannot account for is not written over at all.
    /// Which account a slot holds is what decides whether this is a switch or
    /// a re-affirmation, and both readings are destructive when guessed: a
    /// stale archive written over the same account's live credential hands the
    /// CLI a refresh token that may already have been spent, and a switch away
    /// from an account whose rotation nobody saw spends the last copy of it
    /// this Mac has.
    func activate(uuid: String) async -> Result<Void, Failure> {
        do {
            try await performSwitch(to: uuid)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func performSwitch(to uuid: String) async throws(Failure) {
        guard Self.loadIndex(store) != nil else { throw .indexUnreadable }
        _ = try archived(uuid)
        await refreshActive()
        let names = slot.names()
        guard let primary = names.first else { throw .activeAccountUnknown }
        let before = try readAll(names)
        try await accountForEveryName(names, holding: before)
        let credential = try archived(uuid)
        if ClaudeCredentialBlob.refreshHasExpired(credential, now: now()) { throw .needsLogin }
        guard try readAll(names) == before else { throw .slotChanged }
        let targets = names.filter { name in
            name == primary
                || (before[name].map { ClaudeCredentialBlob.oauth(in: $0) != nil } ?? false)
        }
        if let failure = write(credential, to: targets, over: before) { throw failure }
        lastSeenToken = ClaudeCredentialBlob.credentials(in: credential)?.accessToken
        setActive(uuid)
        sissyLog("sissy: wrote the Claude Code credential for \(uuid) into the CLI's slots")
    }

    /// Makes sure nothing any name holds is lost by the write: every account
    /// in them is one the archive already has, or is archived now. The name
    /// the CLI is reading was offered to the capture in front of this, so one
    /// still unaccounted for there is refused rather than asked about again.
    /// Bytes that are not a JSON object cannot be merged into, and refuse as
    /// a slot that would not read.
    private func accountForEveryName(
        _ names: [ClaudeCLISlot.Name], holding before: Held
    ) async throws(Failure) {
        let reading = names.first { name in
            before[name].map { ClaudeCredentialBlob.oauth(in: $0) != nil } ?? false
        }
        for name in names {
            guard let bytes = before[name] else { continue }
            guard ClaudeCredentialBlob.object(bytes) != nil else { throw .slotUnreadable }
            guard ClaudeCredentialBlob.oauth(in: bytes) != nil, !isAccountedFor(bytes) else {
                continue
            }
            guard name != reading, await file(credential: bytes, markActive: false) else {
                throw .activeAccountUnknown
            }
        }
    }

    /// The archived credential for one account, or why there is none to use.
    private func archived(_ uuid: String) throws(Failure) -> Data {
        let held: Data?
        do {
            held = try store.credential(uuid: uuid)
        } catch {
            throw Self.keychainFailure(error)
        }
        guard let held, ClaudeCredentialBlob.oauth(in: held) != nil else { throw .notArchived }
        return held
    }

    /// What every name holds now. A name that cannot be read stops the switch.
    private func readAll(_ names: [ClaudeCLISlot.Name]) throws(Failure) -> Held {
        var read: Held = [:]
        for name in names {
            do {
                if let data = try slot.read(name) { read[name] = data }
            } catch {
                sissyLog("sissy: could not read one of Claude Code's credential slots: \(error)")
                throw name == .file ? .slotUnreadable : Self.keychainFailure(error)
            }
        }
        return read
    }

    /// Writes the account half into every target, and on a failure puts back
    /// what the names already written held. Answers nil when every write
    /// landed.
    private func write(
        _ credential: Data,
        to targets: [ClaudeCLISlot.Name],
        over before: Held
    ) -> Failure? {
        var written: [ClaudeCLISlot.Name] = []
        for name in targets {
            guard let merged = ClaudeCredentialBlob.merging(account: credential, into: before[name])
            else {
                return restore(written, to: before) ? .slotUnreadable : .partialSwitch
            }
            do {
                try slot.write(name, merged)
                written.append(name)
            } catch {
                sissyLog("sissy: a Claude Code credential slot refused the switch: \(error)")
                let cause = name == .file ? Failure.mirrorWrite : Self.keychainFailure(error)
                return restore(written, to: before) ? cause : .partialSwitch
            }
        }
        return nil
    }

    /// Puts each written name back as it was, the last written first, and
    /// takes away what the switch created where there had been nothing.
    /// Answers whether every one of them went back.
    private func restore(
        _ written: [ClaudeCLISlot.Name], to before: Held
    ) -> Bool {
        var intact = true
        for name in written.reversed() {
            do {
                if let previous = before[name] {
                    try slot.write(name, previous)
                } else {
                    try slot.remove(name)
                }
            } catch {
                sissyLog("sissy: could not put a Claude Code credential slot back: \(error)")
                intact = false
            }
        }
        return intact
    }

    /// Identifies a credential and archives it. A token the vendor will not
    /// answer for — expired, offline, an account that has been removed — is
    /// left alone rather than filed under a guess, and the next poll tries
    /// again.
    ///
    /// Marking it active waits on the slot still holding it once the
    /// identification is back. That is a network turn, and the actor is free
    /// for the length of it: a switch that ran in the gap has already written
    /// another account and marked it, and a capture resuming over it put the
    /// badge back on the account the user had just left.
    ///
    /// A task cancelled in that turn writes nothing. It is the watcher of an
    /// engine being stopped, and an engine is rebuilt on every provider
    /// toggle, so one resuming after its replacement started wrote the
    /// archive and the index behind the new one's back.
    @discardableResult
    private func file(credential: Data, markActive: Bool) async -> Bool {
        guard let parsed = ClaudeCredentialBlob.credentials(in: credential) else { return false }
        let identity: ClaudeAccountIdentity
        do {
            identity = try await identify(parsed.accessToken)
        } catch {
            sissyLog("sissy: could not identify a Claude credential: \(error)")
            return false
        }
        guard !Task.isCancelled, Self.loadIndex(store) != nil else { return false }
        do {
            try store.remember(identity, credential: credential)
        } catch {
            sissyLog("sissy: could not archive the Claude account \(identity.uuid): \(error)")
            return false
        }
        guard markActive, let still = try? slot.current()?.data,
            ClaudeCredentialBlob.sameAccountCredential(still, credential)
        else {
            publishIndex()
            return true
        }
        lastSeenToken = parsed.accessToken
        setActive(identity.uuid)
        return true
    }

    /// Whether overwriting these bytes would lose anything.
    ///
    /// Two answers, and each is sufficient on its own. This run identified
    /// them, so the archive holds that account at least as fresh; or the
    /// archive already holds this exact credential, which is proof that cost
    /// no network turn and cannot expire. The second is what keeps an archived
    /// account switchable on a Mac whose CLI has not run for hours: its access
    /// token has expired, the profile endpoint answers 401 to it, and
    /// re-identifying it is the one thing that cannot be done — while the
    /// bytes in question are Sissy's own copy of a credential it identified
    /// when it was young. Without it a relaunch, which forgets the token it
    /// last saw, would refuse every switch until the user went and ran the CLI.
    ///
    /// Only the account half is compared, since that is all the archive
    /// keeps. An archive that cannot be read accounts for nothing.
    private func isAccountedFor(_ credential: Data) -> Bool {
        if let token = ClaudeCredentialBlob.credentials(in: credential)?.accessToken,
            token == lastSeenToken
        {
            return true
        }
        guard let index = try? store.loadIndex() else { return false }
        return index.accounts.contains { account in
            guard let held = try? store.credential(uuid: account.uuid) else { return false }
            return ClaudeCredentialBlob.sameAccountCredential(held, credential)
        }
    }

    /// How the keychain's own refusals reach the user. A locked keychain and
    /// a tool that would not answer are one sentence, and neither may be
    /// worded as an account that needs a login.
    private static func keychainFailure(_ error: Error) -> Failure {
        switch error {
        case ClaudeKeychainCLI.Failure.tool(let status):
            return ClaudeKeychainCLI.unavailableStatuses.contains(status)
                ? .keychainUnavailable : .keychain(status)
        case ClaudeKeychainCLI.Failure.noItem:
            return .notArchived
        default:
            return .keychainUnavailable
        }
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

    private static func expired(_ index: ClaudeAccountStore.Index, now: Date) -> Set<String> {
        Set((index.refreshExpiries ?? [:]).filter { $0.value <= now }.keys)
    }

    /// Publishes again when an archived refresh token has died since the last
    /// publish. Costs a read of the index, and the keychain only on the poll
    /// that finds one.
    private func republishIfExpiryPassed() {
        guard let index = Self.loadIndex(store),
            Self.expired(index, now: now()) != published.load().needsLogin
        else { return }
        publish(index)
    }

    private func setActive(_ uuid: String?) {
        guard var index = Self.loadIndex(store) else { return }
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

    /// Publishes the index with what the keychain says about each account.
    /// An account whose archive cannot be asked about is not offered, which
    /// is the only safe reading of a question with no answer.
    private func publish(_ index: ClaudeAccountStore.Index) {
        let expired = Self.expired(index, now: now())
        let held = index.accounts.map(\.uuid).filter { uuid in
            guard !expired.contains(uuid) else { return false }
            do {
                return try store.holdsCredential(uuid: uuid)
            } catch {
                sissyLog("sissy: could not ask the keychain about Claude account \(uuid): \(error)")
                return false
            }
        }
        published.update {
            $0 = Snapshot(
                accounts: index.accounts, activeUUID: index.activeUUID,
                switchable: Set(held), needsLogin: expired,
                indexSetAside: store.hasSetAsideIndex(),
                activeCredential: index.activeUUID == nil
                    ? nil : lastSeenToken.map(ClaudeCredentialBlob.fingerprint(of:)))
        }
    }
}
