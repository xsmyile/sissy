import Foundation

/// The grain the archive keeps a day at: one row per model per project.
///
/// The project is optional because a line can name no working directory, and
/// because every row written before the archive carried the dimension decodes
/// without one. Both cases mean the same thing at read time — usage that
/// belongs to no project Sissy can name — which is why they are one value.
struct UsageHistoryRow: Hashable, Sendable {
    let model: String
    let project: String?
}

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

    mutating func add(_ other: Self) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheCreationTokens += other.cacheCreationTokens
        cost += other.cost
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
/// A row per model per project, because a store keeping only a per-provider
/// daily total cannot produce the columns the export and the report need, and
/// re-deriving them means re-reading logs that may be gone. The project landed
/// after the model, as an added optional field that older files decode as
/// absent — no version bump, exactly as this note anticipated.
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
        /// Absolute path of the repository the work was in. Absent for a line
        /// that named no working directory, and for every row written before
        /// the archive carried the dimension. A path is personal data — a
        /// client's name is a directory's name — so it stays on the machine:
        /// the panel renders the last component, and anything that carries it
        /// off the machine has to say so.
        var project: String?
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

        var totals: UsageHistoryTotals {
            UsageHistoryTotals(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheCreationTokens: cacheCreationTokens,
                cost: Decimal(string: cost) ?? 0
            )
        }
    }

    init(
        day: String, provider: String, updatedAt: Date,
        totals: [UsageHistoryRow: UsageHistoryTotals]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.day = day
        self.provider = provider
        self.updatedAt = updatedAt
        self.models =
            totals
            .filter { $0.value.totalTokens > 0 || $0.value.cost > 0 }
            .map { row, t in
                Entry(
                    model: row.model,
                    project: row.project,
                    inputTokens: t.inputTokens,
                    outputTokens: t.outputTokens,
                    cacheReadTokens: t.cacheReadTokens,
                    cacheCreationTokens: t.cacheCreationTokens,
                    cost: NSDecimalNumber(decimal: t.cost).stringValue
                )
            }
            .sorted {
                ($0.model, $0.project ?? "") < ($1.model, $1.project ?? "")
            }
    }

    /// What the day adds up to across its rows. A writer compares against it
    /// to refuse a reading less complete than the one already on disk.
    var totalTokens: Int {
        models.reduce(0) { $0 + $1.totalTokens }
    }

    /// The rows back as running totals, so a reader that resumes a day
    /// continues the count the last run left rather than starting it again.
    var totalsByRow: [UsageHistoryRow: UsageHistoryTotals] {
        var out: [UsageHistoryRow: UsageHistoryTotals] = [:]
        for entry in models {
            out[UsageHistoryRow(model: entry.model, project: entry.project), default: .init()]
                .add(entry.totals)
        }
        return out
    }

    /// This day with every project path read through `resolve` again.
    ///
    /// The archive keeps the working directory it saw, and that stays a
    /// record. What a path *means* is the resolver's answer now, and that
    /// moves underneath a file already written: a worktree deleted since names
    /// no repository any more, so a row wearing its name is a project an older
    /// build invented before the rule said not to. Re-reading where the day is
    /// used, rather than rewriting the file, is what keeps the record honest
    /// and the answer current — and on a machine where the directory is still
    /// there it folds the row into the checkout it was cut from instead of
    /// dropping the name, which a migration would have thrown away for good.
    /// A repository on an unmounted disk is the case that settles it: the file
    /// keeps the path either way, so the attribution survives, where a rewrite
    /// would have destroyed it on the first launch without the disk. What it
    /// costs is the label until the next launch, not the next mount — the
    /// resolver pins an answer for the life of the process, so a path it first
    /// read while the disk was away stays unattributed for the rest of the
    /// run. The alternative is re-walking a path that answers nothing on every
    /// flush, which is the common case, not the rare one.
    ///
    /// Two rows can land on one key — a deleted worktree and its subdirectory
    /// both answer nothing — so the totals are summed, never replaced.
    func reattributed(by resolve: (String) -> String?) -> Self {
        var totals: [UsageHistoryRow: UsageHistoryTotals] = [:]
        for entry in models {
            let row = UsageHistoryRow(model: entry.model, project: entry.project.flatMap(resolve))
            totals[row, default: .init()].add(entry.totals)
        }
        return Self(day: day, provider: provider, updatedAt: updatedAt, totals: totals)
    }

    /// What one model spent across every project the day holds for it.
    func totals(forModel model: String) -> UsageHistoryTotals {
        var out = UsageHistoryTotals()
        for (row, totals) in totalsByRow where row.model == model {
            out.inputTokens += totals.inputTokens
            out.outputTokens += totals.outputTokens
            out.cacheReadTokens += totals.cacheReadTokens
            out.cacheCreationTokens += totals.cacheCreationTokens
            out.cost += totals.cost
        }
        return out
    }

    /// True when `other` knows at least as much of this day as it holds.
    ///
    /// Two tests, and a reading has to pass both.
    ///
    /// **Every model, at the model's own total.** A row naming no project is
    /// usage Sissy could not attribute, and a reading that attributes it has
    /// not lost it — it has resolved it, which is what a re-scan on a machine
    /// whose directories are all still there does. Held to the no-project key
    /// itself, such a reading could never cover the day and the file would
    /// freeze on the first launch that knows about projects. The model total
    /// is what says whether anything actually went missing.
    ///
    /// **Every row that names a project, at its own key.** The model total
    /// alone is the hole: a scan that lost one project's session log while
    /// another project went on spending sums higher and still knows less
    /// about the one it lost.
    /// What neither test can tell apart is a day whose unattributed tokens
    /// were *resolved* into a project from one whose unattributed tokens went
    /// missing while the same model grew by at least as much somewhere else.
    /// Both leave the model's total where it was, and nothing in the rows says
    /// which happened. The day is not written short either way — that total is
    /// what says so — but on the second the money moves to the wrong project.
    /// It needs a line of today's tree to vanish and the same model to grow
    /// over it in the same pass, and the alternative is freezing every day
    /// that a re-scan could have attributed properly.
    func isCoveredBy(_ other: Self) -> Bool {
        let mine = totalsByRow
        let theirs = other.totalsByRow
        var minePerModel: [String: Int] = [:]
        var theirsPerModel: [String: Int] = [:]
        for (row, totals) in mine { minePerModel[row.model, default: 0] += totals.totalTokens }
        for (row, totals) in theirs { theirsPerModel[row.model, default: 0] += totals.totalTokens }
        guard minePerModel.allSatisfy({ (theirsPerModel[$0.key] ?? 0) >= $0.value }) else {
            return false
        }
        return mine.allSatisfy { row, totals in
            row.project == nil || (theirs[row]?.totalTokens ?? 0) >= totals.totalTokens
        }
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

    /// What the archive holds for a day, with "nothing" told apart from
    /// "nothing this build can read". A writer needs the difference: a file
    /// left by a schema this build does not know, or one that has been
    /// corrupted, is not a day to be replaced — every reading available here
    /// knows less about it than it holds.
    enum Stored: Equatable {
        case absent
        case unreadable
        case day(UsageHistoryDay)
    }

    static func stored(provider: String, day: String, in parent: URL) -> Stored {
        let url = url(provider: provider, day: day, in: parent)
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let decoded = decode(at: url) else { return .unreadable }
        return .day(decoded)
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
