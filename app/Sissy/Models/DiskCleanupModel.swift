import Foundation
import Observation

/// The Disk tab's cleanup rows for one showing of the panel: what each cache
/// takes, and the question a `Clean…` press asks.
///
/// **One per open panel, and only the reading is.** `UsagePanelController`
/// makes one when the popover opens and cancels it when the popover closes,
/// so a size is measured at most once for each time the panel is opened, never
/// with the panel closed, and never kept for a later opening: a cache a build
/// refilled in between would be offered at yesterday's size. A removal the
/// panel confirmed is not this model's: it belongs to `DiskCleanupHost`, runs
/// to the end whether the panel stays open or not, and this model only shows
/// it.
///
/// **Nothing is removed without a press.** `measure()` only reads, and it
/// starts when the Disk tab first appears and runs on while the panel is open,
/// bounded by the list. `propose(_:)` asks whether the tool is at work and sizes
/// the cache again, so the confirmation names what will go now rather than what
/// the cache took when the panel opened; `confirm()` is the removal.
@MainActor
@Observable
final class DiskCleanupModel {
    /// The question on screen: which cache, and what it takes this moment.
    struct Confirmation: Equatable {
        let target: CleanupTarget
        let bytes: Int64
    }

    /// What each cache would free, keyed once it has been sized; 0 for one
    /// that is not there.
    private(set) var sizes: [CleanupTarget: Int64] = [:]
    /// Whether every cache has been sized.
    private(set) var measured = false
    /// The cache a press is being checked and sized for.
    private(set) var preparing: CleanupTarget?
    private(set) var confirmation: Confirmation?
    /// The tool found at work on a cache the user asked to clean.
    private(set) var atWork: [CleanupTarget: CleanupTool] = [:]

    let host: DiskCleanupHost
    @ObservationIgnored private var sizingTask: Task<Void, Never>?
    @ObservationIgnored private var preparingTask: Task<Void, Never>?

    init(host: DiskCleanupHost) {
        self.host = host
    }

    /// The caches with a row: one that takes room, one whose removal is
    /// running or has just answered, or one whose tool was found at work.
    var rows: [CleanupTarget] {
        CleanupTarget.allCases.filter {
            size(of: $0) > 0 || host.removals[$0] != nil || atWork[$0] != nil
        }
    }

    /// What the row shows: the size a finished removal left, or the size this
    /// panel measured.
    func size(of target: CleanupTarget) -> Int64 {
        if case .finished(let outcome) = host.removals[target], let remaining = outcome.remaining {
            return remaining
        }
        return sizes[target] ?? 0
    }

    /// Whether a row may offer its `Clean…`: nothing else is being asked or
    /// removed, and the cache takes room.
    func canOffer(_ target: CleanupTarget) -> Bool {
        preparing == nil && confirmation == nil && !host.isRemoving && size(of: target) > 0
    }

    /// Sizes every cache not yet sized, in the list's order, leaving one a
    /// removal is emptying to that removal's own figure. A second call while
    /// one runs, or after all are sized, does nothing.
    func measure() {
        guard sizingTask == nil, !measured else { return }
        let host = host
        sizingTask = Task {
            for target in CleanupTarget.allCases where sizes[target] == nil {
                guard host.removals[target] != .running else { continue }
                let size = await host.size(of: target)
                guard !Task.isCancelled, let size else { return }
                sizes[target] = size
            }
            measured = true
            sizingTask = nil
        }
    }

    /// A press on `Clean…`: says so on the row if the cache's tool is at work,
    /// and otherwise sizes the cache again and asks.
    func propose(_ target: CleanupTarget) {
        guard canOffer(target) else { return }
        preparing = target
        atWork[target] = nil
        let host = host
        preparingTask = Task {
            let tool = await host.toolAtWork(on: target)
            guard !Task.isCancelled else { return }
            if let tool {
                atWork[target] = tool
                preparing = nil
                return
            }
            let bytes = await host.size(of: target)
            guard !Task.isCancelled, let bytes else { return }
            sizes[target] = bytes
            preparing = nil
            if bytes > 0 { confirmation = Confirmation(target: target, bytes: bytes) }
        }
    }

    func dismissConfirmation() {
        confirmation = nil
    }

    /// The answer to the question: the removal, handed to the host.
    func confirm() {
        guard let confirmation else { return }
        self.confirmation = nil
        host.remove(confirmation.target)
    }

    /// Stops the reading, for the panel closing. A removal already confirmed
    /// is the host's and goes on.
    func cancel() {
        sizingTask?.cancel()
        sizingTask = nil
        preparingTask?.cancel()
        preparingTask = nil
        preparing = nil
        confirmation = nil
        host.panelClosed()
    }
}
