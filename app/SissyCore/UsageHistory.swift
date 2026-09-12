import Foundation

/// One model's metered usage within one day, as it accumulates in memory.
/// The four token counts are kept apart because the export (#43) names them
/// apart, and because a total can always be derived from them while the
/// split cannot be recovered from a total.
struct UsageHistoryTotals: Equatable, Sendable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var cost: Decimal = 0

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
    }

    mutating func add(_ event: UsageEvent) {
        inputTokens += event.inputTokens
        outputTokens += event.outputTokens
        cacheReadTokens += event.cacheReadTokens
        cacheCreationTokens += event.cacheCreationTokens
        cost += event.cost
    }
}

/// One provider's day, as it is kept on disk.
///
/// This is the first thing Sissy keeps that the CLIs do not keep for it: the
/// session logs hold the raw lines, but only within whatever window their own
/// tools prune to, and the tail's snapshot is a working set that a schema bump
/// throws away. So the archive is versioned on its own, and a file it cannot
/// read is left where it is rather than quarantined — an archive that deletes
/// what it does not understand is not an archive.
///
/// A row per model, because a store keeping only a per-provider daily total
/// cannot produce the model column the export needs, and re-deriving one means
/// re-reading logs that may be gone. A project dimension lands the same way the
/// grain did — as an added optional field on the row, which older files decode
/// as absent — so it needs no version bump when it arrives.
struct UsageHistoryDay: Codable, Equatable, Sendable {
    /// Bump only when a row's numbers stop meaning what they meant. A reader
    /// skips a version it does not know; it never rewrites one.
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    /// `YYYY-MM-DD` in the local calendar of the machine that wrote it, same
    /// bucketing as the day the panel shows.
    var day: String
    /// Repeated from the directory name so a file that has been copied out of
    /// the tree still says what it is.
    var provider: String
    var updatedAt: Date
    /// One row per model that actually spent something. Claude Code writes a
    /// `<synthetic>` turn with all-zero usage for its own local notices, and a
    /// row of zeroes is a model in the export that never ran.
    var models: [Entry]

    struct Entry: Codable, Equatable, Sendable {
        var model: String
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var cacheCreationTokens: Int
        /// Decimal as String: `JSONEncoder` routes `Decimal` through `Double`
        /// and drops sub-cent precision on the way. Same reason
        /// `UsageStateSnapshot` encodes money as text.
        var cost: String

        var totalTokens: Int {
            inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
        }
    }

    init(day: String, provider: String, updatedAt: Date, totals: [String: UsageHistoryTotals]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.day = day
        self.provider = provider
        self.updatedAt = updatedAt
        self.models =
            totals
            .filter { $0.value.totalTokens > 0 || $0.value.cost > 0 }
            .map { model, t in
                Entry(
                    model: model,
                    inputTokens: t.inputTokens,
                    outputTokens: t.outputTokens,
                    cacheReadTokens: t.cacheReadTokens,
                    cacheCreationTokens: t.cacheCreationTokens,
                    cost: NSDecimalNumber(decimal: t.cost).stringValue
                )
            }
            .sorted { $0.model < $1.model }
    }

    /// What the day adds up to across its rows. A writer compares against it
    /// to refuse a reading less complete than the one already on disk.
    var totalTokens: Int {
        models.reduce(0) { $0 + $1.totalTokens }
    }

    /// The rows back as running totals, so a reader that resumes a day
    /// continues the count the last run left rather than starting it again.
    var totalsByModel: [String: UsageHistoryTotals] {
        var out: [String: UsageHistoryTotals] = [:]
        for entry in models {
            out[entry.model] = UsageHistoryTotals(
                inputTokens: entry.inputTokens,
                outputTokens: entry.outputTokens,
                cacheReadTokens: entry.cacheReadTokens,
                cacheCreationTokens: entry.cacheCreationTokens,
                cost: Decimal(string: entry.cost) ?? 0
            )
        }
        return out
    }
}

/// What a window of the archive adds up to.
struct UsageHistoryRollup: Sendable, Equatable {
    /// Width of the window that was asked for, in days, so a reader can say
    /// "last 7 days" without re-deriving it.
    let days: Int
    /// Earliest day the archive actually holds inside that window, which is
    /// what stops a two-day-old install from presenting itself as a week.
    let earliestDay: Date?
    let tokens: Int
    let cost: Decimal
}

/// File-level wrapper over the archive: one directory per provider, one file
/// per day. Pure I/O, no reader knowledge — the tail composes it the way it
/// composes `UsageStatePersistence`.
///
/// A day is rewritten whole rather than appended to, so a rewrite is
/// idempotent: a cold scan that re-derives a day writes the same numbers back
/// instead of adding them twice. Days outside the tail's retain window are
/// never rewritten at all, which is what makes them frozen.
enum UsageHistoryStore {
    /// Days kept before a file is pruned, when the config names nothing.
    static let defaultRetentionDays = 90
    /// The archive is a record of what the user did, kept for as long as they
    /// asked, so it is owner-only like the `server.json` beside it. On the
    /// directory rather than the files: a day is written atomically through a
    /// temp file, which would land at the umask's mode whatever the previous
    /// file carried.
    private static let ownerOnlyDirectory: Int16 = 0o700
    /// Upper bound on what the config may name, so a typo cannot turn the
    /// archive into something that is never pruned.
    static let maxRetentionDays = 3650

    static func directory(in parent: URL) -> URL {
        parent.appendingPathComponent("history")
    }

    static func providerDirectory(_ provider: String, in parent: URL) -> URL {
        directory(in: parent).appendingPathComponent(provider)
    }

    static func url(provider: String, day: String, in parent: URL) -> URL {
        providerDirectory(provider, in: parent).appendingPathComponent("\(day).json")
    }

    /// Atomic whole-file write, same guarantee as the snapshot's: Foundation
    /// stages a temp file beside the target and renames it.
    static func save(_ day: UsageHistoryDay, in parent: URL) throws {
        let url = url(provider: day.provider, day: day.day, in: parent)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: ownerOnlyDirectory)]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(day).write(to: url, options: [.atomic])
    }

    /// One day back, or nil when it is absent, unreadable, or written by a
    /// schema this build does not know.
    static func load(provider: String, day: String, in parent: URL) -> UsageHistoryDay? {
        decode(at: url(provider: provider, day: day, in: parent))
    }

    /// What the archive holds for the `days` most recent local days, ending
    /// today. Every provider directory present is counted, including one
    /// whose provider is switched off now — the days it recorded happened.
    static func rollup(days: Int, in parent: URL, now: Date = Date()) -> UsageHistoryRollup {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let cutoff = cal.date(byAdding: .day, value: -(max(days, 1) - 1), to: today) ?? today
        var tokens = 0
        var cost: Decimal = 0
        var earliest: Date?
        for provider in providers(in: parent) {
            for (dayKey, url) in dayFiles(provider: provider, in: parent) {
                guard dayKey >= cutoff, dayKey <= today, let decoded = decode(at: url) else {
                    continue
                }
                for entry in decoded.models {
                    tokens += entry.totalTokens
                    cost += Decimal(string: entry.cost) ?? 0
                }
                earliest = earliest.map { min($0, dayKey) } ?? dayKey
            }
        }
        return UsageHistoryRollup(days: days, earliestDay: earliest, tokens: tokens, cost: cost)
    }

    /// Drops the files for days that have fallen out of retention, across
    /// every provider directory the archive holds — including one whose
    /// provider is switched off, since the days it recorded are still there
    /// and the promise the setting makes is about the archive, not about who
    /// is still writing to it.
    ///
    /// A file whose name is not a day is left alone: the archive is the user's
    /// directory and nothing here may delete what it did not write.
    static func prune(keeping retentionDays: Int, in parent: URL, now: Date = Date()) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        guard retentionDays > 0,
            let cutoff = cal.date(byAdding: .day, value: -(retentionDays - 1), to: today)
        else { return }
        for provider in providers(in: parent) {
            for (dayKey, url) in dayFiles(provider: provider, in: parent) where dayKey < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Removes the whole archive. Reachable only from the explicit button in
    /// Settings, which is the one place a user asks for it.
    static func removeAll(in parent: URL) throws {
        let dir = directory(in: parent)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.removeItem(at: dir)
    }

    private static func providers(in parent: URL) -> [String] {
        let dir = directory(in: parent)
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        return contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.map { $0.lastPathComponent }
    }

    private static func dayFiles(provider: String, in parent: URL) -> [(Date, URL)] {
        let dir = providerDirectory(provider, in: parent)
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
        let cal = Calendar.current
        return contents.compactMap { url in
            guard url.pathExtension == "json",
                let day = UsageReaderShared.dayFormatter.date(
                    from: url.deletingPathExtension().lastPathComponent)
            else { return nil }
            return (cal.startOfDay(for: day), url)
        }
    }

    private static func decode(at url: URL) -> UsageHistoryDay? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let day = try? decoder.decode(UsageHistoryDay.self, from: data),
            day.schemaVersion == UsageHistoryDay.currentSchemaVersion
        else { return nil }
        return day
    }
}
