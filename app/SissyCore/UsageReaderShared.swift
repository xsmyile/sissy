import Foundation
import Synchronization

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

    /// Whether `pattern` occurs in `buf[from..<to]`, through libc's `memmem`
    /// rather than a byte loop.
    ///
    /// The one substring scan a reader's prefilter should use: it runs on
    /// every line of every file a cold scan reads, and `memmem` compares a
    /// word at a time where the loops it replaces compared a byte.
    static func bufferContains(
        _ buf: UnsafePointer<UInt8>, from: Int, to: Int, pattern: [UInt8]
    ) -> Bool {
        guard !pattern.isEmpty else { return true }
        guard to - from >= pattern.count else { return false }
        return pattern.withUnsafeBytes { needle in
            memmem(buf + from, to - from, needle.baseAddress, needle.count) != nil
        }
    }

    /// Accepts a value with or without fractional seconds, under `Z` or an
    /// offset, so the shapes both CLIs and every vendor send go through one
    /// path.
    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Parses a JSON timestamp: `Z` as both CLIs write it, or an offset such as
    /// `+00:00`, which Anthropic's usage endpoint sends
    /// (`2026-09-10T12:20:00.061389+00:00`).
    ///
    /// This is the tail's hot path, and the format style is the fastest thing
    /// measured for it: on 52,340 timestamps from real logs on 2026-11-04,
    /// 0.31 us a parse guarded, against 2.07 us for the parser it replaced and
    /// 48 us for `ISO8601DateFormatter`.
    ///
    /// The style stops reading after the zone, so `...Zjunk` would parse, and
    /// the guard is what refuses it. A fraction past nine digits answers nil.
    static func parseTimestamp(_ text: String) -> Date? {
        guard endsAtItsZone(text) else { return nil }
        return try? timestampStyle.parse(text)
    }

    /// Whether nothing but a zone's own characters follows the zone.
    private static func endsAtItsZone(_ text: String) -> Bool {
        let bytes = text.utf8
        func isUTC(_ byte: UInt8) -> Bool { byte == 0x5A || byte == 0x7A }
        guard
            let zone = bytes.lastIndex(where: { isUTC($0) || $0 == 0x2B || $0 == 0x2D })
        else { return false }
        let tail = bytes[bytes.index(after: zone)...]
        if isUTC(bytes[zone]) { return tail.isEmpty }
        return !tail.isEmpty && tail.allSatisfy { (0x30...0x3A).contains($0) }
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
final class DayKeyFormatter: Sendable {
    private static let format = "yyyy-MM-dd"
    private static let localeIdentifier = "en_US_POSIX"
    /// Held for the life of the process, which is the life of the shared
    /// formatter it serves.
    private static let zoneObserver = Mutex<NSObjectProtocol?>(nil)

    /// `DateFormatter` is safe to read from several threads, not to have its
    /// zone set under a reader.
    private let formatter: Mutex<DateFormatter>
    private let zone: @Sendable () -> TimeZone

    init(zone: @escaping @Sendable () -> TimeZone = { Calendar.current.timeZone }) {
        let formatter = DateFormatter()
        formatter.dateFormat = Self.format
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: Self.localeIdentifier)
        formatter.timeZone = zone()
        self.formatter = Mutex(formatter)
        self.zone = zone
    }

    func string(from date: Date) -> String {
        formatter.withLock {
            settleZone(of: $0)
            return $0.string(from: date)
        }
    }

    func date(from string: String) -> Date? {
        formatter.withLock {
            settleZone(of: $0)
            return $0.date(from: string)
        }
    }

    private func settleZone(of formatter: DateFormatter) {
        let current = zone()
        if formatter.timeZone != current { formatter.timeZone = current }
    }

    /// Drops Foundation's cached system zone whenever the system reports a
    /// new one, so `Calendar.current` and every key read after it agree on
    /// the zone the Mac is in now rather than on the one it launched in.
    static func followSystemZone() {
        zoneObserver.withLock {
            guard $0 == nil else { return }
            $0 = observeSystemZone(on: .default) { NSTimeZone.resetSystemTimeZone() }
        }
    }

    /// Runs `reset` on every system zone change `center` reports, and hands
    /// back the observer for its caller to hold.
    static func observeSystemZone(
        on center: NotificationCenter, reset: @escaping @Sendable () -> Void
    ) -> NSObjectProtocol {
        center.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: nil) { _ in
            reset()
        }
    }
}

/// The models a reader has already reported as unpriced, so the warning is
/// one line per model per run instead of one per ingested event.
///
/// One for both adapters, which had each written the same logger out: an
/// unpriced model's tokens contribute $0 to the day's cost, which is
/// otherwise indistinguishable from a quiet day, so each reports the first
/// one it meets.
struct UnpricedModelLog {
    private var logged: Set<String> = []

    /// Logs `model` once, and only if `isPriced` answers that no pricing
    /// source rates it. The lookup runs only for a model not yet reported.
    mutating func report(_ model: String, isPriced: () -> Bool) {
        guard !logged.contains(model), !isPriced() else { return }
        logged.insert(model)
        sissyLog(
            "sissy: no rate for '\(model)' in any pricing source, so its tokens "
                + "bill at $0; add a `pricingOverride` entry in server.json")
    }

    /// Re-arms every model: a catalog refresh may price one the previous
    /// catalog lacked, and the operator wants to see that it healed.
    mutating func reset() {
        logged.removeAll()
    }
}
