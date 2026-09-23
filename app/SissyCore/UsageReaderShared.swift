import Foundation

/// Constants and helpers shared by the one tail (`LocalUsageProvider`) and
/// the per-CLI adapters that feed it. Centralized so a tuning change can't
/// silently drift between a source and the engine reading it.
enum UsageReaderShared {
    /// Streaming read chunk size for incremental JSONL ingest. Big enough to
    /// fit ~10 average assistant lines (most are 1-4 KB) so per-chunk overhead
    /// stays low, small enough that peak resident set during cold backfill is
    /// bounded well under the multi-MB spikes a read-to-end path produced.
    static let ingestChunkSize = 64 * 1024

    /// Minimum spacing between frame emits while tailing, so a burst of new
    /// lines costs one emit instead of one per line.
    static let pollEmitThrottle: TimeInterval = 0.2

    /// Slack added to a file's persisted mtime before treating the on-disk
    /// copy as changed, absorbing sub-millisecond filesystem timestamp
    /// rounding so an unchanged file isn't re-ingested on every poll.
    static let mtimeTolerance: TimeInterval = 0.0005

    /// Longest plan token accepted off a vendor payload, matching the bound
    /// Claude Code applies to its own tier tokens (`^[a-z][a-z0-9_]{0,63}$`).
    static let maxPlanTokenLength = 64

    /// Longest free-text field accepted off a vendor's own file. Past this it
    /// is not a name, and a panel row is 340 points wide.
    static let maxDisplayTextLength = 128

    /// Narrows a free-text field — an address, an organisation's name — to
    /// something a row can render.
    ///
    /// Deliberately not `sanitizedPlanToken`: these are not tokens, so the
    /// only rules are that the value is not blank and not long enough to be
    /// something other than a name. Control characters go because a row is
    /// one line, and a file Sissy does not own is where the value came from.
    static func sanitizedDisplayText(_ raw: String?) -> String? {
        guard let raw, raw.count <= maxDisplayTextLength else { return nil }
        let cleaned =
            raw
            .filter { character in
                !character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            }
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Largest per-field token count accepted off a session log.
    ///
    /// The counts are summed into a per-day total with Swift's trapping
    /// arithmetic, and the logs belong to the CLIs rather than to Sissy. A
    /// value near `Int.max` therefore crashed the process — and did so again
    /// on every relaunch, because a file's offset only advances once its
    /// whole chunk has been ingested, so the line was re-read forever. A
    /// billion is three orders of magnitude past the largest context any CLI
    /// ships, so the clamp cannot reach a real reading.
    static let maxTokenCount = 1_000_000_000

    /// Reads one token count off a decoded JSONL object, bounded so the
    /// per-day sum cannot overflow. Missing, non-numeric, or out of range
    /// reads as zero; `as? Int` already answers nil for a float, for an
    /// infinity, and for anything wider than `Int64`, so only the in-range
    /// absurdities need the clamp.
    static func tokenCount(_ raw: Any?) -> Int {
        guard let value = raw as? Int else { return 0 }
        return min(max(value, 0), maxTokenCount)
    }

    /// Narrows a vendor-supplied plan identifier to the shape both CLIs use
    /// for theirs, so an unexpected payload cannot put arbitrary text in the
    /// frame. Neither reader owns its source: Codex takes the token out of a
    /// rollout line and Claude Code out of the CLI's own config file.
    static func sanitizedPlanToken(_ raw: String?) -> String? {
        guard let raw, let first = raw.first, raw.count <= maxPlanTokenLength else { return nil }
        guard first.isASCII, first.isLowercase else { return nil }
        let allowed = raw.allSatisfy {
            $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_")
        }
        return allowed ? raw : nil
    }

    /// The files still worth tracking, given each one's last-known mtime.
    ///
    /// A file whose last write fell out of the retain window has nothing left
    /// to contribute: its events are already outside the day buckets the
    /// readers keep. Tracking it anyway costs a stat on every poll and a row
    /// in every save, and the enumerator re-admits it precisely *because* it
    /// still has an offset — so the set only ever grew for as long as the
    /// process ran. `loadAndApplyPersistedState` already drops these when it
    /// reads a snapshot; this is the same rule applied while running.
    ///
    /// A file with no recorded mtime is not retained: nothing can vouch for
    /// when it was last written, and re-reading it from zero is what the
    /// enumerator would do for it anyway.
    static func retainedFiles(mtimes: [URL: TimeInterval], cutoff: TimeInterval) -> Set<URL> {
        Set(mtimes.lazy.filter { $0.value >= cutoff }.map(\.key))
    }

    // `ISO8601DateFormatter.date(from:)` is documented thread-safe on Apple
    // platforms (only `formatOptions` mutation is not). We only ever read
    // these instances; `nonisolated(unsafe)` is the right escape hatch under
    // Swift 6 strict concurrency.
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoFormatterNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Manual parser for the `YYYY-MM-DDTHH:MM:SS[.fff]Z` shape both CLIs
    /// write to JSONL. Foundation's `ISO8601DateFormatter` allocates on
    /// every call and walks Calendar+locale, costing tens of µs per parse.
    /// Across the cold-start workload (~44k assistant lines) that alone is
    /// over a second of pure formatter overhead. This path is digit-math +
    /// `timegm`, sub-µs/line. Returns nil for any unexpected shape so the
    /// caller can fall back to the Foundation formatter, keeping forward
    /// compatibility if the upstream timestamp format ever shifts.
    static func parseISODate(_ s: String) -> Date? {
        let bytes = Array(s.utf8)
        if bytes.count < 20 { return nil }
        // Fixed-offset digit check on the date+time skeleton. Bails on the
        // first wrong separator so a slightly different shape ("+00:00"
        // timezones, etc.) falls through to the formatter path.
        guard bytes[4] == 0x2D, bytes[7] == 0x2D, bytes[10] == 0x54,
            bytes[13] == 0x3A, bytes[16] == 0x3A
        else { return nil }
        func d(_ i: Int) -> Int { Int(bytes[i] &- 0x30) }
        for idx in [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18] {
            let v = bytes[idx]
            if v < 0x30 || v > 0x39 { return nil }
        }
        let year = d(0) * 1000 + d(1) * 100 + d(2) * 10 + d(3)
        let month = d(5) * 10 + d(6)
        let day = d(8) * 10 + d(9)
        let hour = d(11) * 10 + d(12)
        let minute = d(14) * 10 + d(15)
        let second = d(17) * 10 + d(18)
        var i = 19
        var frac: Double = 0
        if i < bytes.count && bytes[i] == 0x2E {  // '.'
            i += 1
            var num = 0
            var div = 1
            var digits = 0
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
                // Nanosecond precision is enough for Date. Consume the rest
                // without accumulating unbounded integers from foreign input.
                if digits < 9 {
                    num = num * 10 + Int(bytes[i] &- 0x30)
                    div *= 10
                }
                digits += 1
                i += 1
            }
            guard digits > 0 else { return nil }
            frac = Double(num) / Double(div)
        }
        guard i == bytes.count - 1, bytes[i] == 0x5A else { return nil }  // 'Z'
        var tmStruct = tm()
        tmStruct.tm_year = Int32(year - 1900)
        tmStruct.tm_mon = Int32(month - 1)
        tmStruct.tm_mday = Int32(day)
        tmStruct.tm_hour = Int32(hour)
        tmStruct.tm_min = Int32(minute)
        tmStruct.tm_sec = Int32(second)
        let epoch = timegm(&tmStruct)
        if epoch == -1 { return nil }
        return Date(timeIntervalSince1970: TimeInterval(epoch) + frac)
    }

    /// Parses a JSON timestamp, fast path first, Foundation for the shapes it
    /// rejects by design — chiefly an offset such as `+00:00` in place of `Z`,
    /// which Anthropic's usage endpoint sends
    /// (`2026-09-10T12:20:00.061389+00:00`). Every caller needs that fallback,
    /// which is why it lives here rather than at each call site.
    static func parseTimestamp(_ text: String) -> Date? {
        parseISODate(text)
            ?? isoFormatter.date(from: text)
            ?? isoFormatterNoFrac.date(from: text)
    }

    /// `yyyy-MM-dd` day-bucket key formatter, in the zone `Calendar.current`
    /// is in when it is asked. Built once, which is also what starts
    /// `DayKeyFormatter.followSystemZone`.
    static let dayFormatter: DayKeyFormatter = {
        DayKeyFormatter.followSystemZone()
        return DayKeyFormatter()
    }()
}

/// The `yyyy-MM-dd` key a day is filed under, read in the zone in force at
/// the moment of the call.
///
/// POSIX locale and Gregorian calendar so the key is stable across locale
/// changes that would otherwise shift digit shaping. The zone is asked for on
/// every call because a menu-bar app runs for weeks: a formatter that took
/// `.current` once kept the launch zone after a flight while the tail's
/// buckets, `startOfDay` and the rollups follow `Calendar.current`, so a key
/// and the day it was computed for could name two different dates.
final class DayKeyFormatter: @unchecked Sendable {
    private static let format = "yyyy-MM-dd"
    private static let localeIdentifier = "en_US_POSIX"
    /// Held for the life of the process, which is the life of the shared
    /// formatter it serves.
    nonisolated(unsafe) private static var zoneObserver: NSObjectProtocol?
    private static let observerLock = NSLock()

    private let formatter: DateFormatter
    private let zone: @Sendable () -> TimeZone
    /// `DateFormatter` is safe to read from several threads, not to have its
    /// zone set under a reader.
    private let lock = NSLock()

    init(zone: @escaping @Sendable () -> TimeZone = { Calendar.current.timeZone }) {
        let formatter = DateFormatter()
        formatter.dateFormat = Self.format
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: Self.localeIdentifier)
        formatter.timeZone = zone()
        self.formatter = formatter
        self.zone = zone
    }

    func string(from date: Date) -> String {
        lock.withLock {
            settleZone()
            return formatter.string(from: date)
        }
    }

    func date(from string: String) -> Date? {
        lock.withLock {
            settleZone()
            return formatter.date(from: string)
        }
    }

    private func settleZone() {
        let current = zone()
        if formatter.timeZone != current { formatter.timeZone = current }
    }

    /// Drops Foundation's cached system zone whenever the system reports a
    /// new one, so `Calendar.current` and every key read after it agree on
    /// the zone the Mac is in now rather than on the one it launched in.
    static func followSystemZone() {
        observerLock.withLock {
            guard zoneObserver == nil else { return }
            zoneObserver = NotificationCenter.default.addObserver(
                forName: .NSSystemTimeZoneDidChange, object: nil, queue: nil
            ) { _ in
                NSTimeZone.resetSystemTimeZone()
            }
        }
    }
}
