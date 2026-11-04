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
    /// **What a pass left unfinished answers past the tail's reach.** It has no
    /// record, and the tail's snapshot moves on regardless, so without this the
    /// next launch read the tail's reach past the window's end and nothing went
    /// back: a log it could not read was lost for good, and so was a pass cut
    /// short by a quit. `pending` is a pass that never finished, read again from
    /// where it started. `owed` is one that finished short of logs it could not
    /// read, read again once `canRead` says one of them reads or has gone.
    ///
    /// **Until then the owed span counts as covered**, so a log that stays
    /// unreadable costs one `access` per path at each launch rather than a pass,
    /// and a day's new gap costs a pass over that gap and no further back.
    static func uncovered(
        _ window: Range<Date>,
        coverage: ArchiveBackfillLedger.Coverage?,
        owed: ArchiveBackfillLedger.OwedSpan? = nil,
        pending: ArchiveBackfillLedger.Coverage? = nil,
        meteredThrough: Date?,
        calendar: Calendar = .current,
        canRead: (String) -> Bool = canReadNow
    ) -> Range<Date>? {
        let blockedSpan = owed.flatMap { $0.isBlocked(canRead: canRead) ? $0.span : nil }
        let gap = narrowed(
            window, coverage: blockedSpan?.merging(coverage) ?? coverage,
            meteredThrough: meteredThrough, calendar: calendar)
        let unfinished = [pending, blockedSpan == nil ? owed?.span : nil]
            .compactMap { $0?.fromDay }
            .map { max(window.lowerBound, calendar.startOfDay(for: $0)) }
        guard let start = (unfinished + [gap?.lowerBound].compactMap { $0 }).min(),
            start < window.upperBound
        else { return nil }
        return start..<window.upperBound
    }

    /// Whether a log a pass could not read might answer now. One that has gone
    /// has no lines left to wait for. Told from `errno` because `FileManager`
    /// also calls a file gone when a directory above it refuses to be searched,
    /// which would run the pass on every launch. The same two answers count as
    /// gone in `LocalUsageProvider.saysGone`, so the read and this agree.
    ///
    /// A log that passes this and fails at the read, a disk error being the
    /// case left, stays unread without ever blocking, and costs a pass each
    /// launch.
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

/// What a write to the archive has to respect from the user's last deletion.
enum ArchiveDeletion: Equatable, Sendable {
    /// The archive has not been deleted, or the record does not decode: writes
    /// are atomic, so that is not a state Sissy leaves behind, and refusing on it
    /// would freeze the archive for good.
    case none
    /// The record names the last day the user deleted.
    case through(String)
    /// The read itself failed, which says nothing about what the file holds.
    case unreadable

    /// Whether `day` may not be written now. A failed read refuses every past
    /// day, because any of them may be one the user deleted, and the next read
    /// can still answer. `YYYY-MM-DD` orders as the days do.
    ///
    /// Today is never refused, whatever the record names: a deletion made in Tokyo
    /// records a date that is still today in Honolulu, and refusing it would lose
    /// the live events of a day nobody deleted.
    func refuses(_ day: String, today: String) -> Bool {
        guard day < today else { return false }
        switch self {
        case .none: return false
        case .through(let last): return day <= last
        case .unreadable: return true
        }
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

    /// A span a pass finished short of logs it could not read.
    struct OwedSpan: Codable, Equatable, Sendable {
        var span: Coverage
        /// The paths the passes over it could not read. Sissy's own file,
        /// holding what the logs are called and nothing that is in them.
        var unread: [String]

        /// Whether another pass would only meet the same logs again.
        func isBlocked(canRead: (String) -> Bool) -> Bool {
            !unread.contains(where: canRead)
        }
    }

    var schemaVersion: Int = Self.currentSchemaVersion
    var coverage: [String: Coverage] = [:]
    /// What each provider's passes finished short of.
    var owed: [String: OwedSpan] = [:]
    /// The span each provider's pass is reading, written before it reads a byte
    /// so that a quit or a crash in it is asked for again.
    var pending: [String: Coverage] = [:]
    /// The last day the user deleted, nil until they have.
    ///
    /// Here rather than in anything a provider holds, because neither a snapshot
    /// nor what a reader has in memory can say a day was deleted: a snapshot can
    /// be quarantined, a straggler gives a deleted day rows again, a day that was
    /// only counted has no totals, and a backfill pass starts from nothing.
    /// `DayArchiveWriter` refuses a day at or before this one, whoever asks.
    ///
    /// It survives a `currentSchemaVersion` bump, which answers everything else
    /// in the file as nothing covered: that costs a pass, and the pass would
    /// otherwise read the deleted days back. See `deletion(at:)`.
    var deletedThrough: String?

    static func defaultURL(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// This record with one provider's span written down. A later pass that
    /// covered a narrower span still extends what is known: the two are
    /// merged, never replaced, or a relaunch's one-day top-up would throw away
    /// the months the first pass indexed. It settles the pass that was pending,
    /// and an owed span stays: a pass over a new gap beside it did not read it.
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
        updated.pending[provider] = nil
        return updated
    }

    private static func days(of span: Range<Date>) -> Coverage {
        let formatter = UsageReaderShared.dayFormatter
        return Coverage(
            from: formatter.string(from: span.lowerBound),
            through: formatter.string(from: span.upperBound))
    }

    /// This record with a pass over `span` finished short of `unread`, on top of
    /// whatever the provider owed already.
    func owing(provider: String, span: Range<Date>, unread: [String]) -> Self {
        let existing = owed[provider]
        var updated = self
        updated.owed[provider] = OwedSpan(
            span: Self.days(of: span).merging(existing?.span),
            unread: Array(Set(unread + (existing?.unread ?? []))).sorted())
        updated.pending[provider] = nil
        return updated
    }

    /// This record with a pass over `span` under way. One reaching back across
    /// what the provider owed takes that over, because it reads what that did;
    /// one over a new gap beside a blocked span leaves it owed.
    func starting(
        provider: String, span: Range<Date>, window: Range<Date>, calendar: Calendar = .current
    ) -> Self {
        var updated = self
        updated.pending[provider] = Self.days(of: span)
        if let from = owed[provider]?.span.fromDay,
            span.lowerBound <= max(window.lowerBound, calendar.startOfDay(for: from))
        {
            updated.owed[provider] = nil
        }
        return updated
    }

    /// Writes down the passes about to start, ahead of the first byte they read.
    static func note(
        passes: [(provider: String, span: Range<Date>)], within window: Range<Date>,
        startingAt url: URL
    ) {
        update(at: url) {
            passes.reduce($0) {
                $0.starting(provider: $1.provider, span: $1.span, window: window)
            }
        }
    }

    /// Writes down that the archive was deleted: `providers` are covered across
    /// `window`, and nothing anyone owed is owed any more, or the next pass
    /// would read back the days the user just asked Sissy to forget, and every
    /// day before today is gone for good.
    ///
    /// Written over a file that would not read, unlike `update(at:_:)`. What that
    /// loses costs a pass, and the pass is refused by what this writes. Answers
    /// whether it reached the disk, because a deletion without its date can come
    /// back, and the disk may only have room once the archive is gone.
    @discardableResult
    static func noteDeletion(
        covering providers: [String], window: Range<Date>?, at url: URL, now: Date = Date()
    ) -> Bool {
        var updated = load(from: url)
        let calendar = Calendar.current
        if let yesterday = calendar.date(
            byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        {
            updated.deletedThrough = max(
                updated.deletedThrough ?? "", UsageReaderShared.dayFormatter.string(from: yesterday))
        }
        if let window {
            updated = providers.reduce(updated) { $0.recording(provider: $1, covered: window) }
        }
        updated.owed = [:]
        updated.pending = [:]
        return saving(updated, to: url)
    }

    /// Losing either write costs one repeat of a pass, which is why it is logged
    /// rather than propagated.
    @discardableResult
    private static func saving(_ ledger: Self, to url: URL) -> Bool {
        do {
            try save(ledger, to: url)
            return true
        } catch {
            sissyLog("sissy: could not write the archive backfill record: \(error)")
            return false
        }
    }

    /// Changes the record on disk, unless it would not read: answered as empty
    /// and saved, that would lose `deletedThrough`, and the days it names would
    /// come back.
    ///
    /// One read for both answers: a failure on a second read would come back as an
    /// empty record with no date, past a check the first read had already passed.
    static func update(at url: URL, _ change: (Self) -> Self) {
        let reading = read(url)
        guard reading.deletion != .unreadable else {
            sissyLog("sissy: left the archive backfill record unwritten, it would not read")
            return
        }
        saving(change(reading.ledger), to: url)
    }

    /// The record on disk, or an empty one that keeps `deletedThrough`. A file
    /// that will not decode is answered as empty rather than quarantined: it
    /// holds no reading, and the worst an unreadable one costs is a pass that
    /// runs again and rewrites the days the deletion does not cover.
    static func load(from url: URL) -> Self {
        read(url).ledger
    }

    /// What the record says about the last deletion, read past any schema so a
    /// bump cannot take it away.
    static func deletion(at url: URL) -> ArchiveDeletion {
        read(url).deletion
    }

    private struct DeletionRecord: Codable {
        var deletedThrough: String?
    }

    /// The file read once, and everything it answers.
    private static func read(_ url: URL) -> (ledger: Self, deletion: ArchiveDeletion) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return (Self(), .none)
        } catch {
            return (Self(), .unreadable)
        }
        let decoder = JSONDecoder()
        let deleted = (try? decoder.decode(DeletionRecord.self, from: data))?.deletedThrough
        var ledger = Self()
        if let decoded = try? decoder.decode(Self.self, from: data),
            decoded.schemaVersion == currentSchemaVersion
        {
            ledger = decoded
        }
        ledger.deletedThrough = deleted
        return (ledger, deleted.map(ArchiveDeletion.through) ?? .none)
    }

    static func save(_ ledger: Self, to url: URL) throws {
        try file(url).save(ledger)
    }

    private static func file(_ url: URL) -> VersionedJSONFile<Self> {
        VersionedJSONFile(url: url, policy: .replace)
    }
}

extension ArchiveBackfillLedger {
    /// By hand for three keys: a record written before them still decodes, because
    /// they add nothing the days already covered lack, so they earn no
    /// `currentSchemaVersion` bump and no pass over the whole window on every
    /// install.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        coverage = try container.decode([String: Coverage].self, forKey: .coverage)
        owed = try container.decodeIfPresent([String: OwedSpan].self, forKey: .owed) ?? [:]
        pending = try container.decodeIfPresent([String: Coverage].self, forKey: .pending) ?? [:]
        deletedThrough = try container.decodeIfPresent(String.self, forKey: .deletedThrough)
    }
}
