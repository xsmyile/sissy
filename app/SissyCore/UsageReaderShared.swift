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
