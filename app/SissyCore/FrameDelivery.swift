import Foundation

/// Hands the engine's frames to the app, newest reading last.
///
/// The engine is reentrant and a rebuild suspends between taking its reading
/// and handing its frame over, in the keep-awake hold among other places, so
/// two rebuilds in flight can finish in either order; every monitor's
/// `reemit` makes that ordinary rather than rare. A frame whose reading is
/// older than one already handed over is refused as `overtaken`, since its
/// totals and signals are older than the frame on screen.
///
/// One loop hands frames over, one at a time: `send` hops off the engine, so
/// two calls made in order could otherwise reach the app out of it. A frame
/// that arrives while one is being handed over replaces any other still
/// waiting, so a slow consumer is sent the newest frame rather than a
/// backlog, and a caller returns once its frame or a newer one is in.
/// `stop()` drops what is waiting and returns once a frame already being
/// handed over is in, so nothing reaches the app after it: an engine torn
/// down for a provider switch cannot land a frame after its replacement's.
///
/// **`send` must not await the engine.** A caller waits for the loop, so a
/// `send` that waited on an engine call which rebuilt a frame would wait on
/// the loop it is running inside.
actor FrameDelivery<Frame: Sendable> {
    /// What became of one frame handed in.
    enum Outcome: Sendable, Equatable {
        /// Handed over, or replaced by a newer frame that was.
        case delivered
        /// Built from a reading older than one already handed over.
        case overtaken
        /// Arrived after `stop()`, or was still waiting when it ran.
        case stopped
    }

    private let send: @Sendable (Frame) async -> Void
    private var deliveredRevision = 0
    private var pending: Frame?
    private var drain: Task<Void, Never>?
    private var isStopped = false

    init(send: @escaping @Sendable (Frame) async -> Void) {
        self.send = send
    }

    /// Hands `frame` over, or refuses it; `revision` is the reading's, in the
    /// order readings were taken.
    ///
    /// The same revision is admitted, so two frames built from one reading
    /// both go out in the order they arrived here.
    func deliver(_ frame: Frame, revision: Int) async -> Outcome {
        guard !isStopped else { return .stopped }
        guard revision >= deliveredRevision else { return .overtaken }
        deliveredRevision = revision
        pending = frame
        let loop = drain ?? Task { await drainPending() }
        drain = loop
        await loop.value
        return isStopped ? .stopped : .delivered
    }

    /// The frame waiting behind the one being handed over, if any. Internal
    /// so a test can hold a slow consumer and watch what queues behind it.
    var waiting: Frame? { pending }

    /// Drops what is waiting, refuses everything after it, and waits for a
    /// frame already being handed over. Terminal.
    func stop() async {
        isStopped = true
        pending = nil
        await drain?.value
    }

    private func drainPending() async {
        while !isStopped, let next = pending {
            pending = nil
            await send(next)
        }
        pending = nil
        drain = nil
    }
}
