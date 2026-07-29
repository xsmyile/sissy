import CryptoKit
import Foundation

/// On-disk snapshot of a per-provider usage reader. The daemon writes one
/// of these per provider so a restart can skip the cold backfill of that
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
    /// Dedup keys for the current day only (`startOfDay(today)` ≤ eventDay).
    /// Older keys aren't worth persisting — by the time a daemon restart
    /// happens, yesterday's streaming chunks have long since been flushed
    /// and any duplicate write would have been seen within the same process
    /// lifetime. Today-only keeps the file small (~tens of KB) while still
    /// protecting against the assistant-turn-streamed-across-restart edge.
    var dedupKeysToday: [DedupKey]

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

    struct DedupKey: Codable, Equatable {
        var key: String
        var day: String  // YYYY-MM-DD; must equal the daily-total bucket.
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
    static var defaultURL: URL {
        SissyPaths.appSupportDir.appendingPathComponent("usage-state.json")
    }

    /// Per-provider snapshot path (`usage-state-<id>.json`). Each provider
    /// writes its own file so a schema change in one can quarantine itself
    /// without invalidating the others. Claude Code is the exception — it
    /// stays on the unqualified `usage-state.json` legacy path.
    static func forProvider(_ id: String) -> URL {
        SissyPaths.appSupportDir.appendingPathComponent("usage-state-\(id).json")
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
    /// the daemon may be the first thing to touch
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

    private static func quarantine(_ url: URL, reason: String) {
        let ts = Int(Date().timeIntervalSince1970)
        let quarantined = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(reason)-\(ts).json")
        try? FileManager.default.moveItem(at: url, to: quarantined)
    }
}
