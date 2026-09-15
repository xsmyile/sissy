import Foundation

/// Polls each metering vendor's public status page, so "is it me or them" is
/// answered in the panel instead of in a browser tab.
///
/// It is not a `UsageProvider` and does not ride one: a status belongs to the
/// vendor rather than to the log tail, it is the same answer for every account
/// of that vendor, and it exists for a provider that has not produced a token
/// reading yet. So it publishes its own value and the engine hangs it on the
/// frame beside the slices.
///
/// Three rules the feed itself imposes. The poll is slow, because a status
/// page moves on incidents rather than on polls and this is the one reading
/// Sissy takes that nobody asked for by name. A failed fetch publishes
/// nothing, so the row keeps its last known state and its age — which is the
/// honest signal, since the age is what says how long ago that state was true.
/// And a feed that has never answered says `unknown`, never an outage.
actor ProviderStatusMonitor {
    /// While there are agents working.
    static let refreshInterval: Duration = .seconds(300)
    /// Once nothing has been seen working for `idleAfter`. A status page read
    /// on a Mac nobody is working on answers a question nobody is asking.
    static let idleRefreshInterval: Duration = .seconds(1800)
    static let idleAfter: TimeInterval = 3600
    /// Spread across the interval, so every Sissy started at login does not
    /// ask the same two pages in the same second.
    static let jitterSeconds: ClosedRange<Int> = 0...30

    /// One reading per provider, published as one value: the panel reads the
    /// whole map while the poll may be part way through the next round, and a
    /// getter per provider would let it pair one round's Claude with the next
    /// round's Codex.
    nonisolated private let published = LockedValue([String: ProviderStatusReading]())
    /// When the engine last saw an agent do something, which is the only input
    /// to how often this polls. Nonisolated because it is written from the
    /// frame path, which cannot afford to await this actor.
    nonisolated private let lastActivity = LockedValue<Date?>(nil)
    private let feeds: [String: ProviderStatusFeed]
    /// The network half, injectable for the reason `ClaudeLimitsProbe`'s is: a
    /// test of the poll contract must not reach a vendor to observe it.
    private let fetchSource: @Sendable (ProviderStatusFeed) async throws -> ProviderStatusReading
    private var pollTask: Task<Void, Never>?
    /// Bumped by every stop, so a request in flight when the monitor was torn
    /// down cannot publish over the run that replaced it.
    private var generation = 0

    init(
        providers: [String],
        fetch: @escaping @Sendable (ProviderStatusFeed) async throws -> ProviderStatusReading = {
            try await ProviderStatusMonitor.read($0)
        }
    ) {
        feeds = Dictionary(
            uniqueKeysWithValues: providers.compactMap { id in
                ProviderStatusFeed.feed(for: id).map { (id, $0) }
            })
        fetchSource = fetch
    }

    /// One provider's whole reading, by the shape its vendor publishes.
    ///
    /// A page that answers both halves in one document costs one request; the
    /// one that splits them costs two, and the second is best-effort — a
    /// component list that failed leaves the sentence standing, and `publish`
    /// keeps whichever tree was last read rather than blanking it.
    static func read(_ feed: ProviderStatusFeed, checkedAt: Date = Date()) async throws
        -> ProviderStatusReading
    {
        switch feed.components {
        case .statuspage:
            return try await StatuspageFeed.summary(root: feed.root, checkedAt: checkedAt)
        case .incidentIO:
            let reading = try await StatuspageFeed.fetch(root: feed.root, checkedAt: checkedAt)
            guard let components = try? await IncidentIOFeed.components(root: feed.root) else {
                return reading
            }
            return reading.with(components: components)
        }
    }

    nonisolated func currentStatus() -> [String: ProviderStatusReading] { published.load() }

    nonisolated func noteActivity(at when: Date = Date()) {
        lastActivity.update { $0 = when }
    }

    /// Starts the poll loop. `onRefresh` fires only when the published map
    /// changes, so a vendor that keeps answering the same thing costs no
    /// frames. Idempotent, and a no-op for a build with no feed to read.
    func start(onRefresh: @Sendable @escaping () async -> Void) {
        guard pollTask == nil, !feeds.isEmpty else { return }
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
    /// Dropping is the point, and it is the same rule the limits probe stops
    /// under: the engine rebuilds every frame from `currentStatus()`, so a
    /// cancelled loop would otherwise leave a status row standing under a
    /// switch the user has just turned off, dated to whenever it last managed
    /// to read.
    func stop() {
        generation &+= 1
        pollTask?.cancel()
        pollTask = nil
        published.store([:])
    }

    /// One round: every feed at once, bounded by the group. Returns how long
    /// to wait before the next.
    ///
    /// Internal rather than private so a test can run exactly one round and
    /// assert on what it published, instead of waiting on the scheduler.
    func refreshOnce(onRefresh: @Sendable @escaping () async -> Void) async -> Duration {
        let stamp = generation
        let before = published.load()
        await withTaskGroup(of: (String, ProviderStatusReading?).self) { group in
            for (id, root) in feeds {
                let fetch = fetchSource
                group.addTask { (id, try? await fetch(root)) }
            }
            for await (id, reading) in group {
                guard stamp == generation, !Task.isCancelled else { continue }
                publish(reading, for: id)
            }
        }
        guard stamp == generation, !Task.isCancelled else { return nextDelay() }
        if published.load() != before { await onRefresh() }
        return nextDelay()
    }

    /// Re-reads one vendor, for the refresh button on that provider's page —
    /// which promises to re-read what this provider answers for out of band,
    /// and the status page is now part of that.
    func refresh(provider id: String, onRefresh: @Sendable @escaping () async -> Void) async {
        guard let root = feeds[id] else { return }
        let stamp = generation
        let before = published.load()
        let reading = try? await fetchSource(root)
        guard stamp == generation, !Task.isCancelled else { return }
        publish(reading, for: id)
        if published.load() != before { await onRefresh() }
    }

    /// A reading replaces whatever was there, except for a tree it could not
    /// read: the component list is the best-effort half, so one that failed
    /// keeps the last one rather than collapsing the row's detail because a
    /// second request timed out.
    ///
    /// A failure replaces nothing at all: the previous state keeps its own
    /// age, and a provider that has never answered gets the one `unknown` row
    /// it will keep until a fetch works — republishing that on every failed
    /// round would move an age that dates a reading nobody ever took.
    private func publish(_ reading: ProviderStatusReading?, for id: String) {
        guard let reading else {
            published.update { map in
                guard map[id] == nil else { return }
                map[id] = .unavailable(at: Date())
            }
            return
        }
        published.update { map in
            let previous = map[id]?.components ?? []
            map[id] =
                reading.components.isEmpty && !previous.isEmpty
                ? reading.with(components: previous) : reading
        }
    }

    private func nextDelay() -> Duration {
        let working = lastActivity.load().map { Date().timeIntervalSince($0) < Self.idleAfter }
        let base = working == true ? Self.refreshInterval : Self.idleRefreshInterval
        return base + .seconds(Int.random(in: Self.jitterSeconds))
    }
}
