import Foundation

/// Reads the disks once a minute and publishes what it read, behind
/// `ServerConfig.disk`.
///
/// **Its own monitor rather than a field of `SystemHealthMonitor`'s**, because
/// it is its own switch: memory off and disk on is a Mac whose Disk tab and
/// menu bar dot still answer for the disk, and a disk read that rode the
/// memory sampler would stop with it.
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
    private let read: @Sendable (Date) -> DiskReading

    init(read: @escaping @Sendable (Date) -> DiskReading = DiskReader.read) {
        self.read = read
    }

    /// The reading the frame carries, or nil before the first read and after
    /// `stop()`.
    nonisolated func currentReading() -> DiskReading? { published.load() }

    func start(onRefresh: @Sendable @escaping () async -> Void) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sampleOnce(onRefresh: onRefresh)
                do { try await Task.sleep(for: Self.readInterval) } catch { return }
            }
        }
    }

    /// Stops reading and drops what was published, so a module switched off
    /// leaves nothing on the next frame.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        published.store(nil)
    }

    /// One read and the frame after it. Internal so a test can run exactly
    /// one; a read whose poll was cancelled while it waited for this actor
    /// publishes nothing, since `stop()` ran ahead of it.
    func sampleOnce(onRefresh: @Sendable @escaping () async -> Void) async {
        guard !Task.isCancelled else { return }
        published.store(read(Date()))
        await onRefresh()
    }
}
