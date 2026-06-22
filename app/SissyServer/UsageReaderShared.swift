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
    /// lines fans out one broadcast instead of one per line.
    static let pollEmitThrottle: TimeInterval = 0.2

    /// Slack added to a file's persisted mtime before treating the on-disk
    /// copy as changed, absorbing sub-millisecond filesystem timestamp
    /// rounding so an unchanged file isn't re-ingested on every poll.
    static let mtimeTolerance: TimeInterval = 0.0005

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
