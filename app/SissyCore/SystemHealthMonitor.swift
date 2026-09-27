import Dispatch
import Foundation

/// Samples what the Mac itself is answering, on the agent sweep's clock, and
/// again the moment the kernel's memory pressure moves.
///
/// Not a `UsageProvider`, for `AgentProcessMonitor`'s reasons: the Mac is not
/// a log tail and it exists on a day no CLI has taken a turn. It publishes its
/// own value and the engine hangs it on the frame.
///
/// **In memory and nowhere else.** A reading from before a relaunch describes
/// a Mac that has moved on, and a series of them is not what this answers:
/// the question is whether the Mac is struggling now. It needs no permission,
/// no entitlement and no network, which is why it can be on by default.
actor SystemHealthMonitor {
    /// The agent sweep's cadence, so the heaviest apps it carries are never
    /// more than one sweep behind the figures beside them.
    static let sampleInterval: Duration = AgentProcessMonitor.sampleInterval
    /// How long a disk reading is reused before it is taken again.
    ///
    /// The read costs 6.6 ms of CPU, measured 2026-09-27, more than the whole
    /// process sweep; spaced to once a minute it is a quarter of that cost, and
    /// a disk does not cross a multiple of RAM between two samples unless
    /// swap is growing into it, which the kernel's own level answers first.
    static let diskReadInterval: TimeInterval = 60
    /// How long a Mac whose level has not moved goes without a frame at the
    /// most. The colour follows the level on the sample that changes it; the
    /// numbers beside it can wait a minute.
    static let quietFrameInterval: TimeInterval = 60

    nonisolated private let published = LockedValue<MacHealthReading?>(nil)
    private var disk: (free: Int64?, at: Date)?
    private var lastFrameAt: Date?
    private var pollTask: Task<Void, Never>?
    private var pressureSource: DispatchSourceMemoryPressure?
    private let read: @Sendable (Date) -> MacHealthReading
    private let diskFree: @Sendable () -> Int64?
    /// The heaviest apps, which the agent sweep measures out of the same pass
    /// over the process table rather than this monitor walking it again.
    private let heaviest: @Sendable () -> MacHeaviestApps?

    init(
        read: @escaping @Sendable (Date) -> MacHealthReading = SystemHealthReader.read,
        diskFree: @escaping @Sendable () -> Int64? = SystemHealthReader.diskFree,
        heaviest: @escaping @Sendable () -> MacHeaviestApps? = { nil }
    ) {
        self.read = read
        self.diskFree = diskFree
        self.heaviest = heaviest
    }

    /// The reading the frame carries, or nil before the first sample and after
    /// `stop()`.
    nonisolated func currentReading() -> MacHealthReading? { published.load() }

    /// Starts sampling, and listens for the kernel's pressure transitions so a
    /// change publishes when it happens rather than on the next sample.
    func start(onRefresh: @Sendable @escaping () async -> Void) {
        guard pollTask == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { @Sendable [weak self] in
            Task { await self?.pressureChanged(onRefresh: onRefresh) }
        }
        source.activate()
        pressureSource = source
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sampleOnce(onRefresh: onRefresh)
                do { try await Task.sleep(for: Self.sampleInterval) } catch { return }
            }
        }
    }

    /// Stops sampling and drops what was published, so a module switched off
    /// leaves nothing on the next frame.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        pressureSource?.cancel()
        pressureSource = nil
        disk = nil
        lastFrameAt = nil
        published.store(nil)
    }

    /// A transition the kernel delivered. Ignored once stopped: the event can
    /// be queued behind a `stop()` and must not publish past it.
    private func pressureChanged(onRefresh: @Sendable @escaping () async -> Void) async {
        guard pollTask != nil else { return }
        await sampleOnce(forcingFrame: true, onRefresh: onRefresh)
    }

    /// One sample. Internal so a test can run exactly one and assert on what
    /// it published.
    ///
    /// A frame follows the first sample, any sample whose level differs from
    /// the one before, a pressure event, and otherwise one sample in every
    /// `quietFrameInterval`. A sample whose poll was cancelled while it waited
    /// for this actor publishes nothing, since `stop()` ran ahead of it.
    func sampleOnce(
        forcingFrame: Bool = false, onRefresh: @Sendable @escaping () async -> Void
    ) async {
        guard !Task.isCancelled else { return }
        let now = Date()
        var reading = read(now)
        if forcingFrame || disk.map({ now.timeIntervalSince($0.at) >= Self.diskReadInterval }) ?? true {
            disk = (diskFree(), now)
        }
        reading.diskFree = disk?.free
        reading.diskObservedAt = disk?.free == nil ? nil : disk?.at
        reading.heaviest = heaviest()
        let previous = published.load()
        published.store(reading)
        if !forcingFrame, let previous, previous.level == reading.level,
            previous.pressure == reading.pressure, let lastFrameAt,
            now.timeIntervalSince(lastFrameAt) < Self.quietFrameInterval
        {
            return
        }
        lastFrameAt = now
        await onRefresh()
    }
}
