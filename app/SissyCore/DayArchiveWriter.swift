import Foundation

/// Writes one day of a `DayBook` to a provider's archive, whole, and only over
/// what it knows at least as much as.
struct DayArchiveWriter {
    /// What became of a day the book was asked to write.
    enum Outcome {
        case written
        /// Nothing was written and asking again will not change that.
        case left
        /// The write failed. The caller keeps the day dirty and retries it.
        case failed
    }

    let provider: String
    let root: URL
    let projects: ProjectResolver

    /// Writes `day`, merged with what its file holds beside the rows.
    ///
    /// A day can be counted without being billed: Codex writes a rollout's
    /// `session_meta` when it opens, so a session somebody started and never
    /// asked anything is one session and no tokens. Skipped on the token rows
    /// alone, such a day left the dirty set here and was never retried, so its
    /// count aged out unwritten.
    ///
    /// A day the archive refuses to rewrite is logged, because it is otherwise
    /// indistinguishable from one it had nothing new to say about, and a field
    /// added beside the rows reaches none of the days stuck there. A failed save
    /// is logged because an archive that silently stops growing is
    /// indistinguishable from a quiet week.
    func write(_ day: Date, from book: DayBook, now: Date) -> Outcome {
        let totals = book.rows[day] ?? [:]
        let counts = book.counts[day] ?? .none
        let activity = book.activity[day] ?? .none
        let effort = book.effort[day] ?? [:]
        guard !totals.isEmpty || !counts.isEmpty || !activity.isEmpty || !effort.isEmpty
        else { return .left }
        var record = UsageHistoryDay(
            day: UsageReaderShared.dayFormatter.string(from: day),
            provider: provider,
            updatedAt: now,
            totals: totals,
            agents: counts,
            activity: activity,
            effort: effort
        )
        switch UsageHistoryStore.stored(provider: provider, day: record.day, in: root) {
        case .unreadable:
            return .left
        case .day(let onDisk)
        where !onDisk.reattributed(by: { projects.project(for: $0) }).isCoveredBy(record):
            sissyLog(
                "sissy: \(provider) left \(record.day) as it stands — this reading knows less "
                    + "about it than the file does (\(record.totalTokens) tokens against "
                    + "\(onDisk.totalTokens))")
            return .left
        case .day(let onDisk):
            record = record.merging(
                counts: onDisk.agents, activity: onDisk.activity, effort: onDisk.effort)
        case .absent:
            break
        }
        do {
            try UsageHistoryStore.save(record, in: root)
            return .written
        } catch {
            sissyLog(
                "sissy: \(provider) history save failed for \(record.day) at "
                    + "\(root.path): \(error)")
            return .failed
        }
    }
}
