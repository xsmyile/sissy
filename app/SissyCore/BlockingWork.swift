import Foundation
import Synchronization

/// Work that blocks its thread: a subprocess, a keychain read, a walk of a slow
/// volume.
///
/// It runs on a dispatch thread, so it parks that thread rather than one of the
/// cooperative pool's, which the whole runtime shares. `Task.detached` leaves an
/// actor and not the pool, so it is no substitute. An interactive read still
/// waits on its dialog for as long as it is up, which is why only a user's own
/// gesture makes one.
enum BlockingWork {
    /// Runs `work` and answers with what it answered. Cancelling the caller does
    /// not reach it: blocking work cannot observe a cancellation.
    static func run<Value: Sendable, Failure: Error>(
        qos: DispatchQoS.QoSClass = .utility,
        _ work: @escaping @Sendable () throws(Failure) -> Value
    ) async throws(Failure) -> Value {
        let result: Result<Value, Failure> = await withCheckedContinuation { continuation in
            start(qos: qos) { continuation.resume(returning: Result(catching: work)) }
        }
        return try result.get()
    }

    /// Starts `work` and does not wait, for a caller with its own way of hearing
    /// the answer.
    static func start(
        qos: DispatchQoS.QoSClass = .utility, _ work: @escaping @Sendable () -> Void
    ) {
        DispatchQueue.global(qos: qos).async(execute: work)
    }
}

/// The single blocking call in flight and everyone waiting on its answer.
///
/// One at a time is the whole point: a call stuck behind a dialog or a volume
/// parks its dispatch thread, and a second behind the same stall would park a
/// second. The waiters are independent of it. Each leaves on its own budget and
/// is answered `abandoned` at once, the call stays in flight, and whoever is
/// still there when it returns is served.
final class SingleFlight<Value: Sendable>: Sendable {
    private struct State {
        var inFlight = false
        var waiters: [UUID: CheckedContinuation<Value, Never>] = [:]
        var left: Set<UUID> = []
    }

    private let abandoned: Value
    private let state = Mutex(State())

    /// `abandoned` is what a waiter that leaves is answered.
    init(abandoned: Value) {
        self.abandoned = abandoned
    }

    /// Registers `id` as a waiter and reports whether this caller is the one
    /// that has to make the call. One that left before it joined is answered
    /// `abandoned` here.
    func join(_ id: UUID, _ continuation: CheckedContinuation<Value, Never>) -> Bool {
        let (alreadyLeft, runs) = state.withLock { state in
            if state.left.remove(id) != nil { return (true, false) }
            state.waiters[id] = continuation
            defer { state.inFlight = true }
            return (false, !state.inFlight)
        }
        if alreadyLeft { continuation.resume(returning: abandoned) }
        return runs
    }

    /// The call returned. Hands its answer to everyone still waiting and reopens
    /// the slot.
    func finish(_ value: Value) {
        let pending = state.withLock { state in
            state.inFlight = false
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        for continuation in pending.values { continuation.resume(returning: value) }
    }

    /// A waiter's budget ran out or it was cancelled. It leaves alone, and the
    /// call stays in flight for anyone else.
    func leave(_ id: UUID) {
        let waiter = state.withLock { state in
            let waiter = state.waiters.removeValue(forKey: id)
            if waiter == nil { state.left.insert(id) }
            return waiter
        }
        waiter?.resume(returning: abandoned)
    }

    /// The waiter is done and nothing can make it leave any more.
    ///
    /// A leave landing after `finish` had already answered it finds no waiter
    /// and records the id as one that left before joining, which no `join` will
    /// ever come to collect. Clearing it here, once whatever could call `leave`
    /// has finished, is what keeps that race from leaving one id behind for the
    /// life of the process.
    func forget(_ id: UUID) {
        state.withLock { _ = $0.left.remove(id) }
    }
}
