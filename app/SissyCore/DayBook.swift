import Foundation

/// What one provider has counted, day by day, at each of the grains a day is
/// read at. Every key is a local midnight.
///
/// Five maps rather than a struct per day, because a day's presence in each is
/// part of the answer: a day can be counted without being billed, and a day the
/// archive was deleted under keeps its `totals` and nothing else.
///
/// `totals` is what a day cost, for the panel and for what a resume can vouch
/// for. The other four are what the archive writes.
struct DayBook {
    /// One pair of scalars for the provider's day.
    var totals: [Date: DayTotals] = [:]
    /// The same days split by model and project, which is the grain the archive
    /// keeps.
    var rows: [Date: [UsageHistoryRow: UsageHistoryTotals]] = [:]
    /// The same days counted rather than measured: how many sessions were
    /// started and how many agents they spawned. A count belongs to the
    /// provider's day and to no model at all.
    var counts: [Date: AgentCounts] = [:]
    /// The same days as the shape of the working day rather than its size:
    /// which minutes of each carried a turn, and which of those a sub-agent's.
    /// It belongs to the provider's day and to no model, project or count.
    var activity: [Date: AgentActivityDay] = [:]
    /// The same days at a fifth grain: what each model spent at each effort.
    /// `(model, effort)` is neither of the two grains above it, and `EffortKey`
    /// carries why it is not a third key on the rows.
    var effort: [Date: [EffortKey: EffortTotals]] = [:]

    /// Adds one billed event to the day it happened on, at every grain it has.
    mutating func record(_ event: UsageEvent, on day: Date) {
        let totalTokens =
            event.inputTokens
            + event.outputTokens
            + event.cacheReadTokens
            + event.cacheCreationTokens
        let existing = totals[day] ?? DayTotals(totalTokens: 0, totalCost: 0)
        totals[day] = DayTotals(
            totalTokens: existing.totalTokens + totalTokens,
            totalCost: existing.totalCost + event.cost
        )
        var byRow = rows[day] ?? [:]
        byRow[UsageHistoryRow(model: event.model, project: event.project), default: .init()]
            .add(event)
        rows[day] = byRow
        activity[day, default: .none].record(
            minute: AgentActivityDay.minute(of: event.timestamp), delegated: event.delegated)
        effort[day, default: [:]][
            EffortKey(model: event.model, effort: event.effort), default: .init()
        ].record(event)
    }

    /// Adds one agent observation to the day it happened on.
    mutating func record(_ observation: AgentActivityEvent, on day: Date) {
        if case .turnCompleted(let milliseconds) = observation.kind {
            activity[day, default: .none].recordTurn(milliseconds: milliseconds)
        } else {
            counts[day, default: .none].record(observation.kind)
        }
    }

    /// Moves every day to the key `move` gives it. Distinct dates stay distinct,
    /// so no two keys meet.
    mutating func rekey(by move: (Date) -> Date) {
        totals = Self.rekeyed(totals, by: move)
        rows = Self.rekeyed(rows, by: move)
        counts = Self.rekeyed(counts, by: move)
        activity = Self.rekeyed(activity, by: move)
        effort = Self.rekeyed(effort, by: move)
    }

    private static func rekeyed<Value>(
        _ days: [Date: Value], by move: (Date) -> Date
    ) -> [Date: Value] {
        Dictionary(days.map { (move($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    /// Drops every day before `cutoff`, at every grain.
    mutating func trim(before cutoff: Date) {
        totals = totals.filter { $0.key >= cutoff }
        rows = rows.filter { $0.key >= cutoff }
        counts = counts.filter { $0.key >= cutoff }
        activity = activity.filter { $0.key >= cutoff }
        effort = effort.filter { $0.key >= cutoff }
    }

    /// Forgets what the archive writes for every day before `today`, and answers
    /// which days that touched.
    ///
    /// **`totals` stays.** No file comes back from it, nothing reads a past day's
    /// totals, and `trim(before:)` still bounds them. Nothing this book holds says
    /// a day was deleted: `ArchiveBackfillLedger.deletedThrough` does.
    mutating func forget(before today: Date) -> Set<Date> {
        let held = Set(rows.keys).union(activity.keys).union(counts.keys).union(effort.keys)
        rows = rows.filter { $0.key >= today }
        activity = activity.filter { $0.key >= today }
        counts = counts.filter { $0.key >= today }
        effort = effort.filter { $0.key >= today }
        return held.filter { $0 < today }
    }

    // MARK: The snapshot

    /// The day totals a snapshot carries, without the days before `cutoff`.
    /// Answered rather than applied, because nothing of a snapshot is committed
    /// until the adapter has agreed to resume from it.
    static func totals(from snapshot: UsageStateSnapshot, notBefore cutoff: Date) -> [Date: DayTotals] {
        let cal = Calendar.current
        let dayFmt = UsageReaderShared.dayFormatter
        var restored: [Date: DayTotals] = [:]
        for t in snapshot.dailyTotals {
            guard let dayDate = dayFmt.date(from: t.day) else { continue }
            let dayKey = cal.startOfDay(for: dayDate)
            if dayKey < cutoff { continue }
            let cost = Decimal(string: t.cost) ?? 0
            restored[dayKey] = DayTotals(totalTokens: t.tokens, totalCost: cost)
        }
        return restored
    }

    /// Restores the counts, the activity and the effort a snapshot carries.
    ///
    /// Deliberately not gated on the day having token totals, which the rows are:
    /// a day can be counted without being billed, and such a day has no entry
    /// there at all. `trim(before:)` is what bounds these, the same as it bounds
    /// the totals themselves.
    mutating func restoreCounted(from resume: UsageStateSnapshot.HistoryResume?) {
        let cal = Calendar.current
        let dayFmt = UsageReaderShared.dayFormatter
        for row in resume?.dailyAgentCounts ?? [] {
            guard let dayDate = dayFmt.date(from: row.day) else { continue }
            counts[cal.startOfDay(for: dayDate)] = AgentCounts(
                sessions: row.sessions, agents: row.agents)
        }
        for row in resume?.dailyActivity ?? [] {
            guard let dayDate = dayFmt.date(from: row.day) else { continue }
            activity[cal.startOfDay(for: dayDate)] = row.activity
        }
        for row in resume?.dailyEffort ?? [] {
            guard let dayDate = dayFmt.date(from: row.day) else { continue }
            effort[cal.startOfDay(for: dayDate), default: [:]][
                EffortKey(model: row.model, effort: row.effort), default: .init()
            ].add(
                EffortTotals(
                    turns: row.turns,
                    totals: UsageHistoryTotals(
                        inputTokens: row.inputTokens,
                        outputTokens: row.outputTokens,
                        cacheReadTokens: row.cacheReadTokens,
                        cacheCreationTokens: row.cacheCreationTokens,
                        cacheCreation1hTokens: row.cacheCreation1hTokens ?? 0,
                        cost: Decimal(string: row.cost) ?? 0)))
        }
    }

    /// The rows a snapshot carries for the days this book holds totals for, with
    /// each working directory answered by `project`.
    func restoredRows(
        from resume: UsageStateSnapshot.HistoryResume?, project: (String) -> String?
    ) -> [Date: [UsageHistoryRow: UsageHistoryTotals]] {
        let cal = Calendar.current
        let dayFmt = UsageReaderShared.dayFormatter
        var restored: [Date: [UsageHistoryRow: UsageHistoryTotals]] = [:]
        for row in resume?.dailyModelTotals ?? [] {
            guard let dayDate = dayFmt.date(from: row.day) else { continue }
            let dayKey = cal.startOfDay(for: dayDate)
            guard totals[dayKey] != nil else { continue }
            let key = UsageHistoryRow(
                model: row.model,
                project: row.project.flatMap(project)
            )
            restored[dayKey, default: [:]][key, default: .init()].add(
                UsageHistoryTotals(
                    inputTokens: row.inputTokens,
                    outputTokens: row.outputTokens,
                    cacheReadTokens: row.cacheReadTokens,
                    cacheCreationTokens: row.cacheCreationTokens,
                    cacheCreation1hTokens: row.cacheCreation1hTokens ?? 0,
                    cost: Decimal(string: row.cost) ?? 0
                ))
        }
        return restored
    }

    /// The day totals as the snapshot writes them.
    func snapshotTotals() -> [UsageStateSnapshot.DailyTotal] {
        let dayFmt = UsageReaderShared.dayFormatter
        return totals.map { k, v in
            UsageStateSnapshot.DailyTotal(
                day: dayFmt.string(from: k),
                tokens: v.totalTokens,
                cost: NSDecimalNumber(decimal: v.totalCost).stringValue
            )
        }
    }

    /// Everything else as the snapshot writes it, nil when there is nothing to
    /// write.
    func snapshotResume() -> UsageStateSnapshot.HistoryResume? {
        let dayFmt = UsageReaderShared.dayFormatter
        var modelTotals: [UsageStateSnapshot.DailyModelTotal] = []
        for (day, byRow) in rows {
            let dayString = dayFmt.string(from: day)
            for (row, totals) in byRow {
                modelTotals.append(
                    UsageStateSnapshot.DailyModelTotal(
                        day: dayString,
                        model: row.model,
                        project: row.project,
                        inputTokens: totals.inputTokens,
                        outputTokens: totals.outputTokens,
                        cacheReadTokens: totals.cacheReadTokens,
                        cacheCreationTokens: totals.cacheCreationTokens,
                        cacheCreation1hTokens: UsageHistoryDay.present(
                            totals.cacheCreation1hTokens),
                        cost: NSDecimalNumber(decimal: totals.cost).stringValue
                    ))
            }
        }
        let agentCounts: [UsageStateSnapshot.DailyAgentCount] = counts.compactMap { day, counts in
            guard !counts.isEmpty else { return nil }
            return UsageStateSnapshot.DailyAgentCount(
                day: dayFmt.string(from: day),
                sessions: counts.sessions,
                agents: counts.agents)
        }
        let activity: [UsageStateSnapshot.DailyActivity] = activity.compactMap { day, shape in
            guard !shape.isEmpty else { return nil }
            return UsageStateSnapshot.DailyActivity(
                day: dayFmt.string(from: day), activity: shape)
        }
        var effortRows: [UsageStateSnapshot.DailyEffort] = []
        for (day, byKey) in effort {
            let dayString = dayFmt.string(from: day)
            for (key, totals) in byKey where totals.turns > 0 {
                effortRows.append(
                    UsageStateSnapshot.DailyEffort(
                        day: dayString,
                        model: key.model,
                        effort: key.effort,
                        turns: totals.turns,
                        inputTokens: totals.totals.inputTokens,
                        outputTokens: totals.totals.outputTokens,
                        cacheReadTokens: totals.totals.cacheReadTokens,
                        cacheCreationTokens: totals.totals.cacheCreationTokens,
                        cacheCreation1hTokens: UsageHistoryDay.present(
                            totals.totals.cacheCreation1hTokens),
                        cost: NSDecimalNumber(decimal: totals.totals.cost).stringValue))
            }
        }
        if modelTotals.isEmpty && agentCounts.isEmpty && activity.isEmpty && effortRows.isEmpty {
            return nil
        }
        return UsageStateSnapshot.HistoryResume(
            dailyModelTotals: modelTotals,
            dailyAgentCounts: agentCounts.isEmpty ? nil : agentCounts,
            dailyActivity: activity.isEmpty ? nil : activity,
            dailyEffort: effortRows.isEmpty ? nil : effortRows)
    }
}
