import Foundation

/// The span of days the archive is filled in over, and the record of what has
/// already been filled.
///
/// Sissy's archive starts the day it first runs; the CLIs' logs go back
/// months. So the panel's wide windows read far below what the user knows they
/// spent, and a new install is at day zero forever — measured 2026-09-15, the
/// widest window read $2,103 against $4,615 of logs, 53% of it older than the
/// archive. This is the second pass that closes that gap, and it is a second
/// pass rather than a wider tail: widening the tail's window would grow its
/// ledger, its day buckets and its snapshot permanently, on every relaunch, to
/// buy a one-time catch-up.
enum ArchiveBackfill {
    /// The range one pass counts, or nil when there is nothing for it to do.
    ///
    /// It **ends where the live tail's window begins**, so the two never write
    /// the same day and no coverage check has to arbitrate between them. The
    /// tail archives the days inside its rolling window and suppresses the one
    /// that window cuts in half; that suppressed day is the newest this pass
    /// writes, which is also the only way it is ever written at all.
    ///
    /// It **begins at the retention cutoff**, computed the way
    /// `UsageHistoryStore.prune` computes it — in calendar days, not as a
    /// rolling multiple of 24 hours. A rolling bound would sit a day further
    /// back and write a day the next prune deletes, and it would cut its own
    /// oldest day in half for exactly the reason the tail's does; a calendar
    /// bound lands on a day boundary, so the oldest day it reaches is whole as
    /// far as any log goes and needs no suppression.
    static func window(
        retentionDays: Int,
        liveRetainDays: Int = LocalUsageProvider.defaultRetainDays,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Range<Date>? {
        guard retentionDays > 0, liveRetainDays > 0 else { return nil }
        let today = calendar.startOfDay(for: now)
        guard
            let start = calendar.date(byAdding: .day, value: -(retentionDays - 1), to: today),
            let end = calendar.date(byAdding: .day, value: -(liveRetainDays - 1), to: today),
            start < end
        else { return nil }
        return start..<end
    }
}

/// What a backfill pass has already covered, per provider.
///
/// Its own file, deliberately neither inside `history/` nor in `server.json`.
/// Not inside `history/`, because deleting the archive is a user asking Sissy
/// to forget and a marker that went with it would have the next launch
/// re-deriving what was just deleted. Not in `server.json`, because a pass
/// finishes on a detached task and a config write from there races the ones
/// the settings make — last writer wins, and one of the two changes is lost.
///
/// The recorded value is the oldest day the pass covered rather than when it
/// ran, so widening `historyRetentionDays` asks for the days that are now in
/// range while narrowing it asks for nothing. A provider with no entry has
/// never been passed over, which is what makes switching a CLI on months later
/// fill its own history in.
struct ArchiveBackfillLedger: Codable, Equatable, Sendable {
    /// Bump only when the meaning of an entry changes. A file this build
    /// cannot read is answered as "nothing covered", which costs one pass.
    static let currentSchemaVersion = 1
    static let fileName = "history-backfill.json"

    var schemaVersion: Int = Self.currentSchemaVersion
    /// Provider id → the oldest day its last pass covered, `YYYY-MM-DD` in the
    /// local calendar, the same bucketing the archive keeps.
    var coveredFrom: [String: String] = [:]

    static func defaultURL(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// Whether `provider` still owes a pass over a window starting at `start`.
    ///
    /// True when nothing is recorded, and when what is recorded begins later
    /// than the window asked for. A day that has merely rolled over moves the
    /// window's start *forward*, so an install that has been passed over once
    /// is never asked again.
    func isDue(provider: String, coveringFrom start: Date, calendar: Calendar = .current) -> Bool {
        guard let recorded = coveredFrom[provider],
            let day = UsageReaderShared.dayFormatter.date(from: recorded)
        else { return true }
        return calendar.startOfDay(for: day) > calendar.startOfDay(for: start)
    }

    /// This ledger with one provider's coverage recorded.
    func recording(provider: String, coveredFrom start: Date) -> Self {
        var updated = self
        updated.coveredFrom[provider] = UsageReaderShared.dayFormatter.string(from: start)
        return updated
    }

    /// The ledger on disk, or an empty one. A file that will not decode is
    /// answered as empty rather than quarantined: it holds no reading, and the
    /// worst an unreadable one costs is a pass that runs a second time and
    /// rewrites the same days.
    static func load(from url: URL) -> Self {
        guard let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(Self.self, from: data),
            decoded.schemaVersion == currentSchemaVersion
        else { return Self() }
        return decoded
    }

    static func save(_ ledger: Self, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(ledger).write(to: url, options: [.atomic])
    }
}
