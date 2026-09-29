import Foundation

/// Reads the disks once a minute and publishes what it read, behind
/// `ServerConfig.disk`.
///
/// **Its own monitor rather than a field of `SystemHealthMonitor`'s**, because
/// it is its own switch: memory off and disk on is a Mac whose Disk tab and
/// menu bar dot still answer for the disk, and a disk read that rode the
/// memory sampler would stop with it.
///
/// **The read never runs on this actor.** A resource value is a synchronous
/// filesystem call with no bound, and `stop()` is what the engine awaits on
/// its way down: a read holding the actor would hold the switch, the engine's
/// `stop()` and the quit behind it. So the read goes to a dispatch thread
/// through `DiskReadGate`, one at a time, and a poll that is cancelled leaves
/// it there rather than waiting for it.
///
/// In memory and nowhere else, and needing no permission, no entitlement and
/// no network, for `SystemHealthMonitor`'s reasons.
actor DiskMonitor {
    /// How long a disk reading is reused before it is taken again.
    ///
    /// A read costs 6.7 ms of CPU per volume, measured 2026-09-28, more than
    /// the whole process sweep; once a minute it is a quarter of that sweep's
    /// cost, and a disk does not cross a multiple of RAM between two reads
    /// unless swap is growing into it, which the kernel's memory level
    /// answers first.
    static let readInterval: Duration = .seconds(60)

    nonisolated private let published = LockedValue<DiskReading?>(nil)
    private var pollTask: Task<Void, Never>?
    /// Which `start()` a read belongs to, so one that returns after a `stop()`
    /// cannot publish into the `start()` after it.
    private var generation = 0
    private let gate = DiskReadGate()
    private let read: @Sendable (Date) -> DiskReading

    init(read: @escaping @Sendable (Date) -> DiskReading = { DiskReader.read(now: $0) }) {
        self.read = read
    }

    /// The reading the frame carries, or nil before the first read and after
    /// `stop()`.
    nonisolated func currentReading() -> DiskReading? { published.load() }

    func start(onRefresh: @Sendable @escaping () async -> Void) {
        guard pollTask == nil else { return }
        generation += 1
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sampleOnce(onRefresh: onRefresh)
                do { try await Task.sleep(for: Self.readInterval) } catch { return }
            }
        }
    }

    /// Stops reading and drops what was published, so a module switched off
    /// leaves nothing on the next frame. Never waits for a read in flight.
    func stop() {
        generation += 1
        pollTask?.cancel()
        pollTask = nil
        published.store(nil)
    }

    /// One read and the frame after it. Internal so a test can run exactly
    /// one. A read that was cancelled, or that returned after a `stop()`,
    /// publishes nothing.
    func sampleOnce(onRefresh: @Sendable @escaping () async -> Void) async {
        guard !Task.isCancelled else { return }
        let started = generation
        guard let reading = await readOffActor(), !Task.isCancelled, started == generation
        else { return }
        published.store(reading)
        await onRefresh()
    }

    private func readOffActor() async -> DiskReading? {
        let id = UUID()
        let gate = gate
        let read = read
        let reading = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if gate.join(id, continuation) {
                    DispatchQueue.global(qos: .utility).async {
                        gate.finish(read(Date()))
                    }
                }
            }
        } onCancel: {
            gate.leave(id)
        }
        gate.forget(id)
        return reading
    }
}

/// The single disk read in flight and everyone waiting on it, on
/// `KeychainLookupGate`'s terms.
///
/// One at a time, because a read stuck in the filesystem parks its dispatch
/// thread, and a second read behind the same stuck volume would park a
/// second. A waiter that leaves is answered nil at once, and one that leaves
/// before it joined is answered nil when it does.
final class DiskReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = false
    private var waiters: [UUID: CheckedContinuation<DiskReading?, Never>] = [:]
    private var left: Set<UUID> = []

    /// Registers `id` as a waiter and reports whether this caller is the one
    /// that has to run the read.
    func join(_ id: UUID, _ continuation: CheckedContinuation<DiskReading?, Never>) -> Bool {
        lock.lock()
        if left.remove(id) != nil {
            lock.unlock()
            continuation.resume(returning: nil)
            return false
        }
        waiters[id] = continuation
        let runs = !inFlight
        inFlight = true
        lock.unlock()
        return runs
    }

    /// The read returned. Hands it to everyone still waiting and reopens the
    /// slot.
    func finish(_ reading: DiskReading) {
        lock.lock()
        inFlight = false
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in pending.values { continuation.resume(returning: reading) }
    }

    /// A waiter was cancelled. It leaves alone, and the read stays in flight
    /// for anyone else.
    func leave(_ id: UUID) {
        lock.lock()
        let abandoned = waiters.removeValue(forKey: id)
        if abandoned == nil { left.insert(id) }
        lock.unlock()
        abandoned?.resume(returning: nil)
    }

    /// The waiter is done and its cancellation handler can no longer run.
    ///
    /// A cancel landing after `finish` had already answered it finds no
    /// waiter and records the id as one that left before joining, which no
    /// `join` will ever come to collect. Clearing it here, once the handler's
    /// scope has closed, is what keeps that race from leaving one id behind
    /// for the life of the process.
    func forget(_ id: UUID) {
        lock.lock()
        left.remove(id)
        lock.unlock()
    }
}
