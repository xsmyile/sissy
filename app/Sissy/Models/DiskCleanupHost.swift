import Foundation
import Observation

/// The removals the Disk tab's cleanup confirmed, which outlive the panel
/// that confirmed them, and the one queue every walk over a root waits in.
///
/// **A confirmed removal runs to the end.** The panel is a transient popover,
/// so any click outside it closes it, and a removal that stopped with it left
/// a cache half emptied with no word of what happened. So the removal belongs
/// to the app's lifetime rather than the panel's: it is never cancelled, the
/// panel that opens next shows it still running or what it did, and that
/// outcome is dropped once a panel that could show it has closed.
///
/// **One walk per root, in the order asked.** A sizing a panel starts and a
/// removal already running over the same root never overlap: each walk waits
/// for the one before it on that root, which is also what makes a panel opened
/// again while the last one's walk is still unwinding wait for it rather than
/// race it. `DiskCleaner` refuses an overlapping walk on its own; this is what
/// keeps the page from ever meeting that refusal.
@MainActor
@Observable
final class DiskCleanupHost {
    /// What a removal did, and what its root takes afterwards, nil when
    /// nothing was touched.
    struct Outcome: Equatable {
        let result: Result<CleanupReport, CleanupRefusal>
        let remaining: Int64?
    }

    enum Removal: Equatable {
        case running
        case finished(Outcome)
    }

    private(set) var removals: [CleanupTarget: Removal] = [:]

    @ObservationIgnored private let cleaner: DiskCleaner
    /// The last walk asked for on each root, which the next one waits for.
    @ObservationIgnored private var walks: [CleanupTarget: Task<Void, Never>] = [:]

    init(cleaner: DiskCleaner = DiskCleaner()) {
        self.cleaner = cleaner
    }

    /// Whether a removal is running, on any root: one at a time, so a second
    /// press cannot start a second walk's worth of descriptors and I/O.
    var isRemoving: Bool { removals.values.contains(.running) }

    /// What `target` would free, after any walk already queued on it. The
    /// caller's cancellation stops the sizing, and nothing else.
    func size(of target: CleanupTarget) async -> Int64? {
        let walk = queued(on: target) { await $0.size(of: target) }
        return await withTaskCancellationHandler {
            await walk.value
        } onCancel: {
            walk.cancel()
        }
    }

    func toolAtWork(on target: CleanupTarget) async -> CleanupTool? {
        await cleaner.toolAtWork(on: target)
    }

    /// Empties `target` and sizes it again, after any walk already queued on
    /// it. Nothing cancels it.
    func remove(_ target: CleanupTarget) {
        guard !isRemoving else { return }
        removals[target] = .running
        let walk = queued(on: target) { cleaner in
            let result = await cleaner.clean(target)
            let touched = (try? result.get()) != nil
            return Outcome(result: result, remaining: touched ? await cleaner.size(of: target) : nil)
        }
        Task {
            removals[target] = .finished(await walk.value)
        }
    }

    /// The panel closed: an outcome it could show has been shown, and one still
    /// running waits for the next panel.
    func panelClosed() {
        removals = removals.filter { $0.value == .running }
    }

    private func queued<Value: Sendable>(
        on target: CleanupTarget, _ work: @escaping @Sendable (DiskCleaner) async -> Value
    ) -> Task<Value, Never> {
        let previous = walks[target]
        let cleaner = cleaner
        let walk = Task {
            await previous?.value
            return await work(cleaner)
        }
        walks[target] = Task { _ = await walk.value }
        return walk
    }
}
