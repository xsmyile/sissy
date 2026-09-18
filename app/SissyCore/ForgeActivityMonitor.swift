import Foundation

/// Polls each connected forge for the two counters the Overview prints.
///
/// It is not a `UsageProvider` and does not ride one, for the reasons
/// `ProviderStatusMonitor` is not either: the reading belongs to a forge
/// account rather than to a log tail, it costs no metering provider anything,
/// and it exists on a Mac where neither CLI has taken a turn. So it publishes
/// its own value and the engine hangs it on the frame beside the slices.
///
/// **Deliberately not shared with `ProviderStatusMonitor`, which is the same
/// shape.** The retry policy is what differs and it is the whole of what this
/// loop is for: a refused token cannot be fixed by asking again in five
/// minutes, so a connection whose failure `needsTheUser` is parked until the
/// user acts, where a status page that would not answer is simply asked again.
/// Sharing the loop would mean a parameter that turns the policy off for one
/// caller, which is two policies in one place rather than one each. A third
/// polled feed is when to extract the loop, not the second.
///
/// The cadence is the status monitor's, and for the same reason: these counters
/// move when the user pushes, which is what `noteActivity` already reports.
actor ForgeActivityMonitor {
    /// While there are agents working.
    static let refreshInterval: Duration = .seconds(300)
    /// Once nothing has been seen working for `idleAfter`. A contribution count
    /// on a Mac nobody is working at answers a question nobody is asking.
    static let idleRefreshInterval: Duration = .seconds(1800)
    static let idleAfter: TimeInterval = 3600
    /// Spread across the interval, so every Sissy started at login does not ask
    /// the same two APIs in the same second.
    static let jitterSeconds: ClosedRange<Int> = 0...30

    /// One reading per connection, published as one value: the panel reads the
    /// whole map while the poll may be part way through the next round, and a
    /// getter per connection would let it pair one round's GitHub with the next
    /// round's GitLab.
    nonisolated private let published = LockedValue([String: ForgeActivityReading]())
    /// When the engine last saw an agent do something, which is the only input
    /// to how often this polls. Nonisolated because it is written from the
    /// frame path, which cannot afford to await this actor.
    nonisolated private let lastActivity = LockedValue<Date?>(nil)
    private let connections: [ForgeConnection]
    /// Which counters to ask for. Held here rather than read per round because
    /// a change to it rebuilds the monitor, exactly as a change to the
    /// connections does — the poll has no mutable configuration.
    private let counters: Set<ForgeCounter>
    /// The network half, injectable for the reason every other reader's is: a
    /// test of the poll contract must not reach a forge to observe it.
    private let fetchSource:
        @Sendable (ForgeConnection, String, Set<ForgeCounter>, Date) async throws ->
            ForgeActivityReading
    /// The token lookup, injectable for the same reason — a test must not need
    /// a keychain item to assert what a missing token does to a row. It hands
    /// back the keychain's own outcome rather than an optional, because "never
    /// connected" and "the grant has gone stale" are different rows.
    private let tokenSource: @Sendable (String) -> CredentialLookup<String>
    private var pollTask: Task<Void, Never>?
    /// Connections whose last failure needs the user. They keep their row and
    /// their last figures; what they stop costing is a request per round.
    private var parked: Set<String> = []
    /// Bumped by every stop, so a request in flight when the monitor was torn
    /// down cannot publish over the run that replaced it.
    private var generation = 0

    init(
        connections: [ForgeConnection],
        counters: Set<ForgeCounter> = ForgeCounter.all,
        fetch:
            @escaping @Sendable (ForgeConnection, String, Set<ForgeCounter>, Date) async throws ->
            ForgeActivityReading = {
                try await ForgeActivityFeed.read($0, token: $1, counters: $2, now: $3)
            },
        token: @escaping @Sendable (String) -> CredentialLookup<String> = {
            ForgeTokenStore.load(connection: $0)
        }
    ) {
        self.connections = connections
        self.counters = counters
        fetchSource = fetch
        tokenSource = token
    }

    nonisolated func currentActivity() -> [String: ForgeActivityReading] { published.load() }

    /// Every connection's reading, in the order the index gave them, so the
    /// panel's rows cannot trade places between polls. A connection nothing has
    /// been published for at all is absent rather than drawn as a zero.
    nonisolated func currentReadings() -> [ForgeActivityReading] {
        let readings = published.load()
        return connections.compactMap { readings[$0.id] }
    }

    nonisolated func noteActivity(at when: Date = Date()) {
        lastActivity.update { $0 = when }
    }

    /// Starts the poll loop. `onRefresh` fires only when the published map
    /// changes, so a forge that keeps answering the same counts costs no
    /// frames. Idempotent, and a no-op for a build with nothing connected.
    func start(onRefresh: @Sendable @escaping () async -> Void) {
        guard pollTask == nil, !connections.isEmpty else { return }
        pollTask = Task { [weak self] in
            var delay: Duration = .zero
            while !Task.isCancelled {
                if delay > .zero {
                    do { try await Task.sleep(for: delay) } catch { return }
                }
                guard let self else { return }
                delay = await self.refreshOnce(onRefresh: onRefresh)
            }
        }
    }

    /// Stops the loop and drops what it published.
    ///
    /// Dropping is the point, and it is the rule every reader in this app stops
    /// under: the engine rebuilds every frame from `currentActivity()`, so a
    /// cancelled loop would otherwise leave a contribution count standing under
    /// a connection the user has just removed.
    func stop() {
        generation &+= 1
        pollTask?.cancel()
        pollTask = nil
        parked.removeAll()
        published.store([:])
    }

    /// One round: every connection at once, bounded by the group. Returns how
    /// long to wait before the next.
    ///
    /// Internal rather than private so a test can run exactly one round and
    /// assert on what it published, instead of waiting on the scheduler.
    func refreshOnce(onRefresh: @Sendable @escaping () async -> Void) async -> Duration {
        let stamp = generation
        let before = published.load()
        let due = connections.filter { !parked.contains($0.id) }
        await withTaskGroup(of: (ForgeConnection, Result<ForgeActivityReading, Error>).self) {
            group in
            for connection in due {
                let fetch = fetchSource
                let token = tokenSource
                let counters = counters
                group.addTask {
                    guard case .found(let secret) = token(connection.id) else {
                        return (connection, .failure(Self.credentialFailure(token(connection.id))))
                    }
                    do {
                        return (
                            connection,
                            .success(try await fetch(connection, secret, counters, Date()))
                        )
                    } catch {
                        return (connection, .failure(error))
                    }
                }
            }
            for await (connection, outcome) in group {
                guard stamp == generation, !Task.isCancelled else { continue }
                apply(outcome, for: connection)
            }
        }
        guard stamp == generation, !Task.isCancelled else { return nextDelay() }
        if published.load() != before { await onRefresh() }
        return nextDelay()
    }

    /// What a keychain outcome that is not a token means to a row.
    ///
    /// Only an item that is genuinely absent is reported as a missing
    /// credential, which is the one of these the user can act on. Everything
    /// else is the keychain declining to answer *this* read — a stale grant
    /// after a re-signed build is the ordinary case — and it stays retryable so
    /// the next poll can pick the account back up on its own.
    private static func credentialFailure(_ outcome: CredentialLookup<String>) -> ForgeReadFailure {
        switch outcome {
        case .absent: .noCredential
        case .found, .denied, .interactionRequired, .unreadable, .timedOut: .credentialUnreadable
        }
    }

    /// A reading replaces whatever was there; a failure keeps the figures and
    /// takes the reason.
    ///
    /// **The age is not touched by a failure**, which is the honest signal: the
    /// figures on the row were true when they were read, and how long ago that
    /// was is what says whether to trust them. Republishing a failed round with
    /// a new stamp would date a reading nobody took. A connection that has
    /// never answered gets the one `unavailable` row it keeps until a fetch
    /// works, whose stamp is its own because there is no earlier reading for it
    /// to misdate.
    private func apply(_ outcome: Result<ForgeActivityReading, Error>, for connection: ForgeConnection) {
        switch outcome {
        case .success(let reading):
            parked.remove(connection.id)
            published.update { $0[connection.id] = reading }
        case .failure(let error):
            let failure = (error as? ForgeReadFailure) ?? .malformed
            if failure.needsTheUser { parked.insert(connection.id) }
            published.update { map in
                guard let previous = map[connection.id], previous.login != nil else {
                    map[connection.id] = .unavailable(connection, failure: failure)
                    return
                }
                map[connection.id] = ForgeActivityReading(
                    id: previous.id, kind: previous.kind, host: previous.host,
                    login: previous.login, activity: previous.activity,
                    readAt: previous.readAt, failure: failure)
            }
        }
    }

    private func nextDelay() -> Duration {
        let working = lastActivity.load().map { Date().timeIntervalSince($0) < Self.idleAfter }
        let base = working == true ? Self.refreshInterval : Self.idleRefreshInterval
        return base + .seconds(Int.random(in: Self.jitterSeconds))
    }
}
