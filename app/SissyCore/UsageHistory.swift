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
    /// The part of `cacheCreationTokens` written to the 1-hour cache. Not a
    /// fifth counter: `totalTokens` already holds it through the aggregate.
    var cacheCreation1hTokens: Int = 0
    var cost: Decimal = 0

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
    }

    mutating func add(_ event: UsageEvent) {
        inputTokens += event.inputTokens
        outputTokens += event.outputTokens
        cacheReadTokens += event.cacheReadTokens
        cacheCreationTokens += event.cacheCreationTokens
        cacheCreation1hTokens += event.cacheCreation1hTokens
        cost += event.cost
    }

    mutating func add(_ other: Self) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheCreationTokens += other.cacheCreationTokens
        cacheCreation1hTokens += other.cacheCreation1hTokens
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
    /// How many sessions were started and how many agents they spawned.
    ///
    /// Beside the rows rather than inside them: a count belongs to the
    /// provider's day and to no model or project, and a row carrying it would
    /// make the answer depend on which model happened to reply. Optional
    /// because every day written before the field existed decodes without one,
    /// and `nil` there means "not counted", never "none" — which is why the
    /// panel words an absent count as a dash rather than a zero.
    ///
    /// No version bump: the field is additive and an older build reading a
    /// newer file simply ignores it, exactly as the project dimension landed.
    var agents: AgentCounts?
    /// Which minutes of the day carried a turn, and which of those a
    /// sub-agent's — the shape of the working day rather than its size.
    ///
    /// Beside the rows for the reason the counts are: it belongs to the
    /// provider's day and to no model or project. Optional on the same terms,
    /// so a day written before the field decodes without one and reads as
    /// "not measured" rather than as a day nothing happened in.
    ///
    /// No version bump: additive, and an older build reading a newer file
    /// ignores it.
    var activity: AgentActivityDay?
    /// What each model spent at each effort, which is a third reading of the
    /// same turns the two above are.
    ///
    /// Beside the rows for their reason, and not a third key on
    /// `UsageHistoryRow` — `EffortKey` carries why. Optional on the same terms
    /// as the two above, so a day written before the field reads as "not
    /// measured" rather than as a day nothing was set on.
    ///
    /// **It restates tokens the rows already hold, and that is the trade.**
    /// The rows are `model × project` and these are `model × effort`; neither
    /// can be derived from the other, and both are filled from one pass over
    /// one event, so the only way they disagree is a defect. What it buys is
    /// that the archive answers a question about effort without the row key
    /// that would freeze it.
    ///
    /// No version bump: additive, and an older build reading a newer file
    /// ignores it. `ArchiveBackfillLedger.currentSchemaVersion` is what makes
    /// the days already covered come back and name one.
    var effort: [EffortEntry]?

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
        /// The 1-hour part of `cacheCreationTokens`. Absent where there is
        /// none, which is every Codex row, and on every row written before the
        /// field existed, where it reads as zero: such a row can only be
        /// priced again with all of its cache writes at the 5-minute rate.
        var cacheCreation1hTokens: Int?
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
                cacheCreation1hTokens: cacheCreation1hTokens ?? 0,
                cost: Decimal(string: cost) ?? 0
            )
        }
    }

    /// One model's turns at one effort, as the file keeps them.
    struct EffortEntry: Codable, Equatable, Sendable {
        var model: String
        /// Absent where the lines behind this spend named no effort, which
        /// `EffortKey` carries the reason for, and for every entry written
        /// before the field was optional.
        var effort: String?
        /// How many turns ran at this pair. The count an effort is actually
        /// set per, kept beside the money because a share of spend cannot say
        /// how often a setting was reached for.
        var turns: Int
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var cacheCreationTokens: Int
        /// The 1-hour part of `cacheCreationTokens`, absent on the terms
        /// `Entry.cacheCreation1hTokens` is.
        var cacheCreation1hTokens: Int?
        /// Decimal as String, the reason `Entry.cost` is one.
        var cost: String

        var split: EffortSplit {
            EffortSplit(
                model: model, effort: effort,
                totals: EffortTotals(
                    turns: turns,
                    totals: UsageHistoryTotals(
                        inputTokens: inputTokens,
                        outputTokens: outputTokens,
                        cacheReadTokens: cacheReadTokens,
                        cacheCreationTokens: cacheCreationTokens,
                        cacheCreation1hTokens: cacheCreation1hTokens ?? 0,
                        cost: Decimal(string: cost) ?? 0)))
        }
    }

    init(
        day: String, provider: String, updatedAt: Date,
        totals: [UsageHistoryRow: UsageHistoryTotals],
        agents: AgentCounts? = nil,
        activity: AgentActivityDay? = nil,
        effort: [EffortKey: EffortTotals] = [:]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.day = day
        self.provider = provider
        self.updatedAt = updatedAt
        self.agents = agents.flatMap { $0.isEmpty ? nil : $0 }
        self.activity = activity.flatMap { $0.isEmpty ? nil : $0 }
        self.effort =
            effort.isEmpty
            ? nil
            : effort
                .filter { $0.value.turns > 0 }
                .map { key, value in
                    EffortEntry(
                        model: key.model,
                        effort: key.effort,
                        turns: value.turns,
                        inputTokens: value.totals.inputTokens,
                        outputTokens: value.totals.outputTokens,
                        cacheReadTokens: value.totals.cacheReadTokens,
                        cacheCreationTokens: value.totals.cacheCreationTokens,
                        cacheCreation1hTokens: Self.present(value.totals.cacheCreation1hTokens),
                        cost: NSDecimalNumber(decimal: value.totals.cost).stringValue)
                }
                .sorted { ($0.model, $0.effort ?? "") < ($1.model, $1.effort ?? "") }
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
                    cacheCreation1hTokens: Self.present(t.cacheCreation1hTokens),
                    cost: NSDecimalNumber(decimal: t.cost).stringValue
                )
            }
            .sorted {
                ($0.model, $0.project ?? "") < ($1.model, $1.project ?? "")
            }
    }

    /// A counter as the file keeps it: absent rather than zero, so a day with
    /// no 1-hour writes reads exactly as it did before the field existed.
    static func present(_ count: Int) -> Int? { count > 0 ? count : nil }

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

    /// The effort entries back as running totals, so a reader that folds days
    /// together continues the count rather than starting it again.
    var effortByKey: [EffortKey: EffortTotals] {
        var out: [EffortKey: EffortTotals] = [:]
        for entry in effort ?? [] {
            out[EffortKey(model: entry.model, effort: entry.effort), default: .init()]
                .add(entry.split.totals)
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
        return Self(
            day: day, provider: provider, updatedAt: updatedAt, totals: totals, agents: agents,
            activity: activity, effort: effortByKey)
    }

    /// This day with `counts` folded in, keeping whichever reading saw more.
    ///
    /// The higher of the two rather than the newer, because a count can only
    /// ever be *under*-observed: a run that started at noon saw the afternoon's
    /// agents and not the morning's, and writing its number over a file that
    /// holds the whole day would lose the morning for good. There is no
    /// symmetric case — nothing re-derives a day and legitimately finds fewer
    /// agents, since a day outside the retain window is never rewritten at all
    /// and one inside it still has the logs it was counted from.
    ///
    /// The effort entries fold by the same rule at the pair, and **whichever
    /// reading counted more turns wins the entry whole** rather than each of
    /// its counters separately: turns, tokens and money for one pair came off
    /// one pass over one set of events, and taking the maximum of each apart
    /// would publish a combination no reading ever made.
    ///
    /// This is deliberately not `isCoveredBy`'s business. That test decides
    /// whether a *day* may be written, and refusing the whole write over a
    /// count would freeze the day's tokens — which are the reading the archive
    /// exists for — on every upgrade from a build that counted nothing.
    func merging(
        counts: AgentCounts?, activity other: AgentActivityDay? = nil,
        effort otherEffort: [EffortEntry]? = nil
    ) -> Self {
        var merged = self
        if let counts {
            let mine = agents ?? .none
            let folded = AgentCounts(
                sessions: max(mine.sessions, counts.sessions),
                agents: max(mine.agents, counts.agents))
            merged.agents = folded.isEmpty ? nil : folded
        }
        if let other {
            let folded = (activity ?? .none).union(other)
            merged.activity = folded.isEmpty ? nil : folded
        }
        if let otherEffort {
            var folded = effort ?? []
            var at = Dictionary(
                uniqueKeysWithValues: folded.enumerated().map {
                    (EffortKey(model: $0.element.model, effort: $0.element.effort), $0.offset)
                })
            for entry in otherEffort {
                let key = EffortKey(model: entry.model, effort: entry.effort)
                guard let index = at[key] else {
                    at[key] = folded.count
                    folded.append(entry)
                    continue
                }
                if entry.turns > folded[index].turns { folded[index] = entry }
            }
            merged.effort =
                folded.isEmpty
                ? nil : folded.sorted { ($0.model, $0.effort ?? "") < ($1.model, $1.effort ?? "") }
        }
        return merged
    }

    /// This day with every row and effort entry that carries tokens and no
    /// cost priced through `cost`, or nil when `cost` prices none of them.
    ///
    /// Tokens without cost names a row counted while no source carried its
    /// model, on the grounds `LocalUsageProvider` reads it off its own rows.
    /// A row that has a cost keeps it: what was priced keeps the rate it was
    /// priced at. `cost` answers nil, or zero, for a model it cannot price,
    /// and that row keeps its zero.
    func pricingUnpricedRows(by cost: (UsageHistoryTotals, String) -> Decimal?) -> Self? {
        var priced = self
        var moved = false
        for index in priced.models.indices {
            let entry = priced.models[index]
            let totals = entry.totals
            guard totals.totalTokens > 0, totals.cost == 0,
                let amount = cost(totals, entry.model), amount > 0
            else { continue }
            priced.models[index].cost = NSDecimalNumber(decimal: amount).stringValue
            moved = true
        }
        for index in (priced.effort ?? []).indices {
            guard let entry = priced.effort?[index] else { continue }
            let totals = entry.split.totals.totals
            guard totals.totalTokens > 0, totals.cost == 0,
                let amount = cost(totals, entry.model), amount > 0
            else { continue }
            priced.effort?[index].cost = NSDecimalNumber(decimal: amount).stringValue
            moved = true
        }
        return moved ? priced : nil
    }

    /// What one model spent across every project the day holds for it.
    func totals(forModel model: String) -> UsageHistoryTotals {
        var out = UsageHistoryTotals()
        for (row, totals) in totalsByRow where row.model == model {
            out.inputTokens += totals.inputTokens
            out.outputTokens += totals.outputTokens
            out.cacheReadTokens += totals.cacheReadTokens
            out.cacheCreationTokens += totals.cacheCreationTokens
            out.cacheCreation1hTokens += totals.cacheCreation1hTokens
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

/// A window the panel can put its headline over.
///
/// A ladder rather than a set of alternatives: now, a week, a month,
/// everything kept, each step about four times the last. A calendar month is
/// deliberately absent — it and `thirtyDays` are the same question with two
/// answers a few percent apart, and it degenerates besides, showing two days
/// on the 2nd where a rolling window is always full. The calendar anchor is
/// the invoice question, which needs a last month and a quarter with it and
/// belongs to the report rather than to a popup in a 340 pt panel.
///
/// `today` is a case here so the panel's selection is one value, but it is
/// never rolled up from the archive: the archive's copy of today is written
/// behind the tail's flush, and a headline that went slower the moment it was
/// selected would be a worse reading than the one it replaced. The engine
/// fills it from the live day totals and asks the store only for the rest.
enum UsagePeriod: String, Codable, CaseIterable, Sendable {
    case today
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case all

    /// Width of the window in days, nil for the whole archive — which is
    /// bounded by `historyRetentionDays` rather than by anything here, so
    /// `all` means everything kept and not everything spent.
    var days: Int? {
        switch self {
        case .today: 1
        case .sevenDays: 7
        case .thirtyDays: 30
        case .all: nil
        }
    }

    /// Every period the archive answers for, which is every one but `today`.
    static let archived: [Self] = [.sevenDays, .thirtyDays, .all]

    /// The first day of a window `days` wide that includes today: `days - 1`
    /// before the start of today, inclusive, and never later than today.
    ///
    /// The one copy of the rule, because the archive's rollup, its strip, its
    /// prune, the backfill's cutoff, the forge query and the panel's caption
    /// all have to count the same days: a window that drifted in one of them
    /// would put two answers under one label. Nil only when the calendar
    /// cannot subtract, which each caller answers for itself.
    static func start(days: Int, now: Date, calendar: Calendar = .current) -> Date? {
        calendar.date(
            byAdding: .day, value: -(max(days, 1) - 1), to: calendar.startOfDay(for: now))
    }

    /// The first day this window counts, or nil for `all`, which is unbounded.
    ///
    /// A failed subtraction falls back to the start of today rather than to
    /// nil, which would turn a bounded window into the whole archive under the
    /// bounded window's name.
    func start(now: Date, calendar: Calendar = .current) -> Date? {
        guard let days else { return nil }
        return Self.start(days: days, now: now, calendar: calendar)
            ?? calendar.startOfDay(for: now)
    }
}

/// Whole local days picked on a calendar, both ends included.
///
/// Days rather than instants, because the archive answers at the day and a
/// window cut mid-day would name hours no file can split. Both ends are local
/// midnights and `to` is never after today: a window reaching into a day that
/// has not happened would be a reading of nothing under the name of a day.
///
/// Encoded as the two `yyyy-MM-dd` keys the archive files its days under,
/// not as instants: a midnight is a midnight in one zone, and a window read
/// back after a flight has to name the same two dates it was picked as.
struct UsageDaySpan: Hashable, Sendable, Codable {
    let from: Date
    let to: Date

    /// Nil when `from` is after `to` or `to` is after today.
    init?(from: Date, to: Date, now: Date = Date(), calendar: Calendar = .current) {
        let first = calendar.startOfDay(for: from)
        let last = calendar.startOfDay(for: to)
        guard first <= last, last <= calendar.startOfDay(for: now) else { return nil }
        self.from = first
        self.to = last
    }

    /// The month holding `day`, from its first day through its last or
    /// through today, whichever comes first, which is the window a month
    /// grid draws. Nil for a month that has not started.
    static func month(
        containing day: Date, now: Date = Date(), calendar: Calendar = .current
    ) -> Self? {
        guard let interval = calendar.dateInterval(of: .month, for: day),
            let last = calendar.date(byAdding: .day, value: -1, to: interval.end)
        else { return nil }
        return Self(from: interval.start, to: min(last, now), now: now, calendar: calendar)
    }

    func contains(_ day: Date) -> Bool { from <= day && day <= to }

    /// Whether the window reaches today, which is what decides whether the
    /// rate-limit gauges belong beside it.
    func includesToday(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        to == calendar.startOfDay(for: now)
    }

    /// How many days the window spans, both ends included.
    func dayCount(calendar: Calendar = .current) -> Int {
        (calendar.dateComponents([.day], from: from, to: to).day ?? 0) + 1
    }

    private enum CodingKeys: String, CodingKey {
        case from, to
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keys = UsageReaderShared.dayFormatter
        guard let first = keys.date(from: try container.decode(String.self, forKey: .from)),
            let last = keys.date(from: try container.decode(String.self, forKey: .to)),
            let span = Self(from: first, to: last, now: last)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .from, in: container, debugDescription: "not a span of whole days")
        }
        self = span
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(UsageReaderShared.dayFormatter.string(from: from), forKey: .from)
        try container.encode(UsageReaderShared.dayFormatter.string(from: to), forKey: .to)
    }
}

/// The window the panel reads over: one of the presets, or days picked on a
/// calendar.
///
/// A preset encodes exactly as a bare `UsagePeriod` always has, so every
/// preference written before a window could be picked decodes into the same
/// choice. A span decodes from its own keyed shape.
enum UsageRange: Hashable, Sendable, Codable {
    case preset(UsagePeriod)
    case days(UsageDaySpan)

    /// Width in days, nil for `all`. A span's is its own day count.
    var days: Int? {
        switch self {
        case .preset(let period): period.days
        case .days(let span): span.dayCount()
        }
    }

    /// Whether the window reaches today. Every preset ends today.
    func includesToday(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .preset: true
        case .days(let span): span.includesToday(now: now, calendar: calendar)
        }
    }

    init(from decoder: Decoder) throws {
        if let period = try? decoder.singleValueContainer().decode(UsagePeriod.self) {
            self = .preset(period)
        } else {
            self = .days(try UsageDaySpan(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .preset(let period):
            var container = encoder.singleValueContainer()
            try container.encode(period)
        case .days(let span):
            try span.encode(to: encoder)
        }
    }
}

/// Tokens and what they cost, the pair every split of a window is read in.
struct UsageSpend: Sendable, Equatable {
    var tokens: Int = 0
    var cost: Decimal = 0

    mutating func add(_ other: Self) {
        tokens += other.tokens
        cost += other.cost
    }
}

/// What the archive's files for one local day came to across every provider.
/// A day with no file has no such value, which is an absent reading rather
/// than one of zero.
struct UsageHistoryDayTotal: Sendable, Equatable {
    let day: Date
    let tokens: Int
    let cost: Decimal
}

/// What a window of the archive adds up to.
///
/// Today counts as the archive holds it, for a preset and for a span alike:
/// the file trails the live tail by up to the tail's flush, and every split
/// below is folded from the same files the headline is, so a window's
/// projects and providers add up to its own total rather than to a figure
/// read somewhere else.
struct UsageHistoryRollup: Sendable, Equatable {
    /// The window this is the total of, so a reader can name it without
    /// re-deriving it. A preset rather than a day count: `all` has no width
    /// to carry.
    let period: UsageRange
    /// Earliest day the archive actually holds inside that window, which is
    /// what stops a two-day-old install from presenting itself as a week.
    let earliestDay: Date?
    let tokens: Int
    let cost: Decimal
    /// Sessions and agents across the window, summed over every provider the
    /// archive holds a day for.
    ///
    /// A day written before the archive counted them contributes nothing,
    /// which under-reports a window that spans the change rather than
    /// misreporting it: the reading is "what Sissy has counted", and the
    /// coverage line under the figure already says how far back that is.
    let agents: AgentCounts
    /// The same counts kept apart by provider, which is the split the page
    /// draws a row from.
    ///
    /// Carried here rather than derived from the slices, because the slices
    /// answer for *today* — a row taken from them under a thirty-day heading
    /// is a figure from one window under the label of another, which is the
    /// pairing this whole panel exists to prevent.
    let agentsByProvider: [String: AgentCounts]
    /// How long the window was worked, and how much of that its sub-agents
    /// were.
    ///
    /// **Each day's providers are unioned before the days are summed**, and
    /// that is not a refinement: measured 2026-09-19, Codex runs almost
    /// entirely inside the minutes Claude Code is already working in, so a
    /// window that added the two rows together said 12h40 on a day worth
    /// 11h15.
    let activity: ActivityTotals
    /// The same kept apart by provider, which is what a row on the page reads.
    /// These do sum across days — a day belongs to one date — and they
    /// legitimately add up to more than `activity`, because two CLIs working
    /// in the same minute are one minute of the day and two of each other's.
    let activityByProvider: [String: ActivityTotals]
    /// How much of the window's input the cache answered, priced model by
    /// model at the rates `rollups` was handed.
    let cache: CacheReading
    /// What each provider spent across the window, keyed by the directory
    /// its days are filed under. These sum to `tokens` and `cost`.
    let spendByProvider: [String: UsageSpend]
    /// The window's spend by repository, in `FrameBuilder.orderedProjects`'
    /// order, every path read through the resolver again the way the export
    /// reads it.
    let projects: [ProjectTotals]
    /// What named no repository, or names one no longer: the residue the
    /// projects cannot reach the headline without. Kept rather than dropped,
    /// so `projects` and this always sum to `tokens` and `cost`.
    let unattributed: UsageSpend

    init(
        period: UsageRange, earliestDay: Date?, tokens: Int, cost: Decimal,
        agents: AgentCounts = .none, agentsByProvider: [String: AgentCounts] = [:],
        activity: ActivityTotals = .none, activityByProvider: [String: ActivityTotals] = [:],
        cache: CacheReading = .none, spendByProvider: [String: UsageSpend] = [:],
        projects: [ProjectTotals] = [], unattributed: UsageSpend = UsageSpend()
    ) {
        self.period = period
        self.earliestDay = earliestDay
        self.tokens = tokens
        self.cost = cost
        self.agents = agents
        self.agentsByProvider = agentsByProvider
        self.activity = activity
        self.activityByProvider = activityByProvider
        self.cache = cache
        self.spendByProvider = spendByProvider
        self.projects = projects
        self.unattributed = unattributed
    }
}

/// A window of days picked on a calendar: what it adds up to, and what each
/// day in it came to.
struct UsageSpanReading: Sendable, Equatable {
    let rollup: UsageHistoryRollup
    /// One element per day the archive holds a file for inside the span,
    /// summed across providers, oldest first.
    let days: [UsageHistoryDayTotal]
}

/// What one archived day came to for one provider, which is the grain a
/// per-day reading is drawn from.
///
/// Carries the model split and not the project one. The models are already
/// decoded — every day file is one `models` array and the totals beside them
/// are folded out of it — so keeping them costs the retain and nothing else,
/// and the strip's pills are read off exactly the bytes its bars are. The
/// projects are a different matter: they are the wider dimension, and a
/// window's split by repository is `UsageHistoryRollup`'s to carry rather than
/// every day's.
struct UsageHistoryDaySummary: Equatable, Sendable {
    let day: Date
    let tokens: Int
    let cost: Decimal
    /// That day's totals per model, folded across the projects the archive
    /// keeps them split by. Empty for a day whose file holds no row.
    let models: [ModelTotals]
    /// That day's split by model and effort, straight off the entries the
    /// file keeps beside its rows. Empty for a day written before the archive
    /// carried the dimension, which is an absent reading rather than a day
    /// nothing was set on.
    let effort: [EffortSplit]

    init(
        day: Date, tokens: Int, cost: Decimal, models: [ModelTotals],
        effort: [EffortSplit] = []
    ) {
        self.day = day
        self.tokens = tokens
        self.cost = cost
        self.models = models
        self.effort = effort
    }
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

    /// The `YYYY-MM-DD` of every day file one provider's directory holds, in
    /// no particular order. A file whose name is not a day is not one.
    static func storedDays(provider: String, in parent: URL) -> [String] {
        dayFiles(provider: provider, in: parent).map {
            $0.1.deletingPathExtension().lastPathComponent
        }
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

    /// What the archive holds for each of `periods`, ending today. Every
    /// provider directory present is counted, including one whose provider is
    /// switched off now — the days it recorded happened.
    ///
    /// One pass rather than a walk per window: the windows nest, so every day
    /// file would otherwise be opened and decoded once for each period that
    /// contains it, and the widest of them already reads the whole archive.
    /// A day is decoded once and added into every window whose cutoff admits
    /// it.
    ///
    /// A period holding no days comes back at zero with no earliest day, which
    /// is a reading rather than an absence: a week nothing was spent in is
    /// true, and it is the caller that knows whether there is an archive at
    /// all.
    ///
    /// A `Set` rather than an array, because every day is added into each
    /// window that admits it: the same period twice would silently double its
    /// money, and a type that cannot hold it twice is cheaper than a guard
    /// that checks. Order is not lost with it — the result is keyed, and the
    /// order the panel offers the windows in is `UsagePeriod.archived`'s.
    static func rollups(
        for periods: Set<UsagePeriod>, in parent: URL, now: Date = Date(),
        pricing: ProviderPricing = .seed, projects: ProjectResolver = ProjectResolver()
    ) -> [UsagePeriod: UsageHistoryRollup] {
        var files = UsageHistoryDayCache(pricing: pricing)
        return rollups(for: periods, in: parent, now: now, cache: &files, projects: projects)
    }

    /// The same rollups at the cache's pricing, reading only the day files
    /// `files` does not already hold as they stand now, and leaving it
    /// holding every file it read.
    ///
    /// A file is attributed through `projects` when it is read, and the cache
    /// keeps the answer with the rest of the day, so a warm rollup asks the
    /// resolver nothing but each repository's remote, which it has cached.
    /// A caller that keeps the cache keeps one resolver beside it: a cache
    /// filled through one resolver answers with that resolver's attribution.
    ///
    /// Measured 2026-10-03 against the build before the project and provider
    /// splits, with the resolver kept across calls as the engine keeps it: a
    /// warm rollup over this Mac's 70 day files went from 0.66 ms to 0.86 ms
    /// and over a 7,300-file archive from 74 ms to 75 ms, a cold one from
    /// 9.4 ms to 9.1 ms and from 979 ms to 929 ms. A resolver built per call
    /// doubled the warm figure on this Mac, every repository's remote read
    /// again, which is why the engine holds one.
    static func rollups(
        for periods: Set<UsagePeriod>, in parent: URL, now: Date = Date(),
        cache files: inout UsageHistoryDayCache, projects: ProjectResolver = ProjectResolver()
    ) -> [UsagePeriod: UsageHistoryRollup] {
        guard !periods.isEmpty else { return [:] }
        let cal = Calendar.current
        files.settle(zone: cal.timeZone)
        var held: [URL: UsageHistoryDayCache.Entry] = [:]
        defer { files.files = held }
        let today = cal.startOfDay(for: now)
        let cutoffs = periods.map { ($0, $0.start(now: now, calendar: cal)) }
        var tallies: [UsagePeriod: RollupTally] = [:]
        var unionByDay: [Date: AgentActivityDay] = [:]
        for provider in providers(in: parent) {
            for url in dayFileURLs(
                provider: provider, in: parent, prefetching: UsageHistoryDayCache.stampKeys)
            {
                guard
                    let (dayKey, day) = files.reading(
                        at: url, through: today, holding: &held, dayKey: dayKey(of:),
                        read: { url, pricing in
                            decode(at: url).map {
                                UsageHistoryDayCache.Reading(
                                    $0, provider: provider, pricing: pricing, projects: projects)
                            }
                        })
                else { continue }
                if let shape = day.activity {
                    unionByDay[dayKey, default: .none].formUnion(shape)
                }
                for (period, cutoff) in cutoffs where cutoff.map({ dayKey >= $0 }) ?? true {
                    tallies[period, default: RollupTally()].add(day, on: dayKey, provider: provider)
                }
            }
        }
        for (dayKey, shape) in unionByDay {
            let totals = ActivityTotals(shape)
            for (period, cutoff) in cutoffs where cutoff.map({ dayKey >= $0 }) ?? true {
                tallies[period, default: RollupTally()].activity.add(totals)
            }
        }
        var out: [UsagePeriod: UsageHistoryRollup] = [:]
        for period in periods {
            out[period] = (tallies[period] ?? RollupTally())
                .rollup(.preset(period), projects: projects)
        }
        return out
    }

    /// What the archive holds for `span`, and what each day in it came to.
    ///
    /// The same reading `rollups` takes of a preset, over any run of whole
    /// days, read off disk rather than through a cache: it answers a window
    /// somebody picked, once, and a cache kept for it would be held for a
    /// window nobody is looking at any more. A month is one call.
    ///
    /// Today counts as the archive holds it, which is the rule the presets
    /// follow too, so a span ending today and the preset of the same width
    /// agree. The figure the live tail holds for today runs ahead of the file
    /// by up to the tail's flush, and mixing the two would put one day under
    /// two readings in one window.
    ///
    /// The span's own files are addressed by name rather than found by
    /// listing the directories: naming every file in the archive is most of
    /// what a walk costs, and a span reads a handful of them. Measured
    /// 2026-10-03, a month took 5.8 ms over this Mac's archive and 6.8 ms over
    /// a 7,300-file one, a single day 0.7 ms and 0.3 ms, where listing the
    /// directories had put 352 ms under that single day.
    static func reading(
        over span: UsageDaySpan, in parent: URL, pricing: ProviderPricing = .seed,
        projects: ProjectResolver = ProjectResolver()
    ) -> UsageSpanReading {
        let cal = Calendar.current
        var tally = RollupTally()
        var unionByDay: [Date: AgentActivityDay] = [:]
        var byDay: [Date: UsageSpend] = [:]
        let dayKeys = sequence(first: span.from) { cal.date(byAdding: .day, value: 1, to: $0) }
            .prefix { $0 <= span.to }
            .map { ($0, UsageReaderShared.dayFormatter.string(from: $0)) }
        for provider in providers(in: parent) {
            for (dayKey, name) in dayKeys {
                guard let decoded = decode(at: url(provider: provider, day: name, in: parent))
                else { continue }
                let day = UsageHistoryDayCache.Reading(
                    decoded, provider: provider, pricing: pricing, projects: projects)
                if let shape = day.activity {
                    unionByDay[dayKey, default: .none].formUnion(shape)
                }
                tally.add(day, on: dayKey, provider: provider)
                byDay[dayKey, default: UsageSpend()].add(UsageSpend(tokens: day.tokens, cost: day.cost))
            }
        }
        for shape in unionByDay.values {
            tally.activity.add(ActivityTotals(shape))
        }
        return UsageSpanReading(
            rollup: tally.rollup(.days(span), projects: projects),
            days:
                byDay
                .map { UsageHistoryDayTotal(day: $0.key, tokens: $0.value.tokens, cost: $0.value.cost) }
                .sorted { $0.day < $1.day })
    }

    /// One provider's archived days inside the `days` most recent local days,
    /// oldest first and **strictly before today**.
    ///
    /// Only days the archive actually holds are in the result. A day Sissy was
    /// not running for has no file and gets no element, which is what keeps a
    /// caller from drawing it as a day that cost nothing — an absent reading
    /// and a reading of zero are different answers, and a bar chart is the one
    /// surface where confusing them is a claim about someone's week.
    ///
    /// Today is excluded because the archive is not where today is read from:
    /// the day file is written on the tail's own throttle while the frame is
    /// emitted as events land, so a caller pairs this with the slice it is
    /// already drawing rather than with a figure that lags it.
    static func series(
        provider: String, days: Int, in parent: URL, now: Date = Date()
    ) -> [UsageHistoryDaySummary] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let cutoff = UsagePeriod.start(days: days, now: now, calendar: cal) ?? today
        return dayFiles(provider: provider, in: parent)
            .filter { $0.0 >= cutoff && $0.0 < today }
            .compactMap { day, url in
                guard let decoded = decode(at: url) else { return nil }
                return UsageHistoryDaySummary(
                    day: day,
                    tokens: decoded.models.reduce(0) { $0 + $1.totalTokens },
                    cost: decoded.models.reduce(Decimal(0)) { $0 + (Decimal(string: $1.cost) ?? 0) },
                    models: foldByModel(decoded.models),
                    effort: (decoded.effort ?? []).map(\.split)
                )
            }
            .sorted { $0.day < $1.day }
    }

    /// One day's archived rows folded down to a total per model.
    ///
    /// The archive keeps a row per model *per project*, which is the grain the
    /// export answers at; a strip of bars answers at the day, so the projects
    /// are summed away here rather than by every caller. No zero filter: a row
    /// that spent nothing never reached the file, which is what
    /// `UsageHistoryDay.init` guarantees on the way to disk.
    private static func foldByModel(_ entries: [UsageHistoryDay.Entry]) -> [ModelTotals] {
        var byModel: [String: UsageHistoryTotals] = [:]
        for entry in entries {
            byModel[entry.model, default: .init()].add(entry.totals)
        }
        return byModel.map { ModelTotals(model: $0.key, totals: $0.value) }
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
        guard retentionDays > 0,
            let cutoff = UsagePeriod.start(days: retentionDays, now: now)
        else { return }
        for provider in providers(in: parent) {
            for (dayKey, url) in dayFiles(provider: provider, in: parent) where dayKey < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Every day the archive holds, across every provider directory present,
    /// oldest first and ordered within a day by provider.
    ///
    /// Unbounded on purpose where `rollup` takes a window: retention has
    /// already bounded what is on disk, and a second bound here would mean an
    /// export that silently carried less than the archive the caption names.
    /// A day this build cannot decode is skipped rather than guessed at, the
    /// same answer `load` gives.
    static func allDays(in parent: URL) -> [UsageHistoryDay] {
        var out: [UsageHistoryDay] = []
        for provider in providers(in: parent).sorted() {
            for (_, url) in dayFiles(provider: provider, in: parent) {
                guard let decoded = decode(at: url) else { continue }
                out.append(decoded)
            }
        }
        return out.sorted { lhs, rhs in
            let left: [String] = [lhs.day, lhs.provider]
            let right: [String] = [rhs.day, rhs.provider]
            return left.lexicographicallyPrecedes(right)
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
        dayFileURLs(provider: provider, in: parent).compactMap { url in
            dayKey(of: url).map { ($0, url) }
        }
    }

    private static func dayFileURLs(
        provider: String, in parent: URL, prefetching keys: [URLResourceKey] = []
    ) -> [URL] {
        let dir = providerDirectory(provider, in: parent)
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )) ?? []
        return contents.filter { $0.pathExtension == "json" }
    }

    /// The local midnight a day file's name stands for, or nil for a name
    /// that is not a day.
    private static func dayKey(of url: URL) -> Date? {
        UsageReaderShared.dayFormatter.date(from: url.deletingPathExtension().lastPathComponent)
            .map { Calendar.current.startOfDay(for: $0) }
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

/// The day files `UsageHistoryStore.rollups` has read, held by its caller
/// between calls and keyed by what the file system says about each file.
///
/// Reading a day is most of what a rollup costs, and a past day is almost
/// never rewritten. A file whose modification date or size has moved since it
/// was read is read again, so a rewrite by any writer, in this process or
/// not, is picked up on the next call; a file that is gone is dropped.
/// Measured 2026-09-29 on a 7,300-file archive, a rollup took 1,100 ms, and
/// parsing each file's name into its day was 86% of what was left once the
/// decoding was cached, so the day a name stands for is kept too, and the
/// whole cache is dropped when the time zone that day was a midnight in
/// changes.
///
/// Only a day read and decoded is kept. A file that failed to decode is read
/// again on the next call, as it was before there was a cache, and a day
/// after today is neither read nor kept, since it becomes one to read when
/// the calendar reaches it.
///
/// A day is kept already priced, which is why the cache carries the pricing
/// and a rollup through it takes none of its own: a cache built at one
/// pricing cannot answer at another, and a caller whose rates change starts
/// a new one.
struct UsageHistoryDayCache: Sendable {
    let pricing: ProviderPricing

    init(pricing: ProviderPricing = .seed) {
        self.pricing = pricing
    }

    /// What a rollup takes from one day file.
    fileprivate struct Reading: Sendable {
        let tokens: Int
        let cost: Decimal
        let cache: CacheReading
        let agents: AgentCounts
        let activity: AgentActivityDay?
        let activityTotals: ActivityTotals
        /// The day's spend by repository as `projects` answered when the file
        /// was read, nil keying what named none. Folded across models, so a
        /// day holds a key per repository rather than a row per model too.
        let projects: [String?: UsageSpend]

        /// `provider` is the directory the file was found in.
        init(
            _ day: UsageHistoryDay, provider: String, pricing: ProviderPricing,
            projects resolver: ProjectResolver
        ) {
            var tokens = 0
            var cost: Decimal = 0
            var cache = CacheReading.none
            var projects: [String?: UsageSpend] = [:]
            for entry in day.models {
                let spend = UsageSpend(
                    tokens: entry.totalTokens, cost: Decimal(string: entry.cost) ?? 0)
                tokens += spend.tokens
                cost += spend.cost
                projects[entry.project.flatMap(resolver.project(for:)), default: UsageSpend()]
                    .add(spend)
                cache.add(
                    provider: provider, model: entry.model, totals: entry.totals,
                    pricing: pricing)
            }
            self.tokens = tokens
            self.cost = cost
            self.cache = cache
            self.agents = day.agents ?? .none
            self.activity = day.activity
            self.activityTotals = day.activity.map(ActivityTotals.init) ?? .none
            self.projects = projects
        }
    }

    fileprivate struct Entry: Sendable {
        let modified: Date
        let size: Int
        let dayKey: Date
        let reading: Reading
    }

    fileprivate var files: [URL: Entry] = [:]
    private var zone: TimeZone?

    fileprivate static let stampKeys: [URLResourceKey] = [
        .contentModificationDateKey, .fileSizeKey,
    ]

    /// Forgets every file when the day keys were made in another zone.
    fileprivate mutating func settle(zone current: TimeZone) {
        guard zone != current else { return }
        files = [:]
        zone = current
    }

    /// The day the file at `url` stands for and what it holds, from this cache
    /// when the file is as it was read, recorded into `held` when it was read
    /// and decoded. Nil for a name that is not a day, for a day after `today`,
    /// which are never read, and for a file that does not decode. A file
    /// whose stamp cannot be read is read and not kept.
    fileprivate func reading(
        at url: URL, through today: Date, holding held: inout [URL: Entry],
        dayKey: (URL) -> Date?, read: (URL, ProviderPricing) -> Reading?
    ) -> (Date, Reading)? {
        guard let values = try? url.resourceValues(forKeys: Set(Self.stampKeys)),
            let modified = values.contentModificationDate,
            let size = values.fileSize
        else {
            guard let key = dayKey(url), key <= today, let reading = read(url, pricing)
            else { return nil }
            return (key, reading)
        }
        if let entry = files[url], entry.modified == modified, entry.size == size {
            held[url] = entry
            return entry.dayKey <= today ? (entry.dayKey, entry.reading) : nil
        }
        guard let key = dayKey(url), key <= today, let reading = read(url, pricing)
        else { return nil }
        held[url] = Entry(modified: modified, size: size, dayKey: key, reading: reading)
        return (key, reading)
    }
}

/// One window's sums as the days in it are added, which is the one fold both
/// a preset's rollup and a span's go through.
private struct RollupTally {
    var spend = UsageSpend()
    var agents = AgentCounts.none
    var agentsByProvider: [String: AgentCounts] = [:]
    /// Added by the caller from each day's providers unioned, never per file:
    /// two CLIs in one minute are one minute of the day.
    var activity = ActivityTotals.none
    var activityByProvider: [String: ActivityTotals] = [:]
    var cache = CacheReading.none
    var spendByProvider: [String: UsageSpend] = [:]
    var projects: [String: UsageSpend] = [:]
    var unattributed = UsageSpend()
    var earliest: Date?

    mutating func add(_ day: UsageHistoryDayCache.Reading, on dayKey: Date, provider: String) {
        let spend = UsageSpend(tokens: day.tokens, cost: day.cost)
        self.spend.add(spend)
        agents.add(day.agents)
        agentsByProvider[provider, default: .none].add(day.agents)
        activityByProvider[provider, default: .none].add(day.activityTotals)
        cache.add(day.cache)
        spendByProvider[provider, default: UsageSpend()].add(spend)
        for (project, share) in day.projects {
            guard let project else {
                unattributed.add(share)
                continue
            }
            projects[project, default: UsageSpend()].add(share)
        }
        earliest = earliest.map { min($0, dayKey) } ?? dayKey
    }

    func rollup(_ period: UsageRange, projects resolver: ProjectResolver) -> UsageHistoryRollup {
        UsageHistoryRollup(
            period: period,
            earliestDay: earliest,
            tokens: spend.tokens,
            cost: spend.cost,
            agents: agents,
            agentsByProvider: agentsByProvider,
            activity: activity,
            activityByProvider: activityByProvider,
            cache: cache,
            spendByProvider: spendByProvider,
            projects: FrameBuilder.orderedProjects(
                projects.map { path, share in
                    ProjectTotals(
                        path: path, tokens: share.tokens, cost: share.cost,
                        remote: resolver.repositoryRemote(for: path))
                }),
            unattributed: unattributed)
    }
}
