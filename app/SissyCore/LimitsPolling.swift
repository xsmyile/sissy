import Foundation

/// What a limits poll loop holds between two polls.
///
/// A value on the reader rather than a reader of its own, so every field is
/// isolated to the actor that runs the loop and a guard on `generation` never
/// has to cross a suspension to be read.
struct LimitsLoop {
    var pollTask: Task<Void, Never>?
    /// The request a refresh awaits, so "refreshing" ends when the vendor has
    /// answered rather than when the task was handed off.
    var firstRequest: Task<Duration, Never>?
    /// Bumped by every cancellation, so a request in flight when the reader
    /// was stopped or restarted cannot publish over the run that replaced it.
    var generation = 0
    /// Last condition logged, so a poll that keeps failing the same way says
    /// so once instead of every five minutes, and a *different* failure still
    /// gets through.
    var lastReported: String?
    /// Whether the next credential read may put a dialog on screen. Only the
    /// read a start the user asked for makes, and only the first one.
    var mayInteract = false
    /// Set by a poll whose read the user refused, which ends the loop once
    /// that poll has published. See `halt()`.
    var halting = false
}

/// The poll loop every reader that asks a vendor for its limits runs: the
/// first request and the sleep loop behind it, the generation that retires a
/// cancelled run, the refresh a user asks for, the wait a 429 earns and the
/// deduped log line.
///
/// One loop for the three readers (`ClaudeLimitsProbe`, `ClaudeWebSource`,
/// `CodexUsageSource`), which differ only in how a credential is read and
/// what a request asks. Written out once each they had drifted: two carried a
/// cancellation exception the third did not, and it could never fire.
///
/// The extension's methods are isolated to the conforming actor, so the loop
/// state is read and written on the same executor as the reader's own.
protocol LimitsPolling: Actor {
    /// What the reader publishes, compared before and after a poll so a
    /// steady state costs no emits.
    associatedtype Published: Equatable & Sendable

    nonisolated var published: LockedValue<Published> { get }
    /// Where in `Published` the reason for missing limits sits.
    static var limitsState: WritableKeyPath<Published, ProviderLimitsState> { get }
    static var refreshInterval: Duration { get }
    /// Who a refusal came from, as the log line names it.
    static var vendor: String { get }

    var loop: LimitsLoop { get set }
    /// Where a refusal is written down so the next run honours it. Nil is a
    /// reader that forgets its block when the process ends.
    var backoff: LimitsBackoffSlot? { get }

    /// The credential read and the request of one poll, and the wait the
    /// outcome earns.
    func readAndFetch(generation stamp: Int) async -> Duration
}

extension LimitsPolling {
    /// Starts the loop and hands back the first request, so an explicit
    /// refresh stays pending until credential, network and publication have
    /// all completed rather than ending on the hand-off.
    func begin(
        userInitiated: Bool, onRefresh: @Sendable @escaping () async -> Void
    ) -> Task<Duration, Never> {
        loop.mayInteract = userInitiated
        let request = Task { await refreshOnce(onRefresh: onRefresh) }
        loop.firstRequest = request
        loop.pollTask = Task { [weak self] in
            var delay = await request.value
            while !Task.isCancelled {
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self else { return }
                delay = await self.refreshOnce(onRefresh: onRefresh)
            }
        }
        return request
    }

    /// Restarts the loop and polls at once, returning only once that request
    /// has finished.
    ///
    /// Deliberately not a stop first: that drops the published windows, and
    /// a refresh that blanks the gauges it is trying to restore reads as a
    /// failure for as long as the request takes. The deduped log line is
    /// cleared so the outcome of the read the user just asked for is actually
    /// recorded. A block the vendor set is honoured: a refresh inside it asks
    /// nothing.
    func restart(userInitiated: Bool, onRefresh: @Sendable @escaping () async -> Void) async {
        if case .rateLimited(let until) = published.load()[keyPath: Self.limitsState],
            until > Date()
        {
            return
        }
        cancelRequests()
        loop.lastReported = nil
        let request = begin(userInitiated: userInitiated, onRefresh: onRefresh)
        await withTaskCancellationHandler {
            _ = await request.value
        } onCancel: {
            request.cancel()
        }
    }

    func cancelRequests() {
        loop.halting = false
        loop.generation &+= 1
        loop.pollTask?.cancel()
        loop.firstRequest?.cancel()
        loop.pollTask = nil
        loop.firstRequest = nil
    }

    /// One poll. Returns how long to wait before the next one.
    ///
    /// `onRefresh` fires on any change to the published reading, not only on
    /// new windows: an authorization that lapsed is a change the panel has to
    /// show, and it arrives on a day where no token event will follow it. A
    /// failed request publishes nothing, which is what preserves the age of
    /// the last successful reading beside the windows it produced.
    ///
    /// Internal rather than private so a test can run exactly one and assert
    /// on what it published. Waiting on the poll loop instead means waiting on
    /// the scheduler: the read is recorded before the outcome is classified,
    /// so an assertion hung off the read passes or fails by luck.
    func refreshOnce(onRefresh: @Sendable @escaping () async -> Void) async -> Duration {
        let stamp = loop.generation
        let before = published.load()
        let delay = await readAndFetch(generation: stamp)
        guard isCurrent(stamp) else { return delay }
        if published.load() != before { await onRefresh() }
        if loop.halting, stamp == loop.generation { cancelRequests() }
        return delay
    }

    /// Ends the loop once the poll in flight has published, for a credential
    /// read the user refused: nothing short of a restart they ask for may ask
    /// again.
    ///
    /// Not `cancelRequests()` from inside the poll, which is what the readers
    /// did: that bumped the generation the poll's own publication is checked
    /// against, so the refusal never called `onRefresh` and reached the panel
    /// only on some later emit.
    func halt() {
        loop.halting = true
    }

    /// Whether a poll that took `stamp` may still publish: no stop or
    /// restart has landed in its suspensions.
    ///
    /// The generation is checked rather than `pollTask != nil`, because a
    /// quick off/on leaves a *new* task in that property while the
    /// continuation asking still belongs to the cancelled one.
    func isCurrent(_ stamp: Int) -> Bool {
        stamp == loop.generation && !Task.isCancelled
    }

    /// Whether this read may ask the user, which only the first read after a
    /// start the user made may.
    func takeInteraction() -> Bool {
        defer { loop.mayInteract = false }
        return loop.mayInteract
    }

    /// Logs `message` the first time this condition is seen, and again only
    /// once something else has happened in between.
    func report(_ message: String) {
        guard loop.lastReported != message else { return }
        loop.lastReported = message
        sissyLog("sissy: \(message)")
    }

    /// The wait a refusal recorded on an earlier run still has left, and nil
    /// when there is none.
    ///
    /// Consulted before the credential rather than once at launch: the block
    /// belongs in front of every request that could meet it, and a reader
    /// stopped and started inside one would otherwise spend a request on a
    /// vendor that is still refusing. Everything after the first poll of a
    /// block reads it as already expired, because the sleep this returns is
    /// exactly as long as the deadline it names.
    ///
    /// Reading the record is a suspension, so it is `stamp` that decides
    /// whether the answer may still be published: a stop that landed in it
    /// has already cleared the row, and a block restored over that is the
    /// same defect as a reply arriving after the windows were dropped.
    func recordedBackoff(generation stamp: Int) async -> Duration? {
        guard let until = await backoff?.deadline() else { return nil }
        guard isCurrent(stamp) else { return Self.refreshInterval }
        let remaining = until.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        published.update { $0[keyPath: Self.limitsState] = .rateLimited(until: until) }
        report("still refused by \(Self.vendor) until \(until); waiting rather than asking")
        return .seconds(remaining)
    }

    /// The wait a 429 earns, published and recorded, and nil for any other
    /// error.
    ///
    /// The windows stay: a 429 says nothing about the last reading, which is
    /// still the last true one and whose age is the point.
    func backOff(after error: Error) async -> Duration? {
        guard case UsageRequestError.rateLimited(let retryAfter) = error else { return nil }
        let seconds = UsageRequestError.backoffSeconds(retryAfter: retryAfter)
        let until = Date().addingTimeInterval(seconds)
        published.update { $0[keyPath: Self.limitsState] = .rateLimited(until: until) }
        await backoff?.record(until)
        report("\(Self.vendor) answered 429; backing off until \(until)")
        return .seconds(seconds)
    }
}
