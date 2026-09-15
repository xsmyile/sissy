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

    /// Basename of the file holding every provider's rows.
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

    /// `sissy-usage-<provider>.csv`, and `sissy-usage-all.csv` for the
    /// combined one. The provider is the id the archive filed the day under,
    /// so a provider added later names its own file without a release.
    static func fileName(provider: String) -> String {
        "sissy-usage-\(provider).csv"
    }

    /// Writes one file per provider plus the combined one into `directory`.
    ///
    /// Throws rather than reporting partial success: the caller's gesture was
    /// "give me the archive", and a directory holding one CSV of three is a
    /// worse answer than an error naming what stopped it. Each file is written
    /// atomically, so a failure part-way leaves no half-written CSV behind for
    /// somebody to open and believe.
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
    }
}
