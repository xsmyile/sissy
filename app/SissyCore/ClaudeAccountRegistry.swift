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
    /// one is an account Sissy holds nothing for, the other is the keychain
    /// refusing, which only the user can resolve.
    enum Failure: Error, Equatable {
        case notArchived
        case keychain(Int32)
    }

    /// The CLI's active slot: the keychain item a `claude` started with no
    /// `CLAUDE_CONFIG_DIR` reads, and the mirror of it in the default config
    /// home. Behind closures for the same reason the store's secrets are —
    /// this is the external I/O, and what the registry *decides* has to be
    /// testable without it.
    struct ActiveSlot: Sendable {
        var read: @Sendable () -> Data?
        var write: @Sendable (Data) throws -> Void

        /// Reads and writes nothing. What a test gets unless it asks for the
        /// real keychain, so a suite can never read the machine's own
        /// credential or identify it over the network.
        static let inert = ActiveSlot(read: { nil }, write: { _ in })

        /// The slot of the config home Sissy actually meters.
        ///
        /// Taken from the resolved home rather than assumed to be the default
        /// one: a `claudeDataDir` pointed elsewhere is metered from that home,
        /// and its credential is filed under that home's own service name. A
        /// slot hardcoded to the unscoped item would watch an account nobody
        /// is metering and write a switch into a home nobody is reading.
        ///
        /// The mirror beside the keychain item is written only when the CLI
        /// already keeps one, so this can never create a plaintext credential
        /// where the CLI had none — and an atomic write onto an existing file
        /// keeps its `0600`. A mirror that cannot be written fails the whole
        /// switch: leaving it naming the previous account while the keychain
        /// names the new one is the ambiguity this type exists to avoid.
        static func live(home: ProviderHome) -> ActiveSlot {
            let service = ClaudeKeychainCLI.claudeService(for: home.home)
            let mirror = home.claudeCredentialsURL
            return ActiveSlot(
                read: {
                    try? ClaudeKeychainCLI.read(
                        service: service, account: ClaudeKeychainCLI.claudeLoginName())
                },
                write: { data in
                    try ClaudeKeychainCLI.write(
                        data, service: service, account: ClaudeKeychainCLI.claudeLoginName())
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
    /// overwrites, Sissy still holds. Both the keychain item and the mirror in
    /// the default config home are written, because which of the two the CLI
    /// reads first is its business and a switch that only reached one of them
    /// would half happen.
    func activate(uuid: String) async -> Result<Void, Failure> {
        guard let credential = store.credential(uuid: uuid) else { return .failure(.notArchived) }
        do {
            try slot.write(credential)
        } catch let failure as ClaudeKeychainCLI.Failure {
            guard case .tool(let status) = failure else { return .failure(.notArchived) }
            return .failure(.keychain(status))
        } catch {
            return .failure(.keychain(0))
        }
        lastSeenToken = ClaudeCredentialsStore.parse(credential)?.accessToken
        setActive(uuid)
        return .success(())
    }

    /// Identifies a credential and archives it. A token the vendor will not
    /// answer for — expired, offline, an account that has been removed — is
    /// left alone rather than filed under a guess, and the next poll tries
    /// again.
    private func file(credential: Data, markActive: Bool) async {
        guard let parsed = ClaudeCredentialsStore.parse(credential) else { return }
        let identity: ClaudeAccountIdentity
        do {
            identity = try await identify(parsed.accessToken)
        } catch {
            sissyLog("sissy: could not identify a Claude credential: \(error)")
            return
        }
        do {
            try store.remember(identity, credential: credential)
        } catch {
            sissyLog("sissy: could not archive the Claude account \(identity.uuid): \(error)")
            return
        }
        if markActive {
            lastSeenToken = parsed.accessToken
            setActive(identity.uuid)
        } else {
            publishIndex()
        }
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
