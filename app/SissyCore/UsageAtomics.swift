import Foundation

/// Lock-protected counter the reader actor shares with whoever asks how
/// many files are being watched. Reading it without the hop matters because
/// the actor is busy for the whole initial backfill: an `await
/// reader.filesWatched()` queues behind that scan, and the panel's
/// warming state would be the last thing to learn the scan had started.
final class AtomicIntCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int = 0
    func load() -> Int { lock.withLock { value } }
    func store(_ v: Int) { lock.withLock { value = v } }
}

/// Lock-protected window snapshot, read without entering the owning actor.
///
/// The aggregator reads these while a provider is mid-emit — that is, while
/// the provider holds its own actor waiting on the emit callback. An `await`
/// back into the provider there deadlocks both sides, so the read has to be
/// synchronous, the same reason `filesWatched()` is nonisolated.
final class AtomicWindows: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [UsageWindow] = []
    func load() -> [UsageWindow] { lock.withLock { value } }
    func store(_ v: [UsageWindow]) { lock.withLock { value = v } }
    /// Drops buckets whose reset has passed: a window past its reset
    /// describes a period that no longer exists.
    func live(now: Date = Date()) -> [UsageWindow] {
        lock.withLock { value.filter { $0.resetsAt > now } }
    }
}

/// Same handoff as `AtomicWindows` for a plan token: an adapter parses it on
/// the provider's actor while `UsageProvider.currentPlan()` is read from
/// outside it. Unlike a window a plan never expires, so there is no `live()`
/// here.
final class AtomicPlan: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func load() -> String? { lock.withLock { value } }
    func store(_ v: String?) { lock.withLock { value = v } }
}
