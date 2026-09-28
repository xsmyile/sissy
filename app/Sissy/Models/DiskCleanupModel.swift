import Foundation
import Observation

/// The Disk tab's cleanup rows: what each cache takes, and what emptying one
/// did.
///
/// **One per open panel.** `UsagePanelController` makes one when the popover
/// opens and cancels it when the popover closes, so a size is measured at most
/// once for each time the panel is opened, never with the panel closed, and
/// never kept for a later opening: a cache a build refilled in between would be
/// offered at yesterday's size. Nothing reaches the engine, because nothing
/// here is a reading the frame carries.
///
/// **Nothing is removed without a press.** `measure()` only reads, and it
/// starts when the Disk tab first appears and runs on while the panel is
/// open, bounded by the list; `clean(_:)` is what the
/// confirmation calls, one cache at a time.
@MainActor
@Observable
final class DiskCleanupModel {
    /// What emptying a cache did, as the removal counted it entry by entry,
    /// or nil when its root could not be opened safely and nothing was
    /// touched.
    struct Outcome: Equatable {
        let report: CleanupReport?
    }

    /// What each cache would free, keyed once it has been sized; 0 for one
    /// that is not there.
    private(set) var sizes: [CleanupTarget: Int64] = [:]
    /// Whether every cache has been sized.
    private(set) var measured = false
    /// The cache being emptied, one at a time.
    private(set) var cleaning: CleanupTarget?
    private(set) var outcomes: [CleanupTarget: Outcome] = [:]

    @ObservationIgnored private let cleaner: DiskCleaner
    @ObservationIgnored private var sizingTask: Task<Void, Never>?
    @ObservationIgnored private var cleaningTask: Task<Void, Never>?

    init(cleaner: DiskCleaner = DiskCleaner()) {
        self.cleaner = cleaner
    }

    /// The caches with a row: one that takes room, or one a cleanup has just
    /// answered for, so its outcome stays under its name.
    var rows: [CleanupTarget] {
        CleanupTarget.allCases.filter { (sizes[$0] ?? 0) > 0 || outcomes[$0] != nil }
    }

    /// Sizes every cache not yet sized, in the list's order. A second call
    /// while one runs, or after all are sized, does nothing.
    func measure() {
        guard sizingTask == nil, !measured else { return }
        let cleaner = cleaner
        sizingTask = Task {
            for target in CleanupTarget.allCases where sizes[target] == nil {
                let size = await cleaner.size(of: target)
                guard !Task.isCancelled, let size else { return }
                sizes[target] = size
            }
            measured = true
            sizingTask = nil
        }
    }

    /// Empties `target` and sizes it again, so the row says what is left
    /// rather than what was assumed to go. A refused root keeps its size, since
    /// nothing under it was touched. The confirmation is the caller's: this is
    /// the call made after it.
    func clean(_ target: CleanupTarget) {
        guard cleaning == nil, (sizes[target] ?? 0) > 0 else { return }
        cleaning = target
        outcomes[target] = nil
        let cleaner = cleaner
        cleaningTask = Task {
            let report = await cleaner.clean(target)
            let remaining = report == nil ? sizes[target] : await cleaner.size(of: target)
            guard !Task.isCancelled, let remaining else { return }
            sizes[target] = remaining
            outcomes[target] = Outcome(report: report)
            cleaning = nil
            cleaningTask = nil
        }
    }

    /// Stops whatever is running, for the panel closing. A removal stops at
    /// the next entry, which leaves a cache partly emptied and nothing else.
    func cancel() {
        sizingTask?.cancel()
        sizingTask = nil
        cleaningTask?.cancel()
        cleaningTask = nil
        cleaning = nil
    }
}
