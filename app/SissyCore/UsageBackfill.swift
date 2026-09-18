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
    /// The whole span the archive is meant to cover, or nil when there is
    /// nothing for a pass to do.
    ///
    /// It **ends where the live tail's window begins**, so the two never write
    /// the same day and no coverage check has to arbitrate between them. The
    /// tail archives the days inside its rolling window and suppresses the one
    /// that window cuts in half; that suppressed day is the newest a pass
    /// writes, which is also the only way it is ever written at all. The end
    /// is derived from `LocalUsageProvider.liveWindowStart` rather than
    /// recomputed, because a rolling subtraction and calendar arithmetic
    /// disagree about which day they land in across a daylight-saving
    /// boundary.
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
        let liveStart = LocalUsageProvider.liveWindowStart(retainDays: liveRetainDays, now: now)
        guard
            let start = calendar.date(byAdding: .day, value: -(retentionDays - 1), to: today),
            let end = calendar.date(
                byAdding: .day, value: 1, to: calendar.startOfDay(for: liveStart)),
            start < end
        else { return nil }
        return start..<end
    }

    /// The part of `window` no one has answered for yet, or nil when the
    /// archive is already complete across it.
    ///
    /// This is what makes a pass repeatable without making it repetitive. The
    /// archive over a span is complete if a pass covered it **or** the tail was
    /// running across it, so the next pass starts at the later of the two and
    /// reads only the files that can carry those days — which on an install
    /// that has merely been relaunched is none of them.
    ///
    /// Narrowing rather than suppressing is the whole correction. Asking only
    /// "has a pass run" left the feature working exactly once: a Mac shut for a
    /// fortnight came back with a fortnight the tail's 48 h could not reach and
    /// a record saying the window had been covered, so nothing ever went back
    /// for it and the gap the feature exists to close reopened silently.
    ///
    /// A `coverage` that begins later than the window does is answered with the
    /// whole window: retention has been widened, and the days it just admitted
    /// are older than anything the record speaks for.
    static func uncovered(
        _ window: Range<Date>,
        coverage: ArchiveBackfillLedger.Coverage?,
        meteredThrough: Date?,
        calendar: Calendar = .current
    ) -> Range<Date>? {
        guard let coverage,
            let from = coverage.fromDay,
            let through = coverage.throughDay,
            calendar.startOfDay(for: from) <= calendar.startOfDay(for: window.lowerBound)
        else { return window }
        var start: Date = calendar.startOfDay(for: through)
        if let meteredThrough {
            let tailReach: Date = calendar.startOfDay(for: meteredThrough)
            if tailReach > start { start = tailReach }
        }
        guard start < window.upperBound else { return nil }
        return start..<window.upperBound
    }

    /// When the tail for this provider last wrote its snapshot, which is when
    /// it was last metering.
    ///
    /// The file's own mtime rather than the `savedAt` inside it: the snapshot
    /// is rewritten on every flush, so the two say the same thing, and one is
    /// a stat where the other is a parse of a file measured at 645 KB on a
    /// real install. A snapshot that is missing or unreadable answers nil,
    /// which leaves the record from the last pass to speak alone.
    static func lastMetered(snapshotAt url: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }
}

/// What the archive is already answered for, per provider.
///
/// Its own file, deliberately neither inside `history/` nor in `server.json`.
/// Not inside `history/`, because deleting the archive is a user asking Sissy
/// to forget and a record that went with it would have the next launch
/// re-deriving what was just deleted. Not in `server.json`, because a pass
/// finishes on a detached task and a config write from there races the ones
/// the settings make — last writer wins, and one of the two changes is lost.
///
/// The record is the span a pass covered rather than when it ran, so widening
/// `historyRetentionDays` asks for the days that are now in range while
/// narrowing it asks for nothing. A provider with no entry has never been
/// passed over, which is what makes switching a CLI on months later fill its
/// own history in.
struct ArchiveBackfillLedger: Codable, Equatable, Sendable {
    /// Bump when the meaning of an entry changes, **or when a pass starts
    /// writing something the days it already covered do not carry**. A file
    /// this build cannot read is answered as "nothing covered", which costs
    /// one pass and is the only way a day already inside the covered span is
    /// ever revisited.
    ///
    /// `2` is the session and agent counts. Without the bump the record on an
    /// existing install says the whole window is covered, so every day before
    /// the upgrade keeps its tokens and never gets a count — measured
    /// 2026-09-18, 40 of 42 archived days. The re-run is safe by construction:
    /// `isCoveredBy` still refuses a day whose tokens came back short, and
    /// `UsageHistoryDay.merging(counts:)` keeps whichever reading counted
    /// more, so a second pass can only fill the counts in.
    static let currentSchemaVersion = 2
    static let fileName = "history-backfill.json"

    /// The span one provider's last pass covered, as `YYYY-MM-DD` in the local
    /// calendar — the same bucketing the archive keeps.
    ///
    /// Both ends, because either alone is a hole. The start alone cannot tell
    /// a day that has merely rolled over from a Mac that was off for a
    /// fortnight; the end alone cannot tell that retention has been widened
    /// underneath it.
    struct Coverage: Codable, Equatable, Sendable {
        var from: String
        var through: String

        var fromDay: Date? { UsageReaderShared.dayFormatter.date(from: from) }
        var throughDay: Date? { UsageReaderShared.dayFormatter.date(from: through) }
    }

    var schemaVersion: Int = Self.currentSchemaVersion
    var coverage: [String: Coverage] = [:]

    static func defaultURL(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// This record with one provider's span written down. A later pass that
    /// covered a narrower span still extends what is known: the two are
    /// merged, never replaced, or a relaunch's one-day top-up would throw away
    /// the months the first pass indexed.
    func recording(provider: String, covered span: Range<Date>) -> Self {
        let formatter = UsageReaderShared.dayFormatter
        var from: Date = span.lowerBound
        var through: Date = span.upperBound
        if let existing = coverage[provider] {
            if let existingFrom = existing.fromDay, existingFrom < from { from = existingFrom }
            if let existingThrough = existing.throughDay, existingThrough > through {
                through = existingThrough
            }
        }
        var updated = self
        updated.coverage[provider] = Coverage(
            from: formatter.string(from: from), through: formatter.string(from: through))
        return updated
    }

    /// The record on disk, or an empty one. A file that will not decode is
    /// answered as empty rather than quarantined: it holds no reading, and the
    /// worst an unreadable one costs is a pass that runs again and rewrites
    /// the same days.
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
