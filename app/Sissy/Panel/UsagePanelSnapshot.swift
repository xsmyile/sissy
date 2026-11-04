import Foundation

/// Everything numeric the usage panel renders, derived from one frame. Pure
/// by construction: no AppKit, no clock, no model access, so the panel's
/// arithmetic — shares, rollups — is testable without a running engine.
///
/// Every number is worded here rather than in a view, so the headline and the
/// rows under it round the same way and a test can hold both.
struct UsagePanelSnapshot: Equatable {
    /// The window `tokens` and `cost` are over. Resolved rather than requested:
    /// a preference naming a period this archive cannot answer falls back to
    /// today instead of rendering a blank, and a picked window needs the
    /// archive switched on to be answered at all.
    let period: UsageRange
    /// The presets the control may offer, `[.today]` alone when there is no
    /// archive behind the others and the control therefore does not appear.
    let periods: [UsagePeriod]
    /// What the archive holds for `period`, nil for the `Today` preset, which
    /// is the live tail's, and for a picked window whose reading has not
    /// landed yet.
    let window: UsageHistoryRollup?
    /// Whether `period` reaches today, which decides whether the rate-limit
    /// gauges belong beside it: a gauge is pressure now, and a window of past
    /// days has no now to be under.
    let includesToday: Bool
    /// The window's cost and tokens, or the panel's dash for a picked window
    /// that has not been read yet and for one whose days hold no file.
    let tokens: String
    let cost: String
    /// Tokens per hour so far today, nil on a day nothing has been spent on and
    /// on every window wider than one: an average over thirty days is not a
    /// pace, and the slot it would take is the one that says how far back the
    /// archive actually reaches.
    let burn: String?
    /// How long a picked window was worked, nil for a preset, whose subline
    /// reads as it did before a window could be picked, and for one the
    /// archive measured no minute of.
    let worked: String?
    /// How far back the archive reaches when it falls short of the window on
    /// screen, nil when it covers it — the control already names the period, so
    /// this speaks only to admit that the number under it is of fewer days than
    /// its name claims.
    let coverage: String?
    let providers: [ProviderRow]
    /// The Overview's gauges: one per vendor, or one per readable account of a
    /// vendor that has more than one.
    ///
    /// An account Sissy cannot read is left out here while it still appears in
    /// the picker. The picker is a list of accounts and this is a list of
    /// readings, and a row with an empty track would report headroom nobody
    /// measured.
    let gaugeRows: [GaugeRow]
    /// One row per provider the window's days name, in place of the gauges
    /// while the window does not reach today. Empty while it does.
    let spendRows: [SpendRow]
    /// The window's days as bars under the headline, nil on a one-day window,
    /// where a single bar is the figure above it drawn as a rectangle, and
    /// before its days have been read.
    let strip: DayStrip?
    /// How many of those rows have spent anything today. The rows themselves
    /// are every provider Sissy is metering — a row is also where a plan, an
    /// account and the rate-limit gauges ride, none of which stop existing
    /// because the day's total is zero.
    let usedToday: Int
    /// The window's spend by project, the busiest first and the tail folded
    /// into one row. Today's live split under the `Today` preset and the
    /// archive's for every other window, presets included: a projects block
    /// reading today under a headline over a week answered two windows at
    /// once. Empty when nothing in the window names a project, and the panel
    /// then draws no section rather than a heading over nothing.
    let projects: [ProjectRow]
    /// How many repositories the day names, which is what the section's own
    /// row offers to open — the fold is a row about the rest of the list and
    /// cannot say how long the list is without being read as a project.
    let projectCount: Int
    /// One row per connected forge, over the same window the headline is on.
    /// Empty until the user connects one, and the panel then draws no section
    /// rather than a heading over nothing.
    let forge: [ForgeRow]

    /// One provider's spend over a window of past days, where its gauges
    /// would be: the window's tokens and cost, and under them its sessions,
    /// sub-agents and worked time, all from the archive's split by provider.
    struct SpendRow: Equatable, Identifiable {
        let id: String
        let name: String
        let spend: String
        let work: String
    }

    /// The Overview's one line about identities, drawn on every frame: it is
    /// the door to the page, and a door that comes and goes with the findings
    /// is one nobody learns is there.
    let identityLine: IdentityLine
    /// What the Mac itself is answering, nil with the module off and before
    /// its first sample: the Overview then draws no line and the page has
    /// nothing to open on.
    let mac: MacBlock?

    /// What the disks answer, nil with the module off and before its first
    /// read, and the Disk tab is then not drawn.
    let disk: DiskBlock?

    /// One day of a provider's recent spend, as a bar on its page.
    ///
    /// `cost` is optional and that is the whole point of the type: a day the
    /// archive holds nothing for is a day Sissy was not running, which is the
    /// absence of a reading rather than a reading of zero. Drawn as a zero-height
    /// bar it would be a claim that nothing was spent, made out of Sissy's own
    /// downtime.
    struct DayRow: Equatable, Identifiable {
        let id: String
        /// The weekday, or `Today` for the day the frame is answering for.
        let label: String
        let isToday: Bool
        let cost: Decimal?
        /// Of the tallest bar in the strip, so the shape is readable without
        /// an axis. Zero for a day with no reading and for a day that spent
        /// nothing.
        let fraction: Double
        /// The day named, which the header takes while the pointer is on this
        /// bar.
        let title: String
        /// What the day cost, or why there is nothing to name. The strip has
        /// no axis, so this is where a value is read.
        let figures: String
        /// That day's split by model, as the pills under the strip draw it
        /// while the pointer is on this bar.
        ///
        /// On the row rather than fetched when the pointer arrives: the whole
        /// series is already decoded and folded by the time the strip exists,
        /// so a lookup on hover would be a second read of the same bytes at
        /// the one moment the user is waiting. Empty for a day the archive has
        /// no file for, which is a bar the strip still draws — an absent
        /// reading is not a reading of zero, and the pills say nothing rather
        /// than keeping the last day that had some.
        let models: [ModelRow]
        /// The days a click on this bar reads, nil on a strip that is a
        /// picture rather than a way in. A day, or the week, month or year a
        /// wide window's bar stands for.
        let span: UsageDaySpan?
    }

    /// A provider's recent days, with the window they cover named.
    struct DayStrip: Equatable {
        let rows: [DayRow]
        /// `Last 7 days`, or the day the archive starts on plus how much of
        /// the window it actually covers.
        let label: String
        let total: String
    }

    /// The archive's reading of the days a period covers, with the strip
    /// drawn from it.
    ///
    /// The strip is made here, once, when the reading lands, rather than by
    /// `make` on every frame the panel draws: `All` over an archive kept for
    /// years is thousands of days, and each one formatted per frame was a
    /// cost paid for a reading that had not changed.
    struct SpanAnswer: Equatable {
        /// The period the reading was asked for, which names the strip and
        /// tells two presets over the same days apart.
        let period: UsageRange
        let reading: UsageSpanReading
        let strip: DayStrip?

        init(
            _ reading: UsageSpanReading, period: UsageRange, now: Date = Date(),
            calendar: Calendar = .current
        ) {
            self.period = period
            self.reading = reading
            guard case .days(let span) = reading.rollup.period else {
                strip = nil
                return
            }
            strip = windowStrip(
                reading, span: span, named: UsageFormat.periodHeading(period, now: now, calendar: calendar),
                now: now, calendar: calendar)
        }
    }

    /// How many bars the strip draws, and how many days its reader asks for.
    ///
    /// It lived on `UsageEngine` while the engine rolled a fixed week up for
    /// the Overview's archive row. That row is gone and the headline's windows
    /// are the user's choice now, so the only thing this still decides is how
    /// wide a strip of bars reads — which is the panel's call, and its two
    /// callers are both on this side of the engine.
    static let dayStripDays = 7

    /// The strip for one provider: the archive for every day before today, and
    /// today from the frame.
    ///
    /// **Today's pills are handed in rather than rebuilt.** They are the same
    /// rows the page is already drawing under the bars, so recomputing them
    /// from the slice would be a second derivation of one reading and a second
    /// place for the last bar to disagree with the block beside it.
    ///
    /// **Today never comes from the archive.** Both are the same tail reading
    /// the same events — `LocalUsageProvider.ingest` feeds the day buckets and
    /// the day file from one `UsageEvent` — but the file is written on a
    /// throttle while the frame is emitted as events land. Taking today from
    /// disk would print a bar that disagrees with the `Today` row on the same
    /// page for as long as the throttle holds.
    ///
    /// Nil until the archive reaches past today, for the reason the archive
    /// row carried before it: a strip whose only bar is today is the figure
    /// above it drawn as a rectangle.
    ///
    /// The window is applied here as well as by the reader, so the total under
    /// the label is the bars above it summed. A day older than the window has
    /// no bar to appear in, and counting it would put money on the label that
    /// nothing on screen accounts for.
    static func dayStrip(
        series: [UsageHistoryDaySummary],
        provider: String,
        todayTokens: Int,
        todayCost: Decimal,
        todayModels: [ModelRow],
        days: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> DayStrip? {
        let today = calendar.startOfDay(for: now)
        let start = UsagePeriod.start(days: days, now: now, calendar: calendar) ?? today
        let past = series.filter {
            let day = calendar.startOfDay(for: $0.day)
            return day >= start && day < today
        }
        guard days > 0, !past.isEmpty else { return nil }
        let archived = Dictionary(
            past.map { (calendar.startOfDay(for: $0.day), $0) },
            uniquingKeysWith: { _, last in last })
        let peak = max(past.map(\.cost).max() ?? 0, todayCost)

        let rows: [DayRow] = (0..<days).reversed().compactMap { back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            let isToday = back == 0
            let tokens = isToday ? todayTokens : archived[day]?.tokens
            let cost: Decimal? = isToday ? todayCost : archived[day]?.cost
            let models =
                isToday
                ? todayModels
                : makeModels(
                    archived[day]?.models ?? [], provider: provider,
                    totalCost: cost ?? 0, totalTokens: tokens ?? 0)
            return DayRow(
                id: UsageReaderShared.dayFormatter.string(from: day),
                label: isToday ? "Today" : day.formatted(.dateTime.weekday(.abbreviated)),
                isToday: isToday,
                cost: cost,
                fraction: Self.share(cost, of: peak),
                title: UsageFormat.dayTitle(day),
                figures: UsageFormat.dayFigures(tokens: tokens, cost: cost),
                models: models,
                span: nil)
        }
        let covered = rows.count { $0.cost != nil }
        return DayStrip(
            rows: rows,
            label: UsageFormat.dayStripLabel(
                days: days, covered: covered,
                earliestDay: past.map(\.day).min(), now: now, calendar: calendar),
            total: UsageFormat.cost(past.reduce(todayCost) { $0 + $1.cost }))
    }

    private static func share(_ value: Decimal?, of peak: Decimal) -> Double {
        guard let value, peak > 0, value > 0 else { return 0 }
        return min(
            NSDecimalNumber(decimal: value).doubleValue
                / NSDecimalNumber(decimal: peak).doubleValue, 1)
    }

    /// The window a provider is closest to running out of, or nil when it
    /// reports none.
    ///
    /// The rate decides it, not the reading: a window the pace empties before
    /// its own reset binds, soonest first, and one that survives its reset
    /// does not bind at all however full it is. The percentage is the
    /// fallback, for the windows that carry no projection — too young to
    /// extrapolate from, or never started — and there the most spent leads.
    /// A tie in either group goes to the shorter period, which is the one met
    /// sooner.
    ///
    /// Emphasis and caption were on two different axes before, which is what
    /// made the block unreadable: the row was chosen on its percentage while
    /// its own caption spoke in pace, so a session at 40% that lasts until
    /// reset outranked a weekly at 35% running out in two days — the window
    /// the user actually meets, drawn quiet under one that never binds.
    ///
    /// A window that has rolled over since the reading is not a candidate: its
    /// percentage measures a period that has ended, and both things this
    /// chooses for — the emphasis on the page and the Overview's one gauge —
    /// would then report it as the pressure a user is under now. With every
    /// window rolled over there is no binding one, which is the dash the
    /// Overview already draws for a provider that has answered nothing.
    static func binding(_ windows: [WindowRow]) -> WindowRow? {
        windows.filter { !$0.hasRolledOver }.min(by: bindsSooner)
    }

    static func bindsSooner(_ lhs: WindowRow, _ rhs: WindowRow) -> Bool {
        switch (lhs.pace?.runsOutAt, rhs.pace?.runsOutAt) {
        case (let left?, let right?):
            return left == right ? lhs.minutes < rhs.minutes : left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return lhs.percent == rhs.percent
                ? lhs.minutes < rhs.minutes : lhs.percent > rhs.percent
        }
    }

    /// One gauge on the Overview: a vendor, or a vendor's account once there
    /// is more than one worth drawing.
    ///
    /// The Overview answers whether there is room to keep working, and with
    /// two accounts that question has two answers — the whole point of linking
    /// a second one is seeing 100% and 20% side by side rather than finding
    /// out after switching. So the row is per readable account, and the name
    /// is qualified only then: one account keeps the vendor's plain name and
    /// no track gets shorter for a qualifier nobody needed.
    ///
    /// Carries no money, which is not an omission. A log line names no
    /// account, so the day belongs to the config home and cannot be split; the
    /// Overview's block has answered pressure and nothing else since 0.2.0.
    struct GaugeRow: Equatable, Identifiable {
        let id: String
        /// Which page this opens, which is the vendor's — an account is a
        /// reading on that page rather than a page of its own.
        let provider: String
        /// Which of that vendor's accounts this row reads, so the page opens
        /// on the one that was clicked. Nil for a vendor drawing one row,
        /// where the page's own fields are already that account's.
        let account: String?
        /// The vendor's own name, which is what a degraded status colours.
        let name: String
        /// Which of the vendor's accounts this row is, for a vendor drawing
        /// more than one: the account's name as `AccountNaming` words it,
        /// which by default is a team seat's organisation and a personal
        /// plan's owner. Nil for a vendor drawing one row.
        let qualifier: String?
        /// How many accounts the vendor's picker lists, for the count over a
        /// vendor drawing more than one row. Not how many rows it draws: an
        /// account with no reading has no row and is still one of the vendor's.
        var accountCount: Int = 1
        /// The account's reading. Its plan is the badge a row under a vendor's
        /// label carries, so it is nil for a vendor drawing one row, whose plan
        /// is on its page.
        let reading: AccountReading
        let status: StatusRow?

        /// The row as one string, `Claude · Acme Srl`, for the hover and the
        /// accessibility label that name it whole.
        var title: String {
            qualifier.map { "\(name) · \($0)" } ?? name
        }
    }

    /// What the panel reads about one account, whichever row carries it: an
    /// entry in a vendor's list, the vendor's own row while it has one account,
    /// or a gauge on the Overview.
    struct AccountReading: Equatable {
        /// Subscription plan, already worded. Nil leaves the row's header at
        /// the name alone: an API-key user has no plan to name, and a Codex
        /// that has not taken a turn yet has not said which it is on.
        var plan: String?
        /// Limit tier, worded, and only when it is not already part of
        /// `plan`: a seat metered at a tier of another plan. It goes to the
        /// tooltip: the badge is for the plan the user pays for.
        var planTier: String?
        /// Shortest window first. Empty when the account reports none, which
        /// its page answers with a sentence rather than a blank block.
        var windows: [WindowRow] = []
        /// When those windows were taken, worded. Nil when there are none, and
        /// when the provider published them without saying: a gauge with an
        /// invented age would be worse than one with none.
        var windowsCaption: String?
        /// What to say and offer when the limits are missing for a reason the
        /// user can act on. Nil the rest of the time, which is most of it.
        var notice: LimitsNotice?
        /// What the vendor has billed against a spend cap, worded. Nil for a
        /// provider that publishes none and for an account with nothing to
        /// say: no cap set and nothing spent, which is every account that
        /// has never turned credits on.
        var credits: CreditsRow?
        /// The resets the vendor lets this account spend on its windows. Nil
        /// for a provider that offers none, and for an account that holds none.
        var resets: ResetsRow?
        /// Whose credential a reset press on this account spends, nil for a
        /// provider that offers none. Beside the row rather than on it, because
        /// the press that spends the last reset takes the row away, and its
        /// answer still has to be said somewhere.
        var resetTarget: LimitResetTarget?
        /// How many running sessions are on this account.
        var runningSessions: Int = 0
    }

    /// One account of a vendor, as the panel knows it.
    ///
    /// Two things make an account appear here and they are not the same thing.
    /// Sissy can **read** an account it holds a live source for: the CLI's own
    /// credential for whoever is signed in, a linked claude.ai session for
    /// anyone else. And it **knows of** an account it has seen signed in.
    ///
    /// So a known account with no session linked gets a row with no gauges:
    /// Sissy knows who it is and cannot say a thing about its limits until a
    /// session is linked. Leaving it out would hide the account the user most
    /// wants to link.
    struct AccountEntry: Equatable, Identifiable {
        let id: String
        /// What the picker calls it, and what qualifies the Overview's row
        /// once there is more than one: the name `AccountNaming` gives it, or
        /// its id where the vendor answered for nothing that names it.
        let label: String
        /// The address and organisation the label leaves out, for the line
        /// under it on the provider page.
        let detail: String?
        /// Its windows are empty for an account Sissy cannot read.
        let reading: AccountReading
        /// Whether Sissy has a source for this account at all. False is an
        /// invitation to link one rather than a failure to report.
        let isReadable: Bool
        /// Whether the CLI itself is signed in as this account — the one whose
        /// future spend lands in the day beside it.
        let isSignedIn: Bool
    }

    struct ProviderRow: Equatable, Identifiable {
        let id: String
        let name: String
        /// Every account of this vendor the panel knows. Empty when there is
        /// one, which is most installs — a picker over a single choice is a
        /// control that does nothing, and `reading` is that one account's
        /// anyway.
        let accounts: [AccountEntry]
        /// Why accounts the picker used to list may be missing, worded. Nil
        /// the rest of the time, which is every install whose account index
        /// has always read.
        let accountsNotice: String?
        /// The reading of the account this row's identity names, for an install
        /// with one account, whose `accounts` is empty.
        let reading: AccountReading
        let tokens: String
        let cost: String
        /// Who this provider is signed in as, worded. Nil when its own files
        /// name nobody.
        let account: AccountRow?
        /// This provider's own share of the day by project, folded the same
        /// way the combined list is. Empty for a provider whose format names
        /// no working directory.
        let projects: [ProjectRow]
        /// How many repositories this provider's day names, for the row that
        /// opens the unfolded list.
        let projectCount: Int
        /// This provider's own day by model, dearest first and never folded,
        /// as the pills under the strip. One model is one pill; empty means
        /// the provider has read nothing.
        let models: [ModelRow]
        /// Today's `(model, effort)` pairs, raw. Raw because the page folds
        /// them together with the archived days the strip draws, and a slice
        /// carrying a pre-shared row could not be added to another day's.
        let effort: [EffortSplit]
        /// What the vendor's own status page last said. Nil while the readings
        /// are switched off and for a provider with no feed to poll, which is
        /// what leaves the row off the page rather than putting an empty one
        /// on it.
        let status: StatusRow?
    }

    /// A vendor's own status, as the provider page prints it.
    ///
    /// The indicator travels raw beside the worded label because it is the one
    /// field a surface reads rather than shows: it picks the dot's colour, and
    /// it decides whether the Overview colours that provider's name at all.
    struct StatusRow: Equatable, Sendable {
        let indicator: ProviderStatusIndicator
        /// The vendor's own sentence, or Sissy's own when there is no reading.
        let label: String
        /// When Sissy read it, left for the view to word on its own clock: the
        /// monitor emits nothing while a vendor keeps saying the same thing,
        /// so an age frozen into this value would stop moving under an open
        /// panel. Nil for a feed that has never answered — an age there would
        /// date a fetch that produced no reading as though it were one.
        let checkedAt: Date?
        /// The vendor's own services, in the vendor's own order and nesting.
        /// Empty leaves the row closed and without a disclosure, which is what
        /// a feed whose component list could not be read looks like.
        let components: [ComponentRow]
        /// The page these rows are a copy of, for the one question the copy
        /// deliberately cannot answer: what actually happened, and when.
        let page: URL?
    }

    /// One service on a vendor's status page, or a group of them.
    struct ComponentRow: Equatable, Identifiable, Sendable {
        let id: String
        let name: String
        /// Kept raw beside the worded status because it picks the dot's
        /// colour, which is the one thing about this row that is read rather
        /// than shown.
        let indicator: ProviderStatusIndicator
        /// The vendor's own status, worded.
        let status: String
        let children: [ComponentRow]

        var isGroup: Bool { !children.isEmpty }
    }

    /// The credits block of a provider's page: what has been charged against
    /// the user's own cap, in the account's currency.
    ///
    /// Worded here rather than in the view for the reason every other row is
    /// — the arithmetic and the wording are what a test can hold — and kept
    /// apart from the day's cost, which is Sissy's estimate of the tokens
    /// rather than the vendor's charge.
    struct CreditsRow: Equatable {
        /// `€58.95 of €100.00`, the spend alone when no cap is set, or the
        /// balance for a vendor that answers only for what is left.
        let amount: String
        /// Absent without a cap: a percentage of no ceiling is not a number.
        let percent: Int?
        /// Absent for the same reason, and the bar goes with it — drawing one
        /// at zero against no ceiling is inventing the denominator the row was
        /// built not to invent.
        let fraction: Double?
        /// What is left, when the cap says, and when the reading was taken.
        let caption: String
        /// True once the cap is reached, which is the one state on this row
        /// worth a colour — it is headroom running out, not a verdict on how
        /// much was spent.
        let capReached: Bool
    }

    /// The resets block of a provider's page: how many the account holds, when
    /// the soonest lapses, and whether the vendor counts one as needed now.
    struct ResetsRow: Equatable {
        /// `1 available`, the vendor's own count.
        let headline: String
        /// The vendor's name for the soonest reset and when it lapses.
        let caption: String
        /// Whether the vendor counts one as needed now. False keeps the button
        /// and says so in the confirmation: on 2026-10-02 an account at 100% of
        /// its session and 79% of its week found the button gone, which only an
        /// applicable count of zero did, and so had no way to spend the reset
        /// it held.
        let appliesNow: Bool
        /// How many a press is spending from, for the confirmation's arithmetic.
        let available: Int
        /// The windows the reset puts back to zero, by the label the page gives
        /// them, shortest first. Empty where the vendor does not say, which the
        /// confirmation words as both.
        let clears: [String]
    }

    /// An account as the provider page prints it: its name on its own line,
    /// and under it whatever of the address and the organisation the name
    /// leaves out.
    ///
    /// The seat is deliberately absent — `UsageFormat.plan` has already
    /// folded it into the badge for the one vendor that publishes one, and a
    /// line repeating what the badge above it says is a line nobody reads.
    struct AccountRow: Equatable {
        let name: String
        let detail: String?
    }

    /// A limits problem worded, with whether a refresh can do anything about
    /// it.
    ///
    /// The two halves are separate because they do not always agree: a
    /// refusal is worth saying and worth retrying, an unsigned CLI is worth
    /// saying and Sissy cannot fix it from here.
    struct LimitsNotice: Equatable {
        let message: String
        /// Title for the control beside it, nil when there is nothing this
        /// app can do.
        let action: String?
        /// What that control does. A claude.ai session the vendor has closed
        /// is not something a refresh can revive — the account is linked
        /// again, in the window that linked it — where every other notice is
        /// asking for the reading to be attempted once more.
        let kind: Kind

        enum Kind: Equatable {
            case refresh
            case link
        }
    }

    /// One rate-limit gauge. `fraction` is clamped for the bar while
    /// `percent` is not, so a window past 100% still reads as what it is.
    struct WindowRow: Equatable, Identifiable {
        /// Period and scope together: a vendor can publish a weekly window
        /// for everything and a weekly window for one model, and the period
        /// alone would make them one row.
        let id: String
        /// The period the window measures. Carried beside the id because the
        /// id is no longer a duration: two windows of the same length are
        /// told apart by scope, and the tie between them is still broken by
        /// which period binds sooner.
        let minutes: Int
        let label: String
        /// The vendor's own figure, raw and always the *used* end of the
        /// window. It is what `binding` orders on and what the Overview turns
        /// orange, neither of which may move because the user chose to read
        /// the gauge from the other end.
        let percent: Int
        /// That figure as the row prints it, which is the end the user chose.
        let reading: String
        /// The same, with the noun that names the end, for the tooltip.
        let readingSentence: String
        let fraction: Double
        /// Nil for a window the vendor has not started, which is a bar at
        /// zero with nothing to count down to.
        let resetsAt: Date?

        /// A window nothing has been spent in and no reset is named for, which
        /// is one the vendor starts on the first message. Spend without a
        /// reset is a reading missing its date rather than a window waiting.
        var isUnstarted: Bool { resetsAt == nil && fraction == 0 }
        /// Nil in the window's first minutes, where the projection is noise.
        let pace: Pace?
        /// Whether the period turned over after the vendor last answered for
        /// it, which makes every figure on this row describe a period that has
        /// ended.
        ///
        /// The row is kept and drawn without a reading rather than dropped:
        /// Codex answers only on its own turns, so dropping it took the
        /// session row off the page for as long as nobody used the CLI. It is
        /// drawn without a bar for the reason the Overview draws a dash — an
        /// empty gauge is a measurement, and this is the absence of one.
        ///
        /// Strictly past the reset, never on it. A reading taken at the very
        /// instant a period ends is the one case where withholding it would be
        /// guessing at a roll-over rather than observing one, and the panel
        /// already has a shape for a window with nothing left to project
        /// from — the percentage, with no pace under it.
        let hasRolledOver: Bool
    }

    /// Where even consumption would have put this window by now, and what the
    /// rate so far does to it.
    ///
    /// A percentage says where you are; it does not say whether that is ahead
    /// of where you should be, which is the thing that decides whether to keep
    /// working. All of it is arithmetic over what `UsageWindow` already
    /// carries, so the mark costs no new source, no permission and nothing
    /// persisted.
    struct Pace: Equatable {
        /// Fraction of the bar the mark sits at — `elapsed / duration`, which
        /// is where `usedPercent` would be had the window been spent evenly.
        let expectedFraction: Double
        /// `usedPercent − expected`, rounded and signed. Positive is spending
        /// faster than the window refills, which is what colours the mark.
        let deltaPercent: Int
        /// When the rate so far exhausts the window, or nil when it does not
        /// before the reset.
        let runsOutAt: Date?

        var isOverPace: Bool { deltaPercent > 0 }
    }

    /// The snapshot for `frame` over `period`.
    ///
    /// `span` is the archive's reading of the days `windowSpan` names for the
    /// period, with the strip drawn from it, fetched by the panel while it is
    /// open and handed in rather than read here: it is what a picked window's
    /// headline is and what any window's strip is. An answer for another
    /// period or other days is ignored, so a reply that lands after the
    /// period moved cannot answer for the new one. `forgeSpan` is the forge's
    /// answer for a picked window, by the same rule.
    ///
    /// `archiveKept` is whether the archive is switched on, which the frame
    /// cannot say: it carries no windows both while the archive is off and
    /// in the moment after launch before the engine's first rollup lands.
    /// With the archive on, a chosen window is kept through that moment and
    /// reads as the dash rather than as today's figure under its name.
    static func make(
        frame: FrameData,
        period: UsageRange = .preset(.today),
        archiveKept: Bool = false,
        span: SpanAnswer? = nil,
        forgeSpan: ForgeSpanAnswer? = nil,
        claudeAccounts: ClaudeAccountRegistry.Snapshot = .init(),
        limitsReading: LimitsReading = .used,
        accountNaming: AccountNaming = AccountNaming(),
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Self {
        let totalCost = frame.providers.reduce(Decimal(0)) { $0 + $1.cost }
        let rows = makeRows(
            frame.providers, claudeAccounts: claudeAccounts, status: frame.providerStatus,
            limitsReading: limitsReading, naming: accountNaming, now: now)
        let periods = availablePeriods(frame.history)
        let resolved = resolve(period, periods: periods, archiveKept: archiveKept)
        let days = windowSpan(
            resolved, earliest: frame.history[.all]?.earliestDay, now: now, calendar: calendar)
        let answer = span.flatMap {
            $0.period == resolved && days.map(UsageRange.days) == $0.reading.rollup.period ? $0 : nil
        }
        let reading = answer?.reading
        let window: UsageHistoryRollup? =
            switch resolved {
            case .preset(.today): nil
            case .preset(let preset): frame.history[preset]
            case .days: reading?.rollup
            }
        let isToday = resolved == .preset(.today)
        let unread =
            resolved.isPicked ? reading?.hasReading != true : !isToday && window == nil
        let includesToday = resolved.includesToday(now: now, calendar: calendar)
        return Self(
            period: resolved,
            periods: periods,
            window: window,
            includesToday: includesToday,
            tokens: unread ? "—" : UsageFormat.tokens(window?.tokens ?? frame.tokens),
            cost: unread ? "—" : UsageFormat.cost(window?.cost ?? frame.cost),
            burn: isToday ? frame.burn.map(UsageFormat.burn) : nil,
            worked: !resolved.isPicked
                ? nil
                : window.flatMap {
                    $0.activity.activeMinutes > 0
                        ? UsageFormat.workedDuration(minutes: $0.activity.activeMinutes) + " active"
                        : nil
                },
            coverage: window.flatMap {
                UsageFormat.periodCoverage(
                    $0, archiveStart: frame.history[.all]?.earliestDay, now: now,
                    calendar: calendar)
            },
            providers: rows,
            gaugeRows: makeGaugeRows(rows),
            spendRows: includesToday ? [] : window.map(makeSpendRows) ?? [],
            strip: answer?.strip,
            usedToday: frame.providers.count { $0.tokens > 0 },
            projects: isToday
                ? makeProjects(frame.projects, totalCost: totalCost)
                : makeProjects(window?.projects ?? [], totalCost: window?.cost ?? 0),
            projectCount: isToday ? frame.projects.count : window?.projects.count ?? 0,
            forge: {
                switch resolved {
                case .preset(let preset): makeForge(frame.forge, period: preset, now: now)
                case .days(let picked):
                    makeForgeSpan(frame.forge, span: picked, answer: forgeSpan, now: now)
                }
            }(),
            identityLine: makeIdentityLine(frame.identities),
            mac: frame.mac.map(makeMac),
            disk: frame.disk.map(makeDisk)
        )
    }

    /// The period the panel can answer: a preset the archive carries, a
    /// picked window while there is an archive to read it from, and today
    /// otherwise.
    ///
    /// A frame carrying no window at all with the archive kept is one whose
    /// rollups have not landed yet, so the chosen window stands and its figure
    /// waits; a frame carrying some windows but not the chosen one answers
    /// for an archive that cannot reach it, and falls back.
    static func resolve(
        _ period: UsageRange, periods: [UsagePeriod], archiveKept: Bool = false
    ) -> UsageRange {
        let pending = archiveKept && periods.count == 1
        switch period {
        case .preset(let preset):
            return periods.contains(preset) || pending ? period : .preset(.today)
        case .days:
            return periods.count > 1 || archiveKept ? period : .preset(.today)
        }
    }

    /// The days a period covers, which is what the panel asks the archive for
    /// to draw its strip and, for a picked window, its headline. `All` starts
    /// on the first day the archive holds.
    static func windowSpan(
        _ period: UsageRange, earliest: Date?, now: Date, calendar: Calendar = .current
    ) -> UsageDaySpan? {
        switch period {
        case .days(let span):
            return span
        case .preset(let preset):
            let start = preset.start(now: now, calendar: calendar) ?? earliest ?? now
            return UsageDaySpan(from: start, to: now, now: now, calendar: calendar)
        }
    }

    /// One row per provider the window names, in the panel's provider order.
    private static func makeSpendRows(_ window: UsageHistoryRollup) -> [SpendRow] {
        Set(window.spendByProvider.keys).union(window.agentsByProvider.keys)
            .sorted {
                (FrameBuilder.providerSortOrder($0), $0) < (FrameBuilder.providerSortOrder($1), $1)
            }
            .map { id in
                let spend = window.spendByProvider[id] ?? UsageSpend()
                return SpendRow(
                    id: id,
                    name: UsageFormat.providerName(id),
                    spend: UsageFormat.providerSpend(tokens: spend.tokens, cost: spend.cost),
                    work: UsageFormat.providerWork(
                        window.agentsByProvider[id] ?? .none,
                        activity: window.activityByProvider[id] ?? .none))
            }
    }

    /// The window's days as bars, one per day from its first to its last,
    /// summed across providers, a stretch with no file drawn as the strip's
    /// dot.
    ///
    /// Read off the archive for every day, today included, so the bars sum to
    /// the headline over the same window rather than to a figure read
    /// somewhere else. Weekdays label the bars while a week's worth fits under
    /// them (`DayBarGeometry`'s measurement); a wider strip names its days on
    /// hover alone.
    ///
    /// **A bar a day for as long as `DayBarGeometry.maxBars` days fit**, and
    /// past that a bar per week, then per month, then per year, whichever is
    /// the shortest that fits: a strip of years drawn a day at a time is bars
    /// narrower than the dot for a day with no reading, and a hover target
    /// for each. The first and last bar cover only the days of their week or
    /// month the window holds, and the hover names exactly those days.
    static func windowStrip(
        _ reading: UsageSpanReading, span: UsageDaySpan, named name: String,
        now: Date = Date(), calendar: Calendar = .current
    ) -> DayStrip? {
        let count = span.dayCount(calendar: calendar)
        guard count > 1 else { return nil }
        let unit = stripUnit(span, count: count, now: now, calendar: calendar)
        let buckets = stripBuckets(span, by: unit, now: now, calendar: calendar)
        let bucketStart = { (day: Date) -> Date in
            max(calendar.dateInterval(of: unit, for: day)?.start ?? day, span.from)
        }
        var sums: [Date: (tokens: Int, cost: Decimal)] = [:]
        var filed = Set<Date>()
        for total in reading.days where span.contains(total.day) {
            filed.insert(calendar.startOfDay(for: total.day))
            let sum = sums[bucketStart(total.day), default: (0, 0)]
            sums[bucketStart(total.day)] = (sum.tokens + total.tokens, sum.cost + total.cost)
        }
        let peak = sums.values.map(\.cost).max() ?? 0
        let labelled = count <= dayStripDays
        let rows: [DayRow] = buckets.map { bucket in
            let sum = sums[bucket.from]
            let isToday = bucket.includesToday(now: now, calendar: calendar)
            return DayRow(
                id: UsageReaderShared.dayFormatter.string(from: bucket.from),
                label: !labelled
                    ? "" : isToday ? "Today" : bucket.from.formatted(.dateTime.weekday(.abbreviated)),
                isToday: isToday,
                cost: sum?.cost,
                fraction: share(sum?.cost, of: peak),
                title: UsageFormat.stripBucketTitle(bucket, unit: unit, now: now, calendar: calendar),
                figures: UsageFormat.dayFigures(tokens: sum?.tokens, cost: sum?.cost),
                models: [],
                span: bucket)
        }
        return DayStrip(
            rows: rows,
            label: UsageFormat.spanStripLabel(name, covered: filed.count, days: count),
            total: UsageFormat.cost(sums.values.reduce(Decimal(0)) { $0 + $1.cost }))
    }

    /// The shortest stretch a bar can stand for and still fit the strip.
    /// Years are the last resort and are taken however many there are.
    private static func stripUnit(
        _ span: UsageDaySpan, count: Int, now: Date, calendar: Calendar
    ) -> Calendar.Component {
        guard count > DayBarGeometry.maxBars else { return .day }
        return [Calendar.Component.weekOfYear, .month].first {
            stripBuckets(span, by: $0, now: now, calendar: calendar).count <= DayBarGeometry.maxBars
        } ?? .year
    }

    /// `span` cut at every boundary of `unit`, oldest first, the first and
    /// last piece clipped to the window.
    private static func stripBuckets(
        _ span: UsageDaySpan, by unit: Calendar.Component, now: Date, calendar: Calendar
    ) -> [UsageDaySpan] {
        var buckets: [UsageDaySpan] = []
        var start = span.from
        while start <= span.to,
            let interval = calendar.dateInterval(of: unit, for: start),
            let last = calendar.date(byAdding: .day, value: -1, to: interval.end),
            let bucket = UsageDaySpan(from: start, to: min(last, span.to), now: now, calendar: calendar)
        {
            buckets.append(bucket)
            start = interval.end
        }
        return buckets
    }

    /// Which windows the panel's period may be put over: today, which needs no
    /// archive, and each of the rest the frame actually carries a total for.
    /// The header's control reads it too, so it offers what the headline can
    /// answer.
    ///
    /// Read off the keys rather than from whether the frame sent anything at
    /// all. The engine sends all of them or none, so the difference is invisible
    /// in production — but taking a window the frame cannot answer as available
    /// falls it back to today's number while the control still reads `All`,
    /// which is a wrong label on a right number and the worst of the outcomes
    /// here. Today alone is both the archive switched off and a fresh install,
    /// and then there is no control at all: four windows that all answer the
    /// number already on screen are a feature rather than a reading.
    static func availablePeriods(_ history: [UsagePeriod: UsageHistoryRollup])
        -> [UsagePeriod]
    {
        [.today] + UsagePeriod.archived.filter { history[$0] != nil }
    }

    /// One row per vendor.
    ///
    /// A vendor is one CLI and one reading: Sissy meters the config home the
    /// CLI writes to, and a log line carries no account id, so the spend is the
    /// CLI's rather than an account's. What the account decides is the identity
    /// on the row and the limits under it, both of which come from the
    /// credential that is signed in, and `accounts` is the list of the others
    /// Sissy has seen, which is a property of its index rather than of the
    /// frame.
    private static func makeRows(
        _ slices: [ProviderSlice],
        claudeAccounts: ClaudeAccountRegistry.Snapshot,
        status: [String: ProviderStatusReading],
        limitsReading: LimitsReading,
        naming: AccountNaming,
        now: Date
    ) -> [ProviderRow] {
        slices.map { slice in
            let known =
                slice.id == ProviderID.claudeCode ? claudeAccounts : ClaudeAccountRegistry.Snapshot()
            let source = RowSource(soleRunning: slice, known: known) ?? RowSource(slice)
            let plan = UsageFormat.plan(
                source.plan, tier: source.planTier, seat: source.account?.seat,
                name: source.planName)
            return ProviderRow(
                id: slice.id,
                name: UsageFormat.providerName(slice.id),
                accounts: accountEntries(
                    readings: slice.signals.accounts,
                    // The index of accounts seen signed in is Claude Code's
                    // alone: an account Codex holds no reading for is an
                    // account it holds nothing for.
                    known: known,
                    provider: slice.id,
                    reading: limitsReading, naming: naming, now: now),
                accountsNotice: slice.id == ProviderID.claudeCode && claudeAccounts.indexSetAside
                    ? ClaudeAccountCopy.indexSetAside : nil,
                reading: AccountReading(
                    plan: plan,
                    windows: source.windows,
                    observedAt: source.observedAt,
                    captionedAt: source.windows.isEmpty ? nil : source.observedAt,
                    projecting: !source.isCached,
                    notice: source.windows.isEmpty || !source.isCached
                        ? UsageFormat.limitsNotice(slice.limitsState, provider: slice.id) : nil,
                    credits: source.credits,
                    resets: slice.resets,
                    resetTarget: rowResetTarget(provider: slice.id, slice.signals.accounts),
                    runningSessions: source.runningSessions,
                    limitsReading: limitsReading,
                    now: now),
                tokens: UsageFormat.tokens(slice.tokens),
                cost: UsageFormat.cost(slice.cost),
                account: makeAccount(
                    source.account, id: source.id,
                    plan: source.plan, naming: naming),
                projects: makeProjects(slice.projects, totalCost: slice.cost),
                projectCount: slice.projects.count,
                models: makeModels(
                    slice.models, provider: slice.id, totalCost: slice.cost,
                    totalTokens: slice.tokens),
                effort: slice.effort,
                status: makeStatus(status[slice.id], provider: slice.id)
            )
        }
    }

    /// What a row's own fields read: the slice, or the one account a running
    /// home names when that account is all there is.
    ///
    /// A single account draws no picker, so `accountEntries` answers with none
    /// and the page and the Overview read the row's fields alone. Those are the
    /// metered home's, which names nobody for a user running Claude Code only
    /// under `CLAUDE_CONFIG_DIR`, and the account would vanish with its count and
    /// its gauges. It never counts as signed in to the metered home.
    private struct RowSource {
        let plan: String?
        let planTier: String?
        let planName: String?
        let account: ProviderAccount?
        let windows: [UsageWindow]
        let observedAt: Date?
        let credits: ProviderCredits?
        /// Whether the windows are a running home's cached reply.
        let isCached: Bool
        /// The account a rename of this row is kept by.
        let id: String?
        let runningSessions: Int

        init(_ slice: ProviderSlice) {
            plan = slice.plan
            planTier = slice.planTier
            planName = slice.planName
            account = slice.account
            windows = slice.windows
            observedAt = slice.limitsObservedAt
            credits = slice.credits
            isCached = false
            let own = slice.signals.accounts.filter { !$0.isOnlyRunning }
            let ownID = soleAccountID(own)
            id = ownID
            runningSessions = own.first { $0.id == ownID }?.runningSessions ?? 0
        }

        /// Only over a slice with nothing of its own. One that names an account
        /// or holds a reading has no id to say so with where the file predates
        /// `accountUuid`, and the running account is not that one.
        init?(soleRunning slice: ProviderSlice, known: ClaudeAccountRegistry.Snapshot) {
            let accounts = slice.signals.accounts
            guard accounts.count == 1, let only = accounts.first, only.isOnlyRunning,
                known.accounts.allSatisfy({ $0.uuid == only.id }),
                slice.account == nil, slice.plan == nil, slice.windows.isEmpty
            else { return nil }
            plan = only.plan
            planTier = only.planTier
            planName = only.planName
            account = only.account
            windows = only.windows
            observedAt = only.limitsObservedAt
            credits = only.credits
            isCached = true
            id = only.id
            runningSessions = only.runningSessions
        }
    }

    /// A reading that exists becomes a row; one that does not becomes no row.
    /// The map is empty for every provider while the readings are switched
    /// off, which is what takes the section off the page rather than leaving
    /// an unexplained blank where it was.
    private static func makeStatus(_ reading: ProviderStatusReading?, provider: String)
        -> StatusRow?
    {
        guard let reading else { return nil }
        return StatusRow(
            indicator: reading.indicator,
            label: UsageFormat.statusLabel(reading.description),
            checkedAt: reading.indicator == .unknown ? nil : reading.checkedAt,
            components: reading.components.map(makeComponent),
            page: ProviderStatusFeed.root(for: provider))
    }

    private static func makeComponent(_ component: ProviderStatusComponent) -> ComponentRow {
        ComponentRow(
            id: component.id,
            name: component.name,
            indicator: component.indicator,
            status: UsageFormat.componentStatus(component.status),
            children: component.children.map(makeComponent))
    }

    /// The rows behind `gaugeRows`, built once with the snapshot.
    private static func makeGaugeRows(_ providers: [ProviderRow]) -> [GaugeRow] {
        providers.flatMap { row -> [GaugeRow] in
            let readable = row.accounts.filter(\.isReadable)
            guard readable.count > 1 else {
                var reading = row.reading
                reading.plan = nil
                reading.planTier = nil
                return [
                    GaugeRow(
                        id: row.id, provider: row.id, account: nil, name: row.name, qualifier: nil,
                        reading: reading, status: row.status)
                ]
            }
            return readable.map { account in
                GaugeRow(
                    id: "\(row.id)#\(account.id)",
                    provider: row.id,
                    account: account.id,
                    name: row.name,
                    qualifier: account.label,
                    accountCount: row.accounts.count,
                    reading: account.reading,
                    status: row.status)
            }
        }
    }

    /// Every account of this vendor, readable or merely switchable, in a
    /// stable order with the signed-in one first.
    ///
    /// The two inputs answer different questions and neither subsumes the
    /// other. `readings` is what Sissy has a live source for; `known` is what
    /// it holds an archived credential for. An account in the second and not
    /// the first is one the user has signed into on this Mac and not linked a
    /// session for — it gets a row with no gauges, because hiding it would
    /// hide the account they most need to link.
    ///
    /// Fewer than two accounts is no list at all: the row's own fields are
    /// that account's reading, and a picker over one choice is a control that
    /// does nothing.
    ///
    /// A row's name, address, organisation and seat come off **one** account,
    /// resolved once: the reading's, and the archived identity only where
    /// there is no reading at all. They used to be ordered field by field,
    /// which is how one row came to print the name of one account and the
    /// address of another.
    ///
    /// Reading-first is safe now and was not before: `ClaudeCodeSignals`
    /// attributes the config file to the account it names and resolves a
    /// non-active account from its link ahead of the archive, so whatever
    /// reaches a row is already that row's account and already the freshest
    /// of the answers. The index is the fallback because it is the only one
    /// that can name an account Sissy has seen and holds no session for.
    static func accountEntries(
        readings: [AccountSignals],
        known: ClaudeAccountRegistry.Snapshot,
        provider: String,
        reading limitsReading: LimitsReading,
        naming: AccountNaming = AccountNaming(),
        now: Date
    ) -> [AccountEntry] {
        let byID = Dictionary(readings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = Set(known.accounts.map(\.uuid)).union(byID.keys)
        guard ids.count > 1 else { return [] }

        let entries = ids.map { id -> AccountEntry in
            let reading = byID[id]
            let identity = known.accounts.first { $0.uuid == id }
            let account = reading?.account ?? identity?.providerAccount
            let planToken = reading?.plan ?? identity?.plan
            let plan = UsageFormat.plan(
                planToken,
                tier: reading?.planTier ?? identity?.planTier,
                seat: account?.seat,
                name: reading?.plan != nil ? reading?.planName : identity?.planName)
            let observedAt = reading?.limitsObservedAt
            let label = naming.name(id: id, account: account, plan: planToken) ?? id
            return AccountEntry(
                id: id,
                label: label,
                detail: naming.detail(name: label, account: account, plan: planToken),
                reading: AccountReading(
                    plan: plan,
                    windows: reading?.windows ?? [],
                    observedAt: observedAt,
                    captionedAt: observedAt,
                    projecting: reading?.isOnlyRunning != true,
                    notice: UsageFormat.limitsNotice(
                        reading?.limitsState ?? .quiet, provider: provider),
                    credits: reading?.credits,
                    resets: reading?.resets,
                    resetTarget: accountResetTarget(provider: provider, id: id, reading: reading),
                    runningSessions: reading?.runningSessions ?? 0,
                    limitsReading: limitsReading,
                    now: now),
                isReadable: reading.map { !$0.isOnlyRunning || !$0.windows.isEmpty } ?? false,
                isSignedIn: reading?.isSignedIn ?? (id == known.activeUUID))
        }
        return entries.sorted { lhs, rhs in
            (lhs.isSignedIn ? 0 : 1, lhs.label, lhs.id) < (rhs.isSignedIn ? 0 : 1, rhs.label, rhs.id)
        }
    }

    /// The resets row, or nil when there is nothing to spend.
    ///
    /// A count of zero gets no row, for the reason a credits reading of
    /// nothing against no cap gets none: it is most accounts, and a block that
    /// never changes is a block nobody reads. An absent count gets none
    /// either, because it is a reading nobody took.
    static func makeResets(_ resets: LimitResets?) -> ResetsRow? {
        guard let resets, resets.available > 0 else { return nil }
        return ResetsRow(
            headline: LimitResetCopy.available(resets.available),
            caption: LimitResetCopy.caption(title: resets.title, expiresAt: resets.nextExpiry),
            appliesNow: resets.appliesNow,
            available: resets.available,
            clears: resets.clears.sorted().map { UsageFormat.windowLabel(minutes: $0) })
    }

    /// Whose credential a press on one account's entry spends: that account's
    /// own for Codex, which reads every account it links, and the CLI's for
    /// the one Claude Code account it is signed in as.
    static func accountResetTarget(provider: String, id: String, reading: AccountSignals?)
        -> LimitResetTarget?
    {
        switch provider {
        case ProviderID.codex:
            return LimitResetTarget(
                provider: provider, account: reading?.isSignedIn == false ? id : nil)
        case ProviderID.claudeCode:
            return claudeResetTarget(account: id, isSignedIn: reading?.isSignedIn == true)
        default:
            return nil
        }
    }

    /// Whose credential a press on a Claude Code row or account spends: the
    /// CLI's own, which is the one reader that can, and only for the account
    /// it is signed in as. The account rides the target so the reader can
    /// refuse a press whose credential has since moved to another one.
    static func claudeResetTarget(account: String?, isSignedIn: Bool) -> LimitResetTarget? {
        isSignedIn ? LimitResetTarget(provider: ProviderID.claudeCode, account: account) : nil
    }

    /// Whose credential a press on the row itself spends: the CLI's, unless
    /// the only account Sissy reads is a linked one, which is the reading
    /// `CodexSignals.row` falls back to on a Mac whose `codex` is signed out.
    static func rowResetTarget(provider: String, _ accounts: [AccountSignals])
        -> LimitResetTarget?
    {
        if provider == ProviderID.claudeCode {
            return claudeResetTarget(account: accounts.first(where: \.isSignedIn)?.id, isSignedIn: true)
        }
        guard provider == ProviderID.codex else { return nil }
        return rowResetTarget(accounts)
    }

    static func rowResetTarget(_ accounts: [AccountSignals]) -> LimitResetTarget {
        guard accounts.count == 1, let only = accounts.first, !only.isSignedIn else {
            return LimitResetTarget(provider: ProviderID.codex, account: nil)
        }
        return LimitResetTarget(provider: ProviderID.codex, account: only.id)
    }

    /// The credits row, or nil when there is nothing a reader would act on.
    ///
    /// An account with the facility switched off, and one that has spent
    /// nothing against no cap, both get no row: the section exists to answer
    /// "how much of my own ceiling have I used", and neither of those has a
    /// ceiling or a spend to report. That is most accounts, and a permanent
    /// "Not enabled" under every provider page is a row that never changes.
    ///
    /// A balance answers none of those three and still has something to say,
    /// which is the whole of Codex's reading: it names what is left and never
    /// a spend or a cap, so it would fail a test written for the question
    /// Anthropic answers. A confirmed zero passes here — it is a reading, and
    /// the one an account that has never bought credits has.
    private static func makeCredits(_ credits: ProviderCredits?, now: Date) -> CreditsRow? {
        guard let credits, credits.isEnabled, credits.hasReading,
            credits.hasCap || (credits.usedMinor ?? 0) > 0 || credits.balanceMinor != nil,
            let amount = UsageFormat.creditsAmount(credits)
        else { return nil }
        return CreditsRow(
            amount: amount,
            percent: credits.fraction.map { Int(($0 * 100).rounded()) },
            fraction: credits.fraction,
            caption: UsageFormat.creditsCaption(credits, now: now),
            capReached: credits.capReached
        )
    }

    /// The account as a page prints it, or nil when the vendor answered for
    /// nothing a page would show. An account carrying only a seat is that
    /// case: the badge above already says it.
    /// The id a vendor's one account is filed under, which is what a rename
    /// made in Settings is kept by: the signed-in entry, or the only entry
    /// where none says it is signed in.
    private static func soleAccountID(_ accounts: [AccountSignals]) -> String? {
        accounts.first(where: \.isSignedIn)?.id ?? (accounts.count == 1 ? accounts.first?.id : nil)
    }

    private static func makeAccount(
        _ account: ProviderAccount?, id: String?, plan: String?, naming: AccountNaming
    ) -> AccountRow? {
        guard let name = naming.name(id: id, account: account, plan: plan) else { return nil }
        return AccountRow(
            name: name, detail: naming.detail(name: name, account: account, plan: plan))
    }

    /// One window as a row draws it. `projecting` is false for a running home's
    /// cached reply, which keeps its percentage and its age and draws no pace: a
    /// rate worked out from a reply of unknown age says `Runs out in 16m` about
    /// spending nobody has measured.
    static func makeWindow(
        _ window: UsageWindow, observedAt: Date, reading: LimitsReading, projecting: Bool = true,
        now: Date
    ) -> WindowRow {
        let percent = Int(window.usedPercent.rounded())
        return WindowRow(
            id: "\(window.minutes)-\(window.scope ?? "")",
            minutes: window.minutes,
            label: UsageFormat.windowLabel(minutes: window.minutes, scope: window.scope),
            percent: percent,
            reading: UsageFormat.windowPercent(percent, as: reading),
            readingSentence: UsageFormat.windowReading(percent, as: reading),
            fraction: min(max(window.usedPercent / 100, 0), 1),
            resetsAt: window.resetsAt,
            pace: projecting ? makePace(window, observedAt: observedAt) : nil,
            hasRolledOver: window.resetsAt.map { $0 < now } ?? false
        )
    }

    /// A full window, as a percentage. The pace arithmetic works in the same
    /// unit the vendor reports, so the headroom left is what is not yet spent
    /// of this.
    private static let fullWindowPercent: Double = 100

    /// How far into a window the projection starts being worth drawing.
    ///
    /// Below it the rate is one turn's worth of tokens divided by a few
    /// minutes, which extrapolates to a week's spend before lunch. A mark that
    /// swings from green to red on the first message is worse than no mark.
    private static let paceFloor: Double = 0.03

    /// The pace for one window, or nil when the window is too young to project
    /// from — or already past the reset it names, which describes a period
    /// that no longer exists. A window the vendor has not started names no
    /// reset at all, and there is no elapsed time to project from either.
    ///
    /// Measured from when the reading was taken rather than from the clock,
    /// because the percentage is the vendor's and was true then. Against the
    /// clock the mark slides right while the bar stands still, so a reading
    /// Sissy cannot refresh grows a reserve it never measured: Codex's windows
    /// arrive only on the CLI's own turns, and a Mac left idle overnight gained
    /// a point of phantom headroom every fourteen minutes of a week it had no
    /// news of.
    private static func makePace(_ window: UsageWindow, observedAt: Date) -> Pace? {
        guard let resetsAt = window.resetsAt else { return nil }
        let duration = Double(window.minutes) * 60
        let remaining = resetsAt.timeIntervalSince(observedAt)
        guard duration > 0, remaining > 0 else { return nil }
        let elapsed = min(max(duration - remaining, 0), duration)
        let progress = elapsed / duration
        guard progress >= paceFloor else { return nil }

        let expected = progress * fullWindowPercent
        return Pace(
            expectedFraction: progress,
            deltaPercent: Int((window.usedPercent - expected).rounded()),
            runsOutAt: runOut(
                window, elapsed: elapsed, remaining: remaining, observedAt: observedAt)
        )
    }

    /// When the rate so far exhausts the window, and nil when it does not
    /// before the reset.
    ///
    /// Nothing spent means no rate and therefore no run-out, which is the same
    /// answer as a rate slow enough to last: both are a window that survives
    /// its own reset, and the caption says so rather than naming a date past
    /// the one the row already prints.
    ///
    /// The date is anchored to the reading for the reason the rest of the pace
    /// is, and the countdown under the bar then shortens on its own as the
    /// projection ages — a run-out projected an hour ago for half an hour out
    /// reads as spent rather than as still half an hour away.
    private static func runOut(
        _ window: UsageWindow,
        elapsed: TimeInterval,
        remaining: TimeInterval,
        observedAt: Date
    ) -> Date? {
        let headroom = fullWindowPercent - window.usedPercent
        guard headroom > 0 else { return observedAt }
        let rate = window.usedPercent / elapsed
        guard rate > 0 else { return nil }
        let untilEmpty = headroom / rate
        return untilEmpty >= remaining ? nil : observedAt.addingTimeInterval(untilEmpty)
    }
}

extension UsagePanelSnapshot.AccountReading {
    /// A reading worded from what a row's source says. The one place an account's
    /// figures become its words, so a vendor's own row and an entry in its list
    /// cannot word the same reading two ways.
    ///
    /// `captionedAt` is apart from `observedAt` because a vendor's own row drops
    /// the age of a reading with no windows, where an entry keeps it.
    init(
        plan: (label: String, tier: String?)?,
        windows: [UsageWindow],
        observedAt: Date?,
        captionedAt: Date?,
        projecting: Bool,
        notice: UsagePanelSnapshot.LimitsNotice?,
        credits: ProviderCredits?,
        resets: LimitResets?,
        resetTarget: LimitResetTarget?,
        runningSessions: Int,
        limitsReading: LimitsReading,
        now: Date
    ) {
        self.init(
            plan: plan?.label,
            planTier: plan?.tier,
            windows: windows.map {
                UsagePanelSnapshot.makeWindow(
                    $0, observedAt: observedAt ?? now, reading: limitsReading,
                    projecting: projecting, now: now)
            },
            windowsCaption: captionedAt.map {
                UsageFormat.windowsCaption(observedAt: $0, now: now)
            },
            notice: notice,
            credits: UsagePanelSnapshot.makeCredits(credits, now: now),
            resets: UsagePanelSnapshot.makeResets(resets),
            resetTarget: resetTarget,
            runningSessions: runningSessions)
    }
}

extension UsagePanelSnapshot.WindowRow {
    /// The same gauge under an owner's name, for a window that is one owner's
    /// among several of the same length: the id has to be the owner's too, or
    /// `UsagePanelSnapshot.binding` could not say which of them leads.
    func labelled(_ name: String) -> Self {
        Self(
            id: name, minutes: minutes, label: name, percent: percent, reading: reading,
            readingSentence: readingSentence, fraction: fraction, resetsAt: resetsAt, pace: pace,
            hasRolledOver: hasRolledOver)
    }
}

extension UsageRange {
    /// Whether this is days picked on the calendar rather than a preset: the
    /// window that expires, that the header tints for, and whose figures are
    /// fetched rather than carried on the frame.
    var isPicked: Bool {
        if case .days = self { return true }
        return false
    }
}
