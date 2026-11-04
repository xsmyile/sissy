import Foundation

extension UsagePanelSnapshot {
    /// One connected forge's two counters, as the Overview prints them.
    ///
    /// `login` is on the row because it is the only thing on the line that says
    /// whose figures these are, and a CLI's own configuration cannot be trusted
    /// to answer that: measured 2026-09-17, `gh`'s configuration named one
    /// account for a token that answered as another. The forge's mark beside it
    /// is `ForgeMark`, which the project rows already carry.
    ///
    /// The figures and the reading's own state are separate and may both be
    /// present. A reading that has gone stale keeps its figures and says how
    /// old they are; one that never arrived has a reason and no figures.
    /// Neither state is a zero, which is the rule the whole panel is on — an
    /// empty gauge is a measurement and this would be the absence of one.
    struct ForgeRow: Equatable, Identifiable {
        let id: String
        let kind: ForgeKind
        let host: String
        /// The heading over this forge's section, window included.
        let title: String
        let login: String?
        /// The three counters, already grouped, each nil where the vendor
        /// answered nothing for this window.
        ///
        /// Three values rather than one sentence, because two of them are drawn
        /// behind a mark rather than a word and a view cannot put a glyph
        /// inside a string the formatter has already joined. A row with all
        /// three nil is no reading, which the caller draws as a dash.
        let contributions: String?
        let merged: String?
        let issues: String?
        let comments: String?
        /// When the figures beside it were read, nil for a connection that has
        /// never once answered.
        ///
        /// The date rather than the sentence built from it, because the age
        /// has to keep advancing under an open panel and this block's frame
        /// arrives every five to thirty minutes. `StatusRow.checkedAt` is the
        /// same shape for the same reason, and `PanelProviderStatus` words it
        /// on the view's own clock.
        let readAt: Date?
        /// Why the last read did not work, nil on one that did.
        let failure: ForgeReadFailure?
        /// The newest thing the account did, the event rather than a sentence
        /// for the reason `readAt` is a date: its age is worded on the view's
        /// own clock.
        ///
        /// Kept across midnight where `Today`'s figures are not: it answers
        /// no window, so a new day has not ended it.
        let latest: ForgeEvent?
        let tooltip: String
        /// What each mark means, since a glyph cannot introduce itself.
        let mergedHelp: String
        let issuesHelp: String
        let commentsHelp: String
        /// The month's Actions allowances, nil where the counter is off or
        /// the forge has none to read.
        let actions: ActionsBlock?

        var hasFigures: Bool {
            contributions != nil || merged != nil || issues != nil || comments != nil
        }
    }

    /// One GitHub connection's Actions allowances for the month.
    ///
    /// **Drawn as limit windows, not as counters**, because that is what an
    /// allowance is: it has its own reset, the first of the month in UTC, and
    /// does not move when the panel's period does. So each owner is a
    /// `WindowRow` with the pace the rate-limit rows carry, and the one that
    /// runs out first leads by the rule `binding` holds for those.
    struct ActionsBlock: Equatable {
        let title: String
        /// Every owner that spent any of its allowance this month, the one
        /// running out soonest first. An owner that ran nothing has no row:
        /// four organisations at 0% would be four bars saying nothing.
        let rows: [ActionsRow]
        /// Said once, under the rows, while the token cannot read the
        /// account's own bill.
        let scopeNotice: String?
    }

    struct ActionsRow: Equatable, Identifiable {
        /// The owner's login.
        let id: String
        /// The gauge, nil for a plan whose allowance Sissy does not know,
        /// where the row prints the minutes instead.
        let window: WindowRow?
        /// The reading when there is no gauge.
        let minutes: String
        /// What happened at 100%, nil below it.
        let state: String?
        /// Whether that state is CI that has stopped, which is drawn red.
        let stopped: Bool
        /// The repository and runner that cost the most.
        let spender: String?
        let isBinding: Bool
    }

    /// Each forge's counters over a picked window, held with the window they
    /// were asked for.
    ///
    /// Matched on the days rather than on the instants each reading carries:
    /// those are local midnights worked out in the zone in force when the
    /// question was asked, and the same days worked out again after a zone
    /// change are other instants. An answer that came back empty, which is
    /// also what a failed read answers, is still the answer: every row it
    /// names nothing for is the absence it is rather than a row being read.
    struct ForgeSpanAnswer: Equatable {
        let span: UsageDaySpan
        let readings: [ForgeSpanReading]
    }

    /// The forge rows for the window the headline resolved to.
    ///
    /// The window is the resolved one rather than the requested one, so the
    /// rows cannot answer a period the control is not showing. That does tie
    /// the forge to the archive on a fresh install — with nothing archived the
    /// control does not appear and every row reads today — and it is the right
    /// way round: the block sits under a period the user picked for the money,
    /// and two windows under one control would be worse than one window that
    /// starts narrow.
    ///
    /// **A reading from before midnight loses `Today` and keeps the rest.**
    /// Every figure is over a window the vendor worked out from the instant it
    /// was asked for, so a reading taken yesterday answers yesterday's
    /// windows — but only one of them has *ended*. `Today` holds the whole of
    /// the previous day under a heading claiming this one, so it keeps its row
    /// and loses its figures: the dash a reading that never arrived gets,
    /// which is the roll-over rule the rate-limit windows are already on, with
    /// the caption beside it saying how long ago the last reading was.
    ///
    /// The wider windows have only *moved*, and they stay. Seven days ending
    /// yesterday still covers six of the seven, thirty covers twenty-nine, and
    /// `all` has no start to move at all — `UsagePeriod.days` is nil for it.
    /// Those are stale rather than wrong, staleness is what the age on the row
    /// now reports, and blanking them would throw away a reading the user can
    /// discount for themselves. The poll caps its own wait at midnight so even
    /// `Today` goes blank for seconds; what this is really for is the Mac that
    /// was asleep or offline across the boundary.
    ///
    /// **A section is headed by its vendor, and by its host where the vendor
    /// is not enough.** Two connections to one vendor, `github.com` beside a
    /// GitHub Enterprise or two self-hosted GitLabs, would otherwise head two
    /// sections with the same word.
    static func makeForge(
        _ readings: [ForgeActivityReading], period: UsagePeriod, now: Date,
        calendar: Calendar = .current
    ) -> [ForgeRow] {
        let shared = Set(Dictionary(grouping: readings, by: \.kind).filter { $0.value.count > 1 }.keys)
        return readings.map { reading in
            let name = shared.contains(reading.kind) ? reading.host : UsageFormat.forgeName(reading.kind)
            let ended =
                period == .today && !calendar.isDate(reading.readAt, inSameDayAs: now)
            let current = ended ? nil : reading
            let contributionsFloor = reading.contributionsAreAFloor(for: period)
            let floored = contributionsFloor || reading.commentsAreAFloor(for: period)
            let contributions = current.flatMap { $0.contributions(for: period) }
                .map { UsageFormat.forgeCount($0, atLeast: contributionsFloor) }
            let merged = current.flatMap { $0.merged(for: period) }.map { UsageFormat.forgeCount($0) }
            let issues = current.flatMap { $0.issues(for: period) }.map { UsageFormat.forgeCount($0) }
            let comments = current.flatMap { $0.comments(for: period) }
                .map { UsageFormat.forgeCount($0, atLeast: reading.commentsAreAFloor(for: period)) }
            return ForgeRow(
                id: reading.id,
                kind: reading.kind,
                host: reading.host,
                title: UsageFormat.forgeSectionLabel(name, period: .preset(period)),
                login: reading.login,
                contributions: contributions,
                merged: merged,
                issues: issues,
                comments: comments,
                readAt: reading.hasEverRead ? reading.readAt : nil,
                failure: reading.failure,
                latest: reading.latest,
                tooltip: UsageFormat.forgeTooltip(
                    reading.kind, host: reading.host, login: reading.login, period: .preset(period),
                    boundedToOneYear: reading.activity.contributionsBoundedToOneYear)
                    + (floored ? "\n" + UsageFormat.forgeFloorNote : ""),
                mergedHelp: UsageFormat.forgeMergedHelp(reading.kind),
                issuesHelp: UsageFormat.forgeIssuesHelp(reading.kind),
                commentsHelp: UsageFormat.forgeCommentsHelp(reading.kind),
                actions: makeActions(reading.actions, now: now))
        }
    }

    /// The forge rows over days picked on the calendar, from the forge's own
    /// answer for those days.
    ///
    /// A counter the user switched off is left off the row, as it is under a
    /// preset; one the forge would not answer is the panel's dash, never a
    /// zero. Until the answer lands every row is a dash, and the label says
    /// the forge is being read (`forgeAwaited`). A row the answer names
    /// nothing for, an empty or failed answer included, is a dash with no
    /// such label. The newest event and the month's Actions answer no
    /// window, so they stay the poll's.
    static func makeForgeSpan(
        _ readings: [ForgeActivityReading], span: UsageDaySpan, answer: ForgeSpanAnswer?,
        now: Date
    ) -> [ForgeRow] {
        let matching = answer?.span == span ? answer?.readings ?? [] : []
        let byID = Dictionary(matching.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let shared = Set(Dictionary(grouping: readings, by: \.kind).filter { $0.value.count > 1 }.keys)
        return readings.map { reading in
            let name = shared.contains(reading.kind) ? reading.host : UsageFormat.forgeName(reading.kind)
            let answer = byID[reading.id]
            let login = answer?.login ?? reading.login
            return ForgeRow(
                id: reading.id,
                kind: reading.kind,
                host: reading.host,
                title: UsageFormat.forgeSectionLabel(name, period: .days(span)),
                login: login,
                contributions: answer.flatMap { spanFigure($0.counters[.contributions]) },
                merged: answer.flatMap { spanFigure($0.counters[.merged]) },
                issues: answer.flatMap { spanFigure($0.counters[.issues]) },
                comments: answer.flatMap { spanFigure($0.counters[.comments]) },
                readAt: answer?.readAt,
                failure: answer.flatMap(spanFailure),
                latest: reading.latest,
                tooltip: UsageFormat.forgeTooltip(
                    reading.kind, host: reading.host, login: login, period: .days(span),
                    boundedToOneYear: false),
                mergedHelp: UsageFormat.forgeMergedHelp(reading.kind),
                issuesHelp: UsageFormat.forgeIssuesHelp(reading.kind),
                commentsHelp: UsageFormat.forgeCommentsHelp(reading.kind),
                actions: makeActions(reading.actions, now: now))
        }
    }

    /// The forge rows still waiting on their answer for a picked window,
    /// which their labels word as being read: every row until an answer for
    /// exactly these days has come back, and none after, whatever it held.
    static func forgeAwaited(
        _ rows: [ForgeRow], period: UsageRange, answer: ForgeSpanAnswer?
    ) -> Set<String> {
        guard case .days(let span) = period, answer?.span != span else { return [] }
        return Set(rows.map(\.id))
    }

    private static func spanFigure(_ counter: ForgeSpanCounter?) -> String? {
        switch counter {
        case .counted(let count): UsageFormat.forgeCount(count.value, atLeast: count.isFloor)
        case .unavailable(.switchedOff), nil: nil
        case .unavailable: "—"
        }
    }

    private static func spanFailure(_ answer: ForgeSpanReading) -> ForgeReadFailure? {
        ForgeSpanFeed.counters.lazy.compactMap { metric -> ForgeReadFailure? in
            guard case .unavailable(.failure(let failure)) = answer.counters[metric] else {
                return nil
            }
            return failure
        }.first
    }

    /// The Actions block, nil where there is nothing to draw in it.
    ///
    /// The month's end is read off the reading itself rather than off a gauge,
    /// so a row with no gauge loses last month's minutes too.
    ///
    /// The pace is measured from each owner's own reading rather than the
    /// clock, which is `makePace`'s rule: the bill was true when it was read,
    /// and an owner whose report failed this round is still the last one's. A reading from a
    /// month that has since ended keeps its rows and loses its figures, the
    /// roll-over every limit window is on.
    static func makeActions(_ reading: ActionsReading?, now: Date) -> ActionsBlock? {
        guard let reading else { return nil }
        let quotas = reading.quotas.filter(\.hasUsage)
        let windows: [String: WindowRow] = Dictionary(
            uniqueKeysWithValues: quotas.compactMap { quota in
                guard let percent = quota.usedPercent,
                    let window = UsageWindow(
                        minutes: reading.monthMinutes, usedPercent: percent,
                        resetsAt: reading.resetsAt)
                else { return nil }
                let row = makeWindow(window, observedAt: quota.readAt, reading: .used, now: now)
                return (quota.id, row.labelled(quota.id))
            })
        let bindingID = binding(quotas.compactMap { windows[$0.id] })?.id
        let ended = reading.resetsAt < now
        let rows = quotas.map { quota in
            let window = windows[quota.id]
            let spent = quota.isSpent && !ended
            return ActionsRow(
                id: quota.id,
                window: window,
                minutes: ended ? UsageFormat.actionsNoReading : UsageFormat.actionsMinutes(quota.minutes),
                state: spent || (quota.billed > 0 && !ended)
                    ? UsageFormat.actionsState(quota, resetsAt: reading.resetsAt) : nil,
                stopped: spent && quota.overrun == .stops,
                spender: quota.heaviest.map(UsageFormat.actionsSpender),
                isBinding: bindingID != nil && window?.id == bindingID)
        }
        .sorted(by: leadsActions)
        guard !rows.isEmpty || reading.ownNeedsUserScope else { return nil }
        return ActionsBlock(
            title: UsageFormat.actionsTitle(resetsAt: reading.resetsAt),
            rows: rows,
            scopeNotice: reading.ownNeedsUserScope ? UsageFormat.actionsNeedsUserScope : nil)
    }

    /// The Actions rows in reading order: a live gauge before a rolled-over
    /// one, which `bindsSooner` alone does not exclude, then by the order
    /// `binding` picks from, and a row without a gauge last.
    private static func leadsActions(_ left: ActionsRow, _ right: ActionsRow) -> Bool {
        switch (left.window, right.window) {
        case (let lhs?, let rhs?):
            guard lhs.hasRolledOver == rhs.hasRolledOver else { return !lhs.hasRolledOver }
            return bindsSooner(lhs, rhs)
        case (.some, .none):
            return true
        case (.none, .some), (.none, .none):
            return false
        }
    }
}
