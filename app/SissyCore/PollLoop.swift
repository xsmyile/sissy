import Foundation

/// One repeating piece of work an actor owns: wait, run a step, ask the step how
/// long to wait next.
///
/// A step that goes first starts with `first` at zero and a loop that sleeps
/// first starts with its interval, and a fixed cadence is a step returning the
/// same delay every time. A step answers nil to end the loop, which is what one
/// holding its owner weakly does once the owner has gone.
///
/// It also holds the generation, because stopping is what makes a reading stale.
/// A step, or a read started by a gesture beside it, takes `generation` before
/// it suspends and asks `isCurrent` before it publishes.
struct PollLoop {
    /// How much of a sleep macOS may slide it by, so the 15 s and 60 s timers
    /// coalesce rather than each waking the Mac on its own.
    static let toleranceShare = 0.1

    private var task: Task<Void, Never>?
    private(set) var generation = 0

    var isRunning: Bool { task != nil }

    /// Starts the loop, or does nothing when it is already running.
    ///
    /// `wait` throws only when the loop is cancelled, and defaults to `sleep`.
    mutating func start(
        first: Duration = .zero,
        wait: @escaping @Sendable (Duration) async throws -> Void = Self.sleep,
        step: @escaping @Sendable () async -> Duration?
    ) {
        guard task == nil else { return }
        task = Task { await Self.run(first: first, wait: wait, step: step) }
    }

    /// Cancels the loop and retires every stamp taken so far. Answers the task
    /// it cancelled, for a caller that has to see it finish.
    @discardableResult
    mutating func stop() -> Task<Void, Never>? {
        generation &+= 1
        defer { task = nil }
        task?.cancel()
        return task
    }

    /// Whether what was started under `stamp` may still publish.
    func isCurrent(_ stamp: Int) -> Bool {
        stamp == generation && !Task.isCancelled
    }

    /// The loop itself, on the calling task, for a caller that already owns the
    /// task it should run on and keeps state between steps.
    static func run(
        first: Duration = .zero,
        wait: (Duration) async throws -> Void = Self.sleep,
        step: () async -> Duration?
    ) async {
        var delay = first
        while !Task.isCancelled {
            if delay > .zero {
                do { try await wait(delay) } catch { return }
            }
            guard let next = await step() else { return }
            delay = next
        }
    }

    /// Sleeps `delay` on the continuous clock, so a Mac waking from a long sleep
    /// is due at once rather than owed the rest of the interval.
    @Sendable
    static func sleep(_ delay: Duration) async throws {
        try await Task.sleep(for: delay, tolerance: delay * toleranceShare)
    }
}

/// A poll's wait for a cadence that depends on whether agents are working.
///
/// The cadence is chosen from activity that can start *during* a wait, and
/// `ActivityClock.note` cannot wake a sleeping loop: it is written from the
/// frame path, which cannot afford to await an actor. So the wait is taken in
/// slices rather than in one sleep, and each slice asks again. A slice costs a
/// timer and no request.
///
/// `ContinuousClock` rather than `SuspendingClock` on purpose: it keeps counting
/// while the Mac is asleep, so one waking after a nine-hour lid-close polls at
/// once instead of serving out the rest of an interval nobody was there for.
struct ActivityPacedWait: Sendable {
    /// How often a wait looks up from its sleep to see whether work has begun.
    static let activityCheck: Duration = .seconds(60)

    let activity: ActivityClock
    /// The cadence while agents are working.
    let shortest: Duration
    var slice: Duration = activityCheck

    /// Whether a wait that has run for `waited` is over.
    ///
    /// The delay is the ceiling. The other way out is what the slices exist
    /// for: an idle wait was sized for a Mac nobody was working at, and once
    /// agents are working the short interval is the one in force, so a wait
    /// that has already covered it ends rather than serving out the rest of the
    /// idle delay chosen before the work started.
    static func isOver(
        waited: Duration, of delay: Duration, working: Bool, shortest: Duration
    ) -> Bool {
        if waited >= delay { return true }
        return working && waited >= shortest
    }

    /// Sleeps out `delay`, reconsidering it as it goes.
    @Sendable
    func wait(_ delay: Duration) async throws {
        let started = ContinuousClock.now
        while true {
            let waited = ContinuousClock.now - started
            let over = Self.isOver(
                waited: waited, of: delay, working: activity.isWorking(), shortest: shortest)
            if over { return }
            try await PollLoop.sleep(min(delay - waited, slice))
        }
    }
}
