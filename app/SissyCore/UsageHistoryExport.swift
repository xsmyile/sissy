import Foundation

/// The archive as a spreadsheet reads it: one row per day, provider, model and
/// project, at the finest grain the record holds.
///
/// **No period lives here.** A month, a quarter and a week are aggregations of
/// these rows, and a pivot table does them without Sissy implementing them a
/// second time — which is the whole reason the export is CSV rather than a
/// workbook. The panel is where a period is *read*; this is what carries the
/// rows off the machine so somebody can ask their own question of them.
///
/// Cost is the archive's own decimal string, never `UsageFormat`'s: the
/// formatters round for 340 points of menu bar, and a spreadsheet summing a
/// column of rounded cents lands somewhere the panel never claimed.
enum UsageHistoryExport {
    /// Written verbatim as the first line, and the order every row follows.
    ///
    /// `project` is the last path component, which is the label the panel
    /// renders and the one a person groups by. `project_path` is the absolute
    /// path the archive holds, and it is here because two unrelated
    /// repositories can share a basename — without it those two land on one
    /// row of somebody's pivot table and the money is wrong. It is also the
    /// reason this file is personal data in a way the panel is not, which the
    /// button that writes it has to say before it is pressed.
    static let columns = [
        "day", "provider", "model", "project", "project_path",
        "input_tokens", "output_tokens", "cache_read_tokens", "cache_creation_tokens",
        "cost",
    ]

    /// The activity file's own columns, one row per day and provider.
    ///
    /// **A second file rather than columns on the rows above**, and that is
    /// not tidiness. Those rows are per day *per model per project*, and a
    /// day's worked minutes belong to none of those grains — repeated across
    /// them, the first pivot table that sums the column multiplies the day by
    /// however many models answered in it. The same trap the `project_path`
    /// column exists to close, one grain up.
    ///
    /// `blocks` is here because the two durations cannot imply it: eight hours
    /// in one sitting and eight across eleven are the same figure and not the
    /// same day.
    static let activityColumns = [
        "day", "provider", "active_minutes", "delegated_minutes", "blocks",
    ]

    /// Basename of the file holding every provider's rows, and the one
    /// provider id that cannot name its own file — a provider called `all`
    /// would write into this one. Nothing enforces that, because provider ids
    /// are Sissy's own (`claude-code`, `codex`) rather than a vendor's.
    static let combinedName = "all"

    /// The rows of one day, flattened and ordered so two exports of an
    /// unchanged archive are byte-identical. `UsageHistoryDay.models` comes
    /// out of a dictionary, so without this the row order is whatever the
    /// hashing gave and a diff of two exports is noise.
    private static func rows(_ day: UsageHistoryDay) -> [[String]] {
        let ordered = day.models.sorted { lhs, rhs in
            let left: [String] = [lhs.model, lhs.project ?? ""]
            let right: [String] = [rhs.model, rhs.project ?? ""]
            return left.lexicographicallyPrecedes(right)
        }
        return ordered.map { entry in
            let path: String = entry.project ?? ""
            let name: String = path.isEmpty ? "" : (path as NSString).lastPathComponent
            let row: [String] = [
                day.day,
                day.provider,
                entry.model,
                name,
                path,
                String(entry.inputTokens),
                String(entry.outputTokens),
                String(entry.cacheReadTokens),
                String(entry.cacheCreationTokens),
                entry.cost,
            ]
            return row
        }
    }

    /// RFC 4180, which is what Numbers and Excel both parse.
    ///
    /// A model name or a repository path may hold a comma or a quote, and a
    /// path may hold anything a filesystem allows — so the escaping is not
    /// defensive, it is the format. A field is quoted whenever it carries a
    /// separator, a quote, a newline, or edge whitespace a reader would
    /// otherwise trim.
    static func field(_ value: String) -> String {
        let needsQuotes =
            value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline })
            || value.hasPrefix(" ") || value.hasSuffix(" ")
        guard needsQuotes else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// The days as one CSV document, header included.
    ///
    /// A day with no rows contributes none: the archive already drops a model
    /// that spent nothing, and a zero row in a spreadsheet is a model somebody
    /// has to explain never ran.
    static func csv(_ days: [UsageHistoryDay]) -> String {
        var lines = [columns.joined(separator: ",")]
        for day in days {
            for row in rows(day) {
                lines.append(row.map(field).joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The worked days as one CSV document, header included.
    ///
    /// A day the archive holds no shape for contributes no row, on the rule
    /// the panel draws it by: a day written before Sissy measured this, or one
    /// it was not running for, is unmeasured rather than a day of no work, and
    /// a zero in a spreadsheet is the second claim.
    ///
    /// Per provider and never unioned, unlike the panel's own figure: a
    /// spreadsheet can sum a column and cannot union two bitmaps, so the file
    /// carries the grain the archive holds and says so in the column name.
    /// Summing two providers' minutes for one day therefore over-counts a day
    /// they both worked, which is the honest cost of a format with no rows to
    /// intersect.
    static func activityCSV(_ days: [UsageHistoryDay]) -> String {
        var lines = [activityColumns.joined(separator: ",")]
        for day in days {
            guard let activity = day.activity, activity.hasMinutes else { continue }
            let row: [String] = [
                day.day,
                day.provider,
                String(activity.activeMinutes),
                String(activity.delegatedMinutes),
                String(activity.blocks.count),
            ]
            lines.append(row.map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `sissy-activity.csv`, one file for every provider: it is one row a day
    /// each, where the usage rows are thousands.
    static let activityFileName = "sissy-activity.csv"

    /// `sissy-usage-<provider>.csv`, and `sissy-usage-all.csv` for the
    /// combined one. The provider is the id the archive filed the day under,
    /// so a provider added later names its own file without a release.
    static func fileName(provider: String) -> String {
        "sissy-usage-\(provider).csv"
    }

    /// Writes one file per provider plus the combined one into `directory`.
    ///
    /// Each file is written atomically, so nothing here leaves a half-written
    /// CSV for somebody to open and believe. The *set* is not atomic: a
    /// failure on the third file keeps the two already written, and the throw
    /// is what tells the caller the directory holds less than the archive.
    /// Staging the lot through a temporary directory would buy all-or-nothing
    /// at the cost of writing every byte twice, and the caller already has to
    /// name the error either way.
    static func write(_ days: [UsageHistoryDay], to directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        for provider in Set(days.map { $0.provider }).sorted() {
            let url = directory.appendingPathComponent(fileName(provider: provider))
            try csv(days.filter { $0.provider == provider })
                .write(to: url, atomically: true, encoding: .utf8)
        }
        try csv(days).write(
            to: directory.appendingPathComponent(fileName(provider: combinedName)),
            atomically: true,
            encoding: .utf8
        )
        try activityCSV(days).write(
            to: directory.appendingPathComponent(activityFileName),
            atomically: true,
            encoding: .utf8
        )
    }
}
