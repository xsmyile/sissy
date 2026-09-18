import CryptoKit
import Foundation

/// On-disk snapshot of a per-provider usage reader. Sissy writes one of
/// these per provider so a relaunch can skip the cold backfill of that
/// provider's JSONL tree and resume from each file's last-known offset.
/// Claude Code keeps the legacy unqualified `usage-state.json` path for
/// upgrade smoothness; Codex (and future providers) use
/// `usage-state-<id>.json` via `forProvider(_:)`. Format is JSON via
/// Codable, versioned via `schemaVersion` so a future schema bump can fall
/// back to a cold scan instead of misreading old snapshots.
///
/// Money values are encoded as `String` because Foundation's JSONEncoder
/// routes `Decimal` through `Double`, which silently drops sub-cent
/// precision; round-tripping the textual form preserves the exact `Decimal`
/// the reader computed. (Same reason most ledger systems serialize monetary
/// amounts as strings or integer minor-units.)
struct UsageStateSnapshot: Codable, Equatable {
    /// Bump on any change that affects how an `Int` token count or `Decimal`
    /// cost is derived from raw JSONL — pricing-table refresh, billing-rule
    /// fix, channel remap, etc. Persisted cost is opaque-to-the-load-path, so
    /// the only way to force a recompute under new rules is to invalidate
    /// the snapshot. v2 covers the Codex reasoning double-count fix +
    /// 2026-05-25 pricing refresh. v3 covers v0.1.6 replacing the
    /// hand-maintained rate tables with the LiteLLM catalog: a v2 snapshot
    /// carries costs from a table that could not price models released after
    /// the build that wrote it, so inheriting it would pin a wrong total for
    /// the whole retain window.
    static let currentSchemaVersion = 3

    var schemaVersion: Int
    var savedAt: Date
    var claudeDataDirHash: String
    var retainDays: Int
    var files: [FileEntry]
    var dailyTotals: [DailyTotal]
    /// Dedup keys for every day still inside the retain window, which is what
    /// the ledger itself is trimmed to.
    ///
    /// It held today's alone until a turn that streams across local midnight
    /// showed what that costs: the key's day is the *event's*, so at 00:00 an
    /// in-flight turn stops matching "today" and drops out of every later
    /// snapshot while copies of it are still arriving. A relaunch then meets
    /// the next copy as a first sighting and bills the whole turn again —
    /// input, cache read, and the output already paid for.
    ///
    /// The name is the on-disk one and stays: renaming it would cost every
    /// install its ledger once, on the upgrade, to fix a word.
    var dedupKeysToday: [DedupKey]
    /// What the archive resumes from, absent in a snapshot written before it
    /// existed.
    ///
    /// The archive is a projection of this rather than a second record: a day
    /// file is rewritten whole from what this restored plus whatever the
    /// offsets beside it have not read yet, so the two cannot end up
    /// disagreeing about a day no matter which of their writes a crash
    /// interrupted.
    var historyResume: HistoryResume?
    /// State only the Codex reader can resume from, absent in a snapshot
    /// written before it existed.
    ///
    /// Optional rather than version-gated because a `schemaVersion` bump
    /// would also discard Claude Code's snapshot — a ~16 s cold scan of
    /// `~/.claude/projects` — for a change that tells it nothing. `nil` means
    /// "this snapshot predates the field", which the Codex reader answers with
    /// a cold scan of its own tree and every other reader ignores.
    var codexResume: CodexResume?
    /// Directories a `.git` entry was read from, as an install that predates
    /// `ProjectLedger` left them here.
    ///
    /// Read on load and never written again: the ledger is its own file with
    /// its own schema, because this one is quarantined whenever the way a cost
    /// is derived changes — and a memory of which directory was whose has
    /// nothing to do with cost, while the cold scan that bump forces is
    /// exactly when it is needed. The field stays so an upgrade inherits what
    /// the old build knew instead of starting blind.
    ///
    /// It holds no usage — no tokens, no cost, no times. What it does hold is
    /// paths, which are personal data like every other project path Sissy
    /// keeps.
    var projectCheckouts: [ProjectCheckout]?

    /// Grouped the way `CodexResume` is, and for the same reason: absence is
    /// one question, and within the block empty and missing mean the same
    /// thing — a day that is in `dailyTotals` with no rows here is a day the
    /// snapshot cannot vouch for, whether because it predates the archive or
    /// because it was already suppressed when this was written, and the reader
    /// leaves it unwritten rather than archiving it short.
    struct HistoryResume: Codable, Equatable {
        /// Per-model split of `dailyTotals`, at the grain the archive keeps.
        var dailyModelTotals: [DailyModelTotal]
        /// Agents and sessions counted per day, absent in a snapshot written
        /// before they were.
        ///
        /// Persisted for the reason the rows above are, and it is not an
        /// optimisation: the offsets resume at EOF, so the lines a count was
        /// read from are lines nothing will read again. Without this a
        /// relaunch would restart the day at zero and the next flush would
        /// write that partial number over a whole day.
        ///
        /// Optional rather than version-gated, because a `schemaVersion` bump
        /// discards both providers' snapshots for a change that costs Claude
        /// Code a ~16 s cold scan. `nil` is an upgrade, and the one day it
        /// lands on is the one `UsageHistoryDay.merging(counts:)` keeps whole.
        var dailyAgentCounts: [DailyAgentCount]? = nil
        /// The shape of each day — which minutes carried a turn — absent in a
        /// snapshot written before it.
        ///
        /// Persisted for the reason the counts are and not as an optimisation:
        /// the offsets resume at EOF, so the minutes are read off lines
        /// nothing will read again, and a relaunch would otherwise restart the
        /// day's shape at the moment it happened and write that stub over a
        /// whole day. It costs about 250 bytes a day, the bitmap being base64
        /// with its trailing empty bytes dropped.
        var dailyActivity: [DailyActivity]? = nil
    }

    /// One provider's agent counters for one archived day.
    struct DailyAgentCount: Codable, Equatable {
        var day: String  // YYYY-MM-DD; must equal the daily-total bucket.
        var sessions: Int
        var agents: Int
    }

    /// One provider's working shape for one archived day.
    struct DailyActivity: Codable, Equatable {
        var day: String  // YYYY-MM-DD; must equal the daily-total bucket.
        var activity: AgentActivityDay
    }

    /// Grouped so the absence above is one question rather than three, and so
    /// each collection can be non-optional: within a resume block, empty and
    /// missing mean the same thing.
    struct CodexResume: Codable, Equatable {
        /// Model resolved for each file from the `turn_context` line preceding
        /// its last consumed `token_count`. Persisted because rebuilding it
        /// means re-reading every byte already consumed — minutes of CPU on a
        /// real tree, all of it before the reader can emit anything. Claude
        /// Code needs no equivalent: it carries the model on every entry.
        var fileModels: [FileModel]
        /// Last rate-limit windows observed. Codex learns its limits only from
        /// the CLI's own event stream, so without these a restart leaves the
        /// panel's Codex gauges blank until the next turn. Claude Code
        /// re-polls the usage endpoint at boot and needs none of this.
        var rateLimitWindows: [UsageWindow]
        /// Event timestamp the windows came from, so a rollout older than the
        /// snapshot cannot overwrite them after a resume.
        var rateLimitWindowsAt: Date?
        /// Last plan Codex named, for the same reason as the windows above: it
        /// rides the CLI's own `rate_limits` block, so with offsets at EOF
        /// there is nothing left to re-read and the panel row would sit
        /// without a plan until the next turn. Optional within an already
        /// optional block — a snapshot from before this field simply resumes
        /// without one.
        var plan: String?
        /// Digest of the claims naming the account these windows and this plan
        /// were metered against. Carried so a relaunch can tell the same
        /// account from a different one — without it, signing into another
        /// seat left the previous one's gauges on the row until its buckets
        /// outlived their own resets. Nil for a snapshot from before the
        /// field, and for a token that named none of the claims.
        var accountFingerprint: String?
        /// Last credit balance Codex named, for the reason the plan above is
        /// carried: it rides the same `rate_limits` block, so a reader that
        /// resumed with its offsets at EOF has nothing left to re-read and the
        /// Credits section would be missing until the CLI's next turn. Nil for
        /// a snapshot from before the field and for a Codex that has never
        /// written the key.
        var credits: ProviderCredits?
    }

    struct FileModel: Codable, Equatable {
        var path: String
        var model: String
        /// Repository the rollout's `session_meta` named, absent in a snapshot
        /// written before the field. Per file for the reason the model is:
        /// Codex names it once, on the first line, and a resumed reader is
        /// past it.
        var project: String?
        /// Codex's own running total as of the last `token_count` read from
        /// this rollout. Carried so a relaunch can still tell a re-emitted
        /// turn from a new one — the two are told apart by this not moving,
        /// and a reader that resumed with no memory of it would bill the
        /// repeat. Absent in a snapshot written before the field, and for a
        /// rollout whose events carried no total.
        var cumulative: CodexCumulative?
        /// While a forked session is still replaying the turns it copied from
        /// its parent, the instant of the last copied one. Nil once the
        /// session reaches its own first turn, and for every session that
        /// copied nothing.
        var copyingThrough: Date?
        /// Whether another thread opened this rollout, which makes every turn
        /// it spends a sub-agent's. Codex says so once, on the `session_meta`
        /// a resumed reader is past. Written only when true, and nil in a
        /// snapshot from before the field — which reads as a session somebody
        /// started, the answer for all but a fifth of them.
        var subagent: Bool?
    }

    /// Codex's `total_token_usage`, the running total it reports beside every
    /// per-turn delta.
    ///
    /// Kept field by field rather than as the one scalar, because that is what
    /// "did this advance" has to compare: two readings whose totals match by
    /// coincidence while the breakdown moved are a turn, not a repeat.
    struct CodexCumulative: Codable, Equatable {
        var input: Int
        var cached: Int
        var output: Int
        var total: Int
    }

    struct FileEntry: Codable, Equatable {
        var path: String
        var offset: UInt64
        /// Seconds since the Unix epoch, captured with sub-second precision
        /// because Claude Code can append several times within one calendar
        /// second under load and we use mtime equality as a fast-path
        /// freshness check.
        var mtimeUnix: TimeInterval
    }

    struct DailyTotal: Codable, Equatable {
        var day: String  // YYYY-MM-DD in the local calendar at save time.
        var tokens: Int
        var cost: String  // Decimal as String — see top-of-file note.
    }

    struct DailyModelTotal: Codable, Equatable {
        var day: String  // YYYY-MM-DD; must equal the daily-total bucket.
        var model: String
        /// Repository the work was in, absent in a snapshot written before the
        /// split carried one. Resumed alongside the model for the same reason
        /// the model is: the offsets are at EOF, so a day's rows cannot be
        /// re-derived from lines nothing will read again.
        var project: String?
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var cacheCreationTokens: Int
        var cost: String  // Decimal as String — see top-of-file note.
    }

    struct DedupKey: Codable, Equatable {
        var key: String
        var day: String  // YYYY-MM-DD; must equal the daily-total bucket.
        /// Output tokens already billed for the key, absent in a snapshot
        /// written before a repeat could owe the difference. Optional rather
        /// than version-gated for the reason `historyResume` is: a
        /// `schemaVersion` bump discards both providers' snapshots.
        var outputTokens: Int?
    }
}

/// File-level wrapper that handles atomic write, quarantine of corrupt
/// snapshots, and version-mismatch fallback. Pure I/O — no provider-reader
/// knowledge. Each reader composes it.
enum UsageStatePersistence {
    /// Resolved default location. Sits next to `server.json` per the existing
    /// `ServerConfig.defaultURL` convention; both live in
    /// `~/Library/Application Support/Sissy/` as recommended by Apple's
    /// File System Programming Guide for app-managed support data.
    ///
    /// `directory` is what keeps that "next to" true when the config is not the
    /// install's own: a snapshot describes the trees one config named, so it
    /// follows that config rather than the support dir.
    static func defaultURL(in directory: URL = SissyPaths.appSupportDir) -> URL {
        directory.appendingPathComponent("usage-state.json")
    }

    /// Per-provider snapshot path (`usage-state-<id>.json`). Each provider
    /// writes its own file so a schema change in one can quarantine itself
    /// without invalidating the others. Claude Code is the exception — it
    /// stays on the unqualified `usage-state.json` legacy path.
    static func forProvider(_ id: String, in directory: URL = SissyPaths.appSupportDir) -> URL {
        directory.appendingPathComponent("usage-state-\(id).json")
    }

    /// Hash a provider's resolved data dir so a future swap (user edits
    /// server.json to point at a different dir) invalidates the snapshot
    /// without comparing raw path strings — protects against trailing-slash
    /// / symlink variations. The snapshot field name `claudeDataDirHash` is
    /// legacy from when only Claude had a snapshot.
    static func hashDataDir(_ url: URL) -> String {
        let canonical = url.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    enum LoadOutcome {
        case ok(UsageStateSnapshot)
        case missing
        case invalid(reason: String)
    }

    /// Reads + decodes. On parse failure quarantines the file so the next
    /// boot doesn't loop on the same bad bytes and the operator has a
    /// forensic artifact. Returns a structured outcome so the caller can
    /// log at the right level (info for missing, warn for invalid).
    static func load(from url: URL) -> LoadOutcome {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .invalid(reason: "read failed: \(error.localizedDescription)")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot: UsageStateSnapshot
        do {
            snapshot = try decoder.decode(UsageStateSnapshot.self, from: data)
        } catch {
            quarantine(url, reason: "decode")
            return .invalid(reason: "decode failed: \(error.localizedDescription)")
        }
        if snapshot.schemaVersion != UsageStateSnapshot.currentSchemaVersion {
            quarantine(url, reason: "schema-mismatch")
            let expected = UsageStateSnapshot.currentSchemaVersion
            return .invalid(
                reason: "schemaVersion \(snapshot.schemaVersion) != expected \(expected)"
            )
        }
        return .ok(snapshot)
    }

    /// Atomic save via `Data.write(options: .atomic)`. Foundation writes to a
    /// temp file beside the target then renames atomically — POSIX rename(2)
    /// guarantee on APFS. The parent directory is created lazily because
    /// Sissy may be the first thing to touch
    /// `~/Library/Application Support/Sissy/` on a fresh install.
    static func save(_ snapshot: UsageStateSnapshot, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: [.atomic])
    }

    /// How many copies set aside for one snapshot are kept.
    ///
    /// A snapshot this build cannot read is moved aside rather than deleted,
    /// so the failure can still be opened afterwards. Nothing removed the
    /// older ones, and a schema bump quarantines on every install at once:
    /// measured on one machine, seven were still there across three versions,
    /// the oldest four months old. The newest is the one anybody would read,
    /// and the rest are copies of a working set that has been rebuilt since.
    static let quarantineKeep = 2

    static func quarantinePrefix(for url: URL) -> String {
        "\(url.lastPathComponent).corrupt-"
    }

    private static func quarantine(_ url: URL, reason: String) {
        let ts = Int(Date().timeIntervalSince1970)
        let quarantined = url.deletingLastPathComponent()
            .appendingPathComponent("\(quarantinePrefix(for: url))\(reason)-\(ts).json")
        try? FileManager.default.moveItem(at: url, to: quarantined)
        pruneQuarantined(of: url)
    }

    /// Drops all but the newest `quarantineKeep` copies set aside for one
    /// snapshot.
    ///
    /// Candidates are named by the prefix this type writes, never by being in
    /// the directory: it is the user's, and nothing here may delete what it
    /// did not write.
    private static func pruneQuarantined(of url: URL) {
        let directory = url.deletingLastPathComponent()
        let prefix = quarantinePrefix(for: url)
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
        else { return }
        let mine =
            contents
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { modified($0) > modified($1) }
        for stale in mine.dropFirst(quarantineKeep) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .flatMap { $0 } ?? .distantPast
    }
}
