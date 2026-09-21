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
actor ClaudeAccountRegistry {
    /// What the app reads: who is known, who is active, and whether the last
    /// switch failed.
    struct Snapshot: Sendable, Equatable {
        var accounts: [ClaudeAccountIdentity] = []
        var activeUUID: String?
    }

    /// Why a switch did not happen. Each is a different sentence to the user:
    /// an account Sissy holds nothing for, a slot whose current owner it
    /// cannot establish, and the keychain refusing, which only the user can
    /// resolve.
    enum Failure: Error, Equatable {
        case notArchived
        case activeAccountUnknown
        case keychain(Int32)
    }

    /// The CLI's active slot: the keychain item a `claude` started with no
    /// `CLAUDE_CONFIG_DIR` reads, and the mirror of it in the default config
    /// home. Behind closures for the same reason the store's secrets are —
    /// this is the external I/O, and what the registry *decides* has to be
    /// testable without it.
    struct ActiveSlot: Sendable {
        var read: @Sendable () -> Data?
        /// What each of the CLI's other names for this home currently holds,
        /// a name with no item of its own simply absent from the answer.
        ///
        /// It throws where the lookup itself failed, because the two cases are
        /// not the same fact: a name Sissy could not read is one it is about
        /// to overwrite blind, and reporting that as "no such item" is how a
        /// slot gets left on the previous account with the switch calling
        /// itself a success.
        var readSiblings: @Sendable () throws -> [Data]
        var write: @Sendable (Data) throws -> Void

        /// Reads and writes nothing. What a test gets unless it asks for the
        /// real keychain, so a suite can never read the machine's own
        /// credential or identify it over the network.
        static let inert = ActiveSlot(
            read: { nil }, readSiblings: { [] }, write: { _ in })

        /// The slot of the config home Sissy actually meters.
        ///
        /// Taken from the resolved home rather than assumed to be the default
        /// one: a `claudeDataDir` pointed elsewhere is metered from that home,
        /// and its credential is filed under that home's own service name. A
        /// slot hardcoded to the unscoped item would watch an account nobody
        /// is metering and write a switch into a home nobody is reading.
        ///
        /// Every sibling item the CLI keeps for that home is written too, and
        /// only the ones it already keeps: a switch that reached one of the
        /// pair the default home now carries would leave the other naming the
        /// previous account, and creating an item the CLI never had would put
        /// a credential somewhere nothing reads it back from. Existence is
        /// asked by reading rather than by a boolean probe, so a lookup that
        /// failed cannot pass for a name that is not there.
        ///
        /// The mirror beside the keychain items is written on the same terms,
        /// so this can never create a plaintext credential where the CLI had
        /// none — and an atomic write onto an existing file keeps its `0600`.
        /// A write that fails part way fails the whole switch rather than
        /// being undone: leaving one name on the previous account while
        /// another names the new one is the ambiguity this type exists to
        /// avoid, and a retry is what repairs it.
        static func live(home: ProviderHome) -> ActiveSlot {
            let service = ClaudeKeychainCLI.claudeService(for: home.home)
            let siblings = ClaudeKeychainCLI.siblingClaudeServices(for: home.home)
            let mirror = home.claudeCredentialsURL
            return ActiveSlot(
                read: {
                    try? ClaudeKeychainCLI.read(
                        service: service, account: ClaudeKeychainCLI.claudeLoginName())
                },
                readSiblings: {
                    let account = ClaudeKeychainCLI.claudeLoginName()
                    return try siblings.compactMap { sibling in
                        do {
                            return try ClaudeKeychainCLI.read(service: sibling, account: account)
                        } catch ClaudeKeychainCLI.Failure.noItem {
                            return nil
                        }
                    }
                },
                write: { data in
                    let account = ClaudeKeychainCLI.claudeLoginName()
                    try ClaudeKeychainCLI.write(data, service: service, account: account)
                    for sibling in siblings {
                        do {
                            _ = try ClaudeKeychainCLI.read(service: sibling, account: account)
                        } catch ClaudeKeychainCLI.Failure.noItem {
                            continue
                        }
                        try ClaudeKeychainCLI.write(data, service: sibling, account: account)
                    }
                    guard FileManager.default.fileExists(atPath: mirror.path) else { return }
                    try data.write(to: mirror, options: .atomic)
                })
        }
    }

    private let store: ClaudeAccountStore
    private let slot: ActiveSlot
    /// Resolves a token to its owner. Injected so a test can exercise the
    /// capture without reaching Anthropic — the network is the only part of
    /// this that cannot be stood in for by the keychain.
    private let identify: @Sendable (String) async throws -> ClaudeAccountIdentity
    /// Access token of the credential last seen active, so a poll that finds
    /// it unchanged costs nothing. Only a token Sissy has not already filed
    /// buys a request.
    private var lastSeenToken: String?
    nonisolated private let published = LockedValue(Snapshot())

    /// A registry that knows nothing and learns nothing: no keychain, no
    /// network, no index on disk. The default everywhere an engine is built
    /// without one.
    static func inert() -> ClaudeAccountRegistry {
        var store = ClaudeAccountStore(indexURL: URL(fileURLWithPath: "/dev/null"))
        store.secrets = ClaudeAccountStore.Secrets(
            read: { _ in nil }, write: { _, _ in })
        return ClaudeAccountRegistry(store: store, slot: .inert) { _ in
            throw ClaudeAccountProfile.Failure.malformedPayload
        }
    }

    init(
        store: ClaudeAccountStore,
        slot: ActiveSlot,
        identify: @escaping @Sendable (String) async throws -> ClaudeAccountIdentity = {
            try await ClaudeAccountProfile.resolve(token: $0)
        }
    ) {
        self.store = store
        self.slot = slot
        self.identify = identify
        let index = store.loadIndex()
        published.update { $0 = Snapshot(accounts: index.accounts, activeUUID: index.activeUUID) }
    }

    nonisolated func currentSnapshot() -> Snapshot { published.load() }

    /// Reads the active credential and archives it when it is one Sissy has
    /// not seen. Cheap when nothing has changed, which is the ordinary case.
    ///
    /// Answers whether the published snapshot moved, so the caller can emit on
    /// the one event that produces no token of its own — someone signing into
    /// a different account in a terminal Sissy is not watching.
    @discardableResult
    func captureActive() async -> Bool {
        guard let credential = slot.read() else { return false }
        guard let parsed = ClaudeCredentialsStore.parse(credential),
            parsed.accessToken != lastSeenToken
        else { return false }
        let before = published.load()
        await file(credential: credential, markActive: true)
        return published.load() != before
    }

    /// Makes an archived account the one Claude Code starts as.
    ///
    /// Writes the CLI's own slots and nothing else, which is safe precisely
    /// because they are no longer where the account lives: whatever this
    /// overwrites, Sissy still holds. Every name the CLI reads that home's
    /// credential from is written, because which of them it reads first is its
    /// business and a switch that only reached one would half happen — and
    /// because a retry after a write that failed part way is what repairs the
    /// names it did not reach.
    ///
    /// Nothing is overwritten that Sissy has not archived first, and that is
    /// one rule rather than one per name. The slot's own credential earns it
    /// by the capture in front of the test: a slot this accepts is one whose
    /// archive is the same bytes, so the write that follows cannot be a
    /// downgrade. A sibling holding something else earns it by being archived
    /// here, because the capture reads only the primary name and a sibling can
    /// legitimately differ — an earlier build wrote one of the pair and left
    /// the other on the account it switched away from.
    ///
    /// The slots are read once more between the last identification and the
    /// write, because every reading above it sits behind a network round trip
    /// and the CLI rotates on its own schedule. A slot that moved in that
    /// window holds a credential nothing has archived, so the switch is
    /// abandoned rather than completed over it; the click is the user's to
    /// make again, and by then the rotation is captured.
    ///
    /// A credential Sissy cannot account for is not written over at all.
    /// Which account a slot holds is what decides whether this is a switch or
    /// a re-affirmation, and both readings are destructive when guessed: a
    /// stale archive written over the same account's live credential hands the
    /// CLI a refresh token that may already have been spent, and a switch away
    /// from an account whose rotation nobody saw spends the last copy of it
    /// this Mac has.
    func activate(uuid: String) async -> Result<Void, Failure> {
        guard store.credential(uuid: uuid) != nil else { return .failure(.notArchived) }
        await captureActive()
        let live = slot.read()
        if let live {
            guard isAccountedFor(live) else { return .failure(.activeAccountUnknown) }
        }
        let siblings: [Data]
        do {
            siblings = try slot.readSiblings()
        } catch {
            return .failure(Self.failure(from: error))
        }
        for sibling in siblings where sibling != live && !isAccountedFor(sibling) {
            guard await file(credential: sibling, markActive: false) else {
                return .failure(.activeAccountUnknown)
            }
        }
        guard let credential = store.credential(uuid: uuid) else { return .failure(.notArchived) }
        do {
            guard slot.read() == live, try slot.readSiblings() == siblings else {
                return .failure(.activeAccountUnknown)
            }
            try slot.write(credential)
        } catch {
            return .failure(Self.failure(from: error))
        }
        lastSeenToken = ClaudeCredentialsStore.parse(credential)?.accessToken
        setActive(uuid)
        sissyLog("sissy: wrote the Claude Code credential for \(uuid) into the CLI's slots")
        return .success(())
    }

    /// Identifies a credential and archives it. A token the vendor will not
    /// answer for — expired, offline, an account that has been removed — is
    /// left alone rather than filed under a guess, and the next poll tries
    /// again.
    @discardableResult
    private func file(credential: Data, markActive: Bool) async -> Bool {
        guard let parsed = ClaudeCredentialsStore.parse(credential) else { return false }
        let identity: ClaudeAccountIdentity
        do {
            identity = try await identify(parsed.accessToken)
        } catch {
            sissyLog("sissy: could not identify a Claude credential: \(error)")
            return false
        }
        do {
            try store.remember(identity, credential: credential)
        } catch {
            sissyLog("sissy: could not archive the Claude account \(identity.uuid): \(error)")
            return false
        }
        if markActive {
            lastSeenToken = parsed.accessToken
            setActive(identity.uuid)
        } else {
            publishIndex()
        }
        return true
    }

    /// Whether overwriting these bytes would lose anything.
    ///
    /// Two answers, and each is sufficient on its own. This run identified
    /// them, so the archive holds that account at least as fresh; or the
    /// archive already holds these exact bytes, which is proof that cost no
    /// network turn and cannot expire. The second is what keeps an archived
    /// account switchable on a Mac whose CLI has not run for hours: its access
    /// token has expired, the profile endpoint answers 401 to it, and
    /// re-identifying it is the one thing that cannot be done — while the
    /// bytes in question are Sissy's own copy of a credential it identified
    /// when it was young. Without it a relaunch, which forgets the token it
    /// last saw, would refuse every switch until the user went and ran the CLI.
    private func isAccountedFor(_ credential: Data) -> Bool {
        if let token = ClaudeCredentialsStore.parse(credential)?.accessToken,
            token == lastSeenToken
        {
            return true
        }
        return store.loadIndex().accounts
            .contains { store.credential(uuid: $0.uuid) == credential }
    }

    /// How the keychain's own refusals reach the user: a status that names the
    /// tool's exit code, or an item that is simply not there.
    private static func failure(from error: Error) -> Failure {
        guard case ClaudeKeychainCLI.Failure.tool(let status) = error else { return .notArchived }
        return .keychain(status)
    }

    private func setActive(_ uuid: String) {
        var index = store.loadIndex()
        index.activeUUID = uuid
        try? store.saveIndex(index)
        published.update { $0 = Snapshot(accounts: index.accounts, activeUUID: index.activeUUID) }
    }

    private func publishIndex() {
        let index = store.loadIndex()
        published.update { $0 = Snapshot(accounts: index.accounts, activeUUID: index.activeUUID) }
    }
}
