import Foundation

/// Constants and helpers shared by the per-CLI usage readers
/// (`ClaudeCodeUsageReader`, `CodexUsageReader`). Centralized so a tuning
/// change can't silently drift between the two tails.
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

    /// `yyyy-MM-dd` day-bucket key formatter. POSIX locale + Gregorian
    /// calendar so the key is stable across locale changes that would
    /// otherwise shift digit shaping.
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()
}
