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
        let liveStart = LocalUsageProvider.liveWindowStart(retainDays: liveRetainDays, now: now)
        guard
            let start = UsagePeriod.start(days: retentionDays, now: now, calendar: calendar),
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
    ///
    /// **`owed` answers past the tail's reach.** A span a pass started on and
    /// never finished has no record, and the tail's snapshot moves on regardless,
    /// so without this the next launch read the tail's reach past the window's
    /// end and nothing went back for it: a log it could not read was lost for
    /// good, and so was a pass cut short by a quit. One a log is still blocking
    /// is treated as covered, so a log that stays unreadable costs a stat at
    /// each launch rather than a pass over the whole span: it runs again once
    /// `canRead` says one of those logs can be read or has gone, or beside a new
    /// gap.
    static func uncovered(
        _ window: Range<Date>,
        coverage: ArchiveBackfillLedger.Coverage?,
        owed: ArchiveBackfillLedger.OwedSpan? = nil,
        meteredThrough: Date?,
        calendar: Calendar = .current,
        canRead: (String) -> Bool = canReadNow
    ) -> Range<Date>? {
        guard let owed, let owedFrom = owed.span.fromDay else {
            return narrowed(window, coverage: coverage, meteredThrough: meteredThrough, calendar: calendar)
        }
        let blocked = owed.isBlocked(canRead: canRead)
        let gap = narrowed(
            window, coverage: blocked ? owed.span.merging(coverage) : coverage,
            meteredThrough: meteredThrough, calendar: calendar)
        if blocked && gap == nil { return nil }
        let start = max(window.lowerBound, calendar.startOfDay(for: owedFrom))
        guard start < window.upperBound else { return gap }
        return min(gap?.lowerBound ?? start, start)..<window.upperBound
    }

    /// Whether a log a pass could not read might answer now. One that has gone
    /// has no lines left to wait for. Told from `errno` because `FileManager`
    /// also calls a file gone when a directory above it refuses to be searched,
    /// which would run the pass on every launch.
    static func canReadNow(_ path: String) -> Bool {
        access(path, R_OK) == 0 || errno == ENOENT || errno == ENOTDIR
    }

    private static func narrowed(
        _ window: Range<Date>,
        coverage: ArchiveBackfillLedger.Coverage?,
        meteredThrough: Date?,
        calendar: Calendar
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
    ///
    /// `3` is `AgentActivityDay`, on identical grounds: the archive's own days
    /// are where every window wider than today reads its worked time, so
    /// without a re-run the page would answer for the day it shipped and say
    /// nothing about the month behind it. The merge is a union of minute
    /// bitmaps, which like the counts can only ever fill in.
    ///
    /// `4` is the effort split, on the same grounds again: the words are on
    /// lines the CLIs wrote months ago and the archive's days are the only
    /// place a window wider than today can read them from. Measured
    /// 2026-09-22, the record on this machine claimed 2026-06-22 through
    /// 2026-09-18 covered, so without the bump every one of those days would
    /// keep its tokens and never name an effort. The merge takes whichever
    /// reading counted more turns for a pair, whole, so a second pass can only
    /// fill in.
    ///
    /// `5` is the longest turn, for the same reason: both CLIs have timed
    /// every turn for months on a line nothing read, and the merge takes the
    /// longer of the two readings, so a second pass can only fill in.
    static let currentSchemaVersion = 5
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

        /// Both spans as one. `YYYY-MM-DD` orders as the days do.
        func merging(_ other: Self?) -> Self {
            guard let other else { return self }
            return Self(from: min(from, other.from), through: max(through, other.through))
        }
    }

    /// A span a pass started on and has not answered for, written before it
    /// reads a byte so a quit or a crash in it owes the span too.
    struct OwedSpan: Codable, Equatable, Sendable {
        var span: Coverage
        /// The paths the last pass could not read, and empty while none has
        /// finished. Sissy's own file, holding what the logs are called and
        /// nothing that is in them.
        var unread: [String]

        /// Whether another pass would only meet the same logs again.
        func isBlocked(canRead: (String) -> Bool) -> Bool {
            !unread.isEmpty && !unread.contains(where: canRead)
        }
    }

    var schemaVersion: Int = Self.currentSchemaVersion
    var coverage: [String: Coverage] = [:]
    /// What each provider's passes have started on and not answered for.
    var owed: [String: OwedSpan] = [:]

    static func defaultURL(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// This record with one provider's span written down. A later pass that
    /// covered a narrower span still extends what is known: the two are
    /// merged, never replaced, or a relaunch's one-day top-up would throw away
    /// the months the first pass indexed. It settles what the provider owed:
    /// `uncovered` makes every pass while a span is owed read across that span.
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
        updated.owed[provider] = nil
        return updated
    }

    /// This record with `span` owed by one provider, on top of whatever it owed
    /// already, and `unread` as what stands in the way of it now.
    func owing(provider: String, span: Range<Date>, unread: [String] = []) -> Self {
        let formatter = UsageReaderShared.dayFormatter
        let started = Coverage(
            from: formatter.string(from: span.lowerBound),
            through: formatter.string(from: span.upperBound))
        var updated = self
        updated.owed[provider] = OwedSpan(span: started.merging(owed[provider]?.span), unread: unread)
        return updated
    }

    /// Writes down the passes about to start, ahead of the first byte they read.
    static func note(
        passes: [(provider: String, span: Range<Date>)], startingAt url: URL
    ) {
        let updated = passes.reduce(load(from: url)) {
            $0.owing(provider: $1.provider, span: $1.span)
        }
        do {
            try save(updated, to: url)
        } catch {
            sissyLog("sissy: could not note the archive backfills about to start: \(error)")
        }
    }

    /// The record on disk, or an empty one. A file that will not decode is
    /// answered as empty rather than quarantined: it holds no reading, and the
    /// worst an unreadable one costs is a pass that runs again and rewrites
    /// the same days.
    static func load(from url: URL) -> Self {
        (try? file(url).load()) ?? Self()
    }

    static func save(_ ledger: Self, to url: URL) throws {
        try file(url).save(ledger)
    }

    private static func file(_ url: URL) -> VersionedJSONFile<Self> {
        VersionedJSONFile(
            url: url, policy: .replace, schema: (currentSchemaVersion, \.schemaVersion))
    }
}

extension ArchiveBackfillLedger {
    /// By hand for one key: a record written before `owed` still decodes, because
    /// that field adds nothing the days already covered lack, so it earns no
    /// `currentSchemaVersion` bump and no pass over the whole window on every
    /// install.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        coverage = try container.decode([String: Coverage].self, forKey: .coverage)
        owed = try container.decodeIfPresent([String: OwedSpan].self, forKey: .owed) ?? [:]
    }
}
