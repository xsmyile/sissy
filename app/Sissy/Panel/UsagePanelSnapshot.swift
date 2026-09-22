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
    /// today instead of rendering a blank.
    let period: UsagePeriod
    /// The windows the control may offer, `[.today]` alone when there is no
    /// archive behind the others and the control therefore does not appear.
    let periods: [UsagePeriod]
    let tokens: String
    let cost: String
    /// Tokens per hour so far today, nil on a day nothing has been spent on and
    /// on every window wider than one: an average over thirty days is not a
    /// pace, and the slot it would take is the one that says how far back the
    /// archive actually reaches.
    let burn: String?
    /// How far back the archive reaches when it falls short of the window on
    /// screen, nil when it covers it — the control already names the period, so
    /// this speaks only to admit that the number under it is of fewer days than
    /// its name claims.
    let coverage: String?
    let providers: [ProviderRow]
    /// How many of those rows have spent anything today. The rows themselves
    /// are every provider Sissy is metering — a row is also where a plan, an
    /// account and the rate-limit gauges ride, none of which stop existing
    /// because the day's total is zero.
    let usedToday: Int
    /// Today's spend by project, the busiest first, the tail folded into one
    /// row and whatever named no repository in a last row of its own. Empty
    /// when nothing today names a project, and the panel then draws no section
    /// rather than a heading over nothing.
    let projects: [ProjectRow]
    /// How many repositories the day names, which is what the section's own
    /// row offers to open — the fold is a row about the rest of the list and
    /// cannot say how long the list is without being read as a project.
    let projectCount: Int
    /// One row per connected forge, over the same window the headline is on.
    /// Empty until the user connects one, and the panel then draws no section
    /// rather than a heading over nothing.
    let forge: [ForgeRow]

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
        /// When the vendor starts counting the window this row is over, nil
        /// for one it is already counting.
        ///
        /// Only ever `today`, and only east of Greenwich: the row is over the
        /// vendor's whole UTC day of the local date's name, which opens after
        /// the local day does by the length of the offset. The row has no
        /// figures for that hour or two — the reading is absent rather than
        /// zero — and this is what lets the caption say why instead of leaving
        /// a dash that reads as a vendor which answered nothing.
        let opensAt: Date?
        let tooltip: String
        /// What each mark means, since a glyph cannot introduce itself.
        let mergedHelp: String
        let issuesHelp: String
        let commentsHelp: String

        var hasFigures: Bool {
            contributions != nil || merged != nil || issues != nil || comments != nil
        }
    }

    /// Every repository Sissy could read a commit identity for, the ones that
    /// disagree with their forge first. Empty where there is no git to read
    /// with and until the first sweep has run, and the page is then not
    /// reachable rather than empty.
    let identities: [IdentityRow]
    /// The Overview's one line about identities, nil when every repository
    /// agrees with its forge — which is the ordinary state, and a line that
    /// said so would be a row that never changes.
    let identityAlert: IdentityAlert?
    /// What is running on this Mac right now, and what the archive has
    /// counted over the window the headline is showing.
    let agents: AgentsBlock

    /// What a repository's commit identity is, as one row of the identities
    /// page.
    struct IdentityRow: Equatable, Identifiable {
        let id: String
        /// `owner/name`, the way the project row names the same repository,
        /// falling back to the directory for one whose remote names no forge.
        let name: String
        /// The full path, which is a client's name as often as not, so it
        /// stays on the hover exactly as it does on a project row.
        let path: String
        let mark: IdentityMark
        /// Who would sign a commit here, or why nobody would.
        let author: String
        /// Where the address was resolved from. Only on a row that needs
        /// correcting: on every other row it answers a question nobody asked.
        let origin: String?
        /// What the forge expects, and how many repositories say so.
        let expectation: String?
        /// The command that takes a repository's own override back out.
        ///
        /// Only where the override is local, because that is the only place
        /// unsetting changes the answer — a repository wearing the wrong name
        /// because a global rule gives it one has nothing of its own to
        /// remove, and offering the command there would be offering a no-op
        /// dressed as a fix. Nil too for a path `sh` quoting cannot make safe,
        /// which the reader refuses to build a command for at all.
        let fix: String?
    }

    /// How a repository's row is marked. A dash for `unjudged` rather than a
    /// tick or a warning: there is no reading to agree or disagree with, and
    /// the panel's own rule is that an absence of a measurement is drawn as
    /// one.
    enum IdentityMark: Equatable {
        case agrees
        case unexpected
        case unjudged
    }

    /// The Overview's identity line, and where it leads.
    struct IdentityAlert: Equatable {
        let summary: String
        /// The repository to open the page on, when exactly one is wrong.
        let repository: String?
    }

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
    }

    /// A provider's recent days, with the window they cover named.
    struct DayStrip: Equatable {
        let rows: [DayRow]
        /// `Last 7 days`, or the day the archive starts on plus how much of
        /// the window it actually covers.
        let label: String
        let total: String
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
        let start = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: today) ?? today
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
                models: models)
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

    private static func bindsSooner(_ lhs: WindowRow, _ rhs: WindowRow) -> Bool {
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
    /// Overview's block has answered pressure and nothing else since 0.1.10.
    struct GaugeRow: Equatable, Identifiable {
        let id: String
        /// Which page this opens, which is the vendor's — an account is a
        /// reading on that page rather than a page of its own.
        let provider: String
        /// Which of that vendor's accounts this row reads, so the page opens
        /// on the one that was clicked. Nil for a vendor drawing one row,
        /// where the page's own fields are already that account's.
        let account: String?
        let name: String
        let windows: [WindowRow]
        let notice: LimitsNotice?
        let status: StatusRow?
    }

    /// One account of a vendor, as the panel knows it.
    ///
    /// Two things make an account appear here and they are not the same thing.
    /// Sissy can **read** an account it holds a live source for — the CLI's
    /// own credential for whoever is signed in, a linked claude.ai session for
    /// anyone else — and it can **switch to** an account whose credential it
    /// has archived. An account can be either, both, or the first without the
    /// second.
    ///
    /// So an archived account with no session linked gets a row with no
    /// gauges: Sissy knows who it is and can sign the CLI in as it, and cannot
    /// say a thing about its limits until a session is linked. Leaving it out
    /// would hide the account the user most wants to link.
    struct AccountEntry: Equatable, Identifiable {
        let id: String
        /// What the picker calls it, and what qualifies the Overview's row
        /// once there is more than one.
        let label: String
        let email: String?
        let organization: String?
        let plan: String?
        let planTier: String?
        /// Shortest window first, and empty for an account Sissy cannot read.
        let windows: [WindowRow]
        let windowsCaption: String?
        let credits: CreditsRow?
        let notice: LimitsNotice?
        /// Whether Sissy has a source for this account at all. False is an
        /// invitation to link one rather than a failure to report.
        let isReadable: Bool
        /// Whether the CLI itself is signed in as this account — the one whose
        /// future spend lands in the day beside it.
        let isSignedIn: Bool
        /// Whether Sissy holds a credential it could sign the CLI in with.
        let isSwitchable: Bool
    }

    struct ProviderRow: Equatable, Identifiable {
        let id: String
        let name: String
        /// Every account of this vendor the panel knows. Empty when there is
        /// one, which is most installs — a picker over a single choice is a
        /// control that does nothing, and the fields below are that one
        /// account's reading anyway.
        let accounts: [AccountEntry]
        /// Subscription plan, already worded. Nil leaves the row's header at
        /// the name alone — an API-key user has no plan to name, and a Codex
        /// that has not taken a turn yet has not said which it is on.
        let plan: String?
        /// Limit tier, worded, and only when it is not already part of
        /// `plan` — a Team seat metered at Max 5x. It goes to the tooltip:
        /// the badge is for the plan the user pays for.
        let planTier: String?
        let tokens: String
        let cost: String
        /// Shortest window first. Empty when the provider reports none, which
        /// its page answers with a sentence rather than a blank block.
        let windows: [WindowRow]
        /// When those windows were taken, worded. Nil when there are none, and
        /// when the provider published them without saying — a gauge with an
        /// invented age would be worse than one with none.
        let windowsCaption: String?
        /// What to say and offer when the limits are missing for a reason the
        /// user can act on. Nil the rest of the time, which is most of it.
        let notice: LimitsNotice?
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
        /// What the vendor has billed against a spend cap, worded. Nil for a
        /// provider that publishes none and for an account with nothing to
        /// say — no cap set and nothing spent, which is every account that
        /// has never turned credits on.
        let credits: CreditsRow?
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

    /// An account as the provider page prints it: the address on its own
    /// line, the organisation under it.
    ///
    /// The seat is deliberately absent — `UsageFormat.plan` has already
    /// folded it into the badge for the one vendor that publishes one, and a
    /// line repeating what the badge above it says is a line nobody reads.
    struct AccountRow: Equatable {
        let email: String?
        /// Organisation the seat belongs to. Nil when the vendor named none.
        let organization: String?
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

    struct ProjectRow: Equatable, Identifiable {
        let id: String
        /// The repository's own name — the last component of its path, which
        /// is what the user calls it.
        let name: String
        /// The account the repository is pushed to, drawn quiet in front of
        /// the name. Nil when the repository names no forge, and on the folded
        /// row, which stands for several.
        ///
        /// It prefixes the name rather than replacing it: two accounts can
        /// hold a `website` each, and without this the panel draws one label
        /// twice. The name still comes from the directory, so a row never
        /// changes what it was already called.
        let owner: String?
        /// The repository as its forge names it, for the card a click on the
        /// row opens. Nil for a row that stands for no repository and for one
        /// whose remote names no forge — both of which have nothing to open,
        /// so the click does nothing rather than opening an empty card.
        let repository: RepositoryLink?
        /// What the row hovers: a repository's full path. Nil on the folded
        /// row, which stands for several. A project path is a client's name as
        /// often as not, so the row shows the name and keeps the rest for a
        /// hover.
        let tooltip: String?
        let tokens: String
        let cost: String
        let share: Double
        /// Which CLIs the money on this row went through, in the panel's own
        /// provider order so the marks and the bar's segments read the same
        /// way down the page.
        ///
        /// Empty on the folded row, which stands for no single repository,
        /// and on every row of a single provider's own list — there the answer
        /// is the page's own name. The shares are of the same day `share` is
        /// of, so they sum to it.
        let providers: [ProviderShare]
    }

    /// One model's share of one provider's day, as its own page prints it.
    struct ModelRow: Equatable, Identifiable {
        /// The model id as the vendor spells it, which is also what the pill
        /// is keyed by.
        let id: String
        /// The same id with its release date and its vendor prefix taken off,
        /// which is the pill's first line.
        let name: String
        /// The pill's second line: the share of the day and what it cost.
        /// The share is of the money while there is any, and of the tokens
        /// when the whole day priced at nothing.
        let reading: String
        /// The four token counters apart, with the raw id. The pill's hover
        /// and its accessibility label, which are the same sentence: anything
        /// only a pointer can reach does not exist for VoiceOver.
        let detail: String
    }

    /// What one provider spent on one project, as a share of the day.
    ///
    /// Derived rather than carried on `ProjectTotals`: the combined list sums
    /// the CLIs into one row per repository by design, and the frame still
    /// holds both halves on its own slices.
    struct ProviderShare: Equatable, Identifiable {
        /// The provider id, which is what the mark and the tint are keyed by.
        let id: String
        let share: Double
    }

    /// What a day spent that no repository can be named for: the line under
    /// the list rather than the last row of it.
    ///
    /// It is not a project, so it gets no rank among them, no bar, no path and
    /// no forge — it is the arithmetic that lets the rows above it reach the
    /// total beside them, which is a sentence rather than a reading. It has no
    /// `share` for the same reason: a bar invites a comparison with the rows,
    /// and the one thing this line is not is a project that happened to be
    /// small.
    struct ProjectsResidue: Equatable {
        let tokens: String
        let cost: String
        /// Which CLIs it went through, where more than one is metered. Empty
        /// on a provider's own page, whose title has named the CLI already.
        let providers: [ProviderCost]
    }

    /// One provider's share of a figure, in money rather than in a fraction of
    /// a bar — the residue has no bar for the fraction to be of.
    struct ProviderCost: Equatable, Identifiable {
        let id: String
        let cost: String
    }

    /// A repository on the forge it is pushed to.
    ///
    /// `label` is the forge's own name for it, which is not always the
    /// directory's: a clone renamed on disk keeps the row the name the user
    /// gave it and the card the name the forge answers to.
    struct RepositoryLink: Equatable {
        let label: String
        let host: String
        /// Nil for a remote that names no page — the card then says where the
        /// repository lives without claiming a way there.
        let page: URL?
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

    static func make(
        frame: FrameData,
        period: UsagePeriod = .today,
        claudeAccounts: ClaudeAccountRegistry.Snapshot = .init(),
        limitsReading: LimitsReading = .used,
        now: Date = Date()
    ) -> Self {
        let totalTokens = frame.providers.reduce(0) { $0 + $1.tokens }
        let totalCost = frame.providers.reduce(Decimal(0)) { $0 + $1.cost }
        let rows = makeRows(
            frame.providers, claudeAccounts: claudeAccounts, status: frame.providerStatus,
            totalTokens: totalTokens, limitsReading: limitsReading, now: now)
        let periods = availablePeriods(frame.history)
        let resolved = periods.contains(period) ? period : .today
        let rollup = frame.history[resolved]
        return Self(
            period: resolved,
            periods: periods,
            tokens: UsageFormat.tokens(rollup?.tokens ?? frame.tokens),
            cost: UsageFormat.cost(rollup?.cost ?? frame.cost),
            burn: resolved == .today ? frame.burn.map(UsageFormat.burn) : nil,
            coverage: rollup.flatMap { UsageFormat.periodCoverage($0, now: now) },
            providers: rows,
            usedToday: frame.providers.count { $0.tokens > 0 },
            projects: makeProjects(frame.projects, totalCost: totalCost),
            projectCount: frame.projects.count,
            forge: makeForge(frame.forge, period: resolved, now: now),
            identities: makeIdentities(frame.identities),
            identityAlert: makeIdentityAlert(frame.identities),
            agents: makeAgents(frame, now: now)
        )
    }

    /// What the CLIs on this Mac are doing, on the two axes a person asks
    /// about: how many of them there are right now, and how many there have
    /// been over a window.
    ///
    /// The two are separate readings and neither substitutes for the other. A
    /// count of running processes says nothing about the day, and a day's
    /// count says nothing about whether the Mac has room to keep working.
    struct AgentsBlock: Equatable {
        /// The live half, absent until the first sweep lands — which the
        /// surfaces draw as a dash, because not having measured is not a
        /// measurement of none.
        let live: Live?
        /// Every window at once, keyed by period.
        ///
        /// Every one rather than the selected one, for the reason
        /// `FrameData.history` carries them all: the choice is the page's own
        /// and changing it must not cost a round trip to the engine and a
        /// frame's wait. It is also what lets the page pick locally, which is
        /// the whole point — the Overview shows none of this, so a shared
        /// selection would have moved the money headline behind the user's
        /// back.
        let counted: [UsagePeriod: Window]
        let periods: [UsagePeriod]

        /// One window's counts, whole and split by provider.
        struct Window: Equatable {
            let counts: AgentCounts
            let byProvider: [ProviderCount]
            /// How far back the archive actually reaches inside this window,
            /// or nil where it covers the whole of it.
            let coverage: String?
            /// How long the window was worked, and how much of that its
            /// sub-agents were.
            let activity: ActivityTotals
            /// What the window cost, which is only here so the page can put a
            /// price on an hour of it. Never drawn on its own: the money is
            /// the headline's question and this page is not the headline.
            let cost: Decimal
            /// The day's own shape, for the strip.
            ///
            /// **Today only.** A strip is a picture of one day, and a window
            /// of thirty has no single day to draw — a strip per day is the
            /// spend bar this panel already removed, and one strip averaging
            /// thirty is a day nobody worked. The caption under it reads
            /// `activity` instead, which carries its block count for every
            /// window.
            let shape: DayShape?
            /// One pill per effort the window's turns ran at, busiest first.
            ///
            /// Empty for a window whose days all predate the field, which is
            /// the archive's own answer for a reading it never took — and the
            /// block is drawn only when there is one, because pills at zero
            /// would report a setting nobody chose.
            let effort: [ModelRow]

            init(
                counts: AgentCounts, byProvider: [ProviderCount], coverage: String?,
                activity: ActivityTotals = .none, cost: Decimal = 0, shape: DayShape? = nil,
                effort: [ModelRow] = []
            ) {
                self.counts = counts
                self.byProvider = byProvider
                self.coverage = coverage
                self.activity = activity
                self.cost = cost
                self.shape = shape
                self.effort = effort
            }
        }

        /// One day's blocks, as the strip draws them.
        ///
        /// Minutes rather than fractions, and the day's own length beside
        /// them, because a local day is 1380 or 1500 minutes across a
        /// daylight-saving change and a strip drawn against a fixed 1440 would
        /// put that day's evening past its own right edge.
        struct DayShape: Equatable {
            let blocks: [ClosedRange<Int>]
            let dayMinutes: Int

            /// Where a block sits along the strip, as a fraction of the day.
            func span(_ block: ClosedRange<Int>) -> ClosedRange<Double> {
                let width = Double(max(dayMinutes, 1))
                let start = min(Double(block.lowerBound) / width, 1)
                let end = min(Double(block.upperBound + 1) / width, 1)
                return start...max(end, start)
            }
        }

        struct Live: Equatable {
            let running: Int
            let footprint: UInt64
            let treeFootprint: UInt64
            let peak: UInt64
            /// Footprints oldest first, for the sparkline. Empty until a
            /// second sample lands — one point is not a line.
            let samples: [UInt64]
            let since: Date
            /// One row per running process, dearest first, which is what
            /// answers "two gigabytes of what".
            let processes: [Process]
        }

        /// One running agent, as a row.
        struct Process: Equatable, Identifiable {
            let id: pid_t
            let provider: String
            /// The repository it is working in, rendered as its last component
            /// exactly as a project row is — a path is a client's name as
            /// often as not, so the whole of it stays on the hover.
            let project: String?
            let directory: String?
            let footprint: UInt64
            let startedAt: Date
        }

        /// What the Overview's one line says. A Mac that has never measured
        /// and one that measured nothing both get the row, because it is the
        /// only way to the page and a door that comes and goes is not one.
        var summary: String {
            guard let live else { return "no reading yet" }
            guard live.running > 0 else { return "no agents running" }
            return UsageFormat.agentsRunning(live.running, footprint: live.footprint)
        }

        struct ProviderCount: Equatable, Identifiable {
            let id: String
            let name: String
            let counts: AgentCounts
            /// How many of this vendor's processes are running now, which is
            /// the live half of the same row.
            let running: Int
            /// How long this vendor alone was working. The rows can add up to
            /// more than the figure above them, and that is the reading rather
            /// than a rounding: two CLIs working in the same minute are one
            /// minute of the day and one minute of each of theirs.
            let activity: ActivityTotals

            init(
                id: String, name: String, counts: AgentCounts, running: Int,
                activity: ActivityTotals = .none
            ) {
                self.id = id
                self.name = name
                self.counts = counts
                self.running = running
                self.activity = activity
            }
        }

        /// The window a page opens on when nothing has been chosen.
        ///
        /// Today rather than the widest, because the block above it is what is
        /// running *now* and a page whose two halves answer for two different
        /// spans reads as one reading. Widening is one click and resets on the
        /// way out, exactly as the identities page's own fold does.
        static let defaultPeriod: UsagePeriod = .today
    }

    /// Builds the block from a frame.
    ///
    /// Today's counts come off the slices rather than out of the archive, for
    /// the reason the headline's own figure does: the archive's copy of today
    /// is written behind the tail's flush, so a count read from it would lag
    /// the one beside it. Every other window is the archive's, **including its
    /// per-provider split** — a row taken from the slices under a thirty-day
    /// heading would be today's figure wearing another window's label.
    static func makeAgents(_ frame: FrameData, now: Date) -> AgentsBlock {
        let running = frame.agentMemory?.current.agents ?? []
        // Unioned rather than summed, because two CLIs working in the same
        // minute are one minute of the day.
        let shape = frame.providers.reduce(into: AgentActivityDay.none) { $0.formUnion($1.activity) }
        let today = AgentsBlock.Window(
            counts: frame.providers.reduce(into: AgentCounts.none) { $0.add($1.agents) },
            byProvider: frame.providers.map { slice in
                AgentsBlock.ProviderCount(
                    id: slice.id, name: UsageFormat.providerName(slice.id),
                    counts: slice.agents,
                    running: running.count { $0.provider == slice.id },
                    activity: ActivityTotals(slice.activity))
            },
            coverage: nil,
            activity: ActivityTotals(shape),
            cost: frame.cost,
            shape: AgentsBlock.DayShape(
                blocks: shape.blocks, dayMinutes: Self.minutesInDay(containing: now)),
            effort: makeEffort(
                frame.providers.reduce(into: EffortCounts.none) { $0.add($1.effort) }))
        var counted: [UsagePeriod: AgentsBlock.Window] = [.today: today]
        for (period, rollup) in frame.history {
            counted[period] = AgentsBlock.Window(
                counts: rollup.agents,
                byProvider: rollup.agentsByProvider
                    .map { id, counts in
                        AgentsBlock.ProviderCount(
                            id: id, name: UsageFormat.providerName(id), counts: counts,
                            running: running.count { $0.provider == id },
                            activity: rollup.activityByProvider[id] ?? .none)
                    }
                    .sorted { $0.name < $1.name },
                coverage: UsageFormat.periodCoverage(rollup, now: now),
                activity: rollup.activity,
                cost: rollup.cost,
                effort: makeEffort(rollup.effort))
        }
        return AgentsBlock(
            live: frame.agentMemory.map { memory in
                AgentsBlock.Live(
                    running: memory.current.agents.count,
                    footprint: memory.current.footprint,
                    treeFootprint: memory.current.treeFootprint,
                    peak: memory.peak,
                    samples: memory.samples.count > 1 ? memory.samples : [],
                    since: memory.since,
                    processes: memory.current.agents.map {
                        AgentsBlock.Process(
                            id: $0.pid, provider: $0.provider, project: $0.project,
                            directory: $0.directory, footprint: $0.footprint,
                            startedAt: $0.startedAt)
                    })
            },
            counted: counted,
            periods: [.today] + UsagePeriod.archived.filter { counted[$0] != nil })
    }

    /// How many minutes the local day holding `instant` is made of, which is
    /// 1440 except across a daylight-saving change.
    private static func minutesInDay(containing instant: Date, calendar: Calendar = .current)
        -> Int
    {
        let start = calendar.startOfDay(for: instant)
        guard let next = calendar.date(byAdding: .day, value: 1, to: start) else {
            return ActivityMinutes.minutesPerDay
        }
        return Int(next.timeIntervalSince(start) / 60)
    }

    /// Every project a day names, unfolded, for the page behind the section's
    /// own row.
    ///
    /// Built on demand rather than carried on the snapshot: the panel makes a
    /// snapshot per frame while it is open, and the full list is wanted on one
    /// page that is usually closed.
    ///
    /// **Today, and no period of its own.** The rows come from the day buckets
    /// — `UsageHistoryRollup` carries a period's total and deliberately no
    /// project split — so a control here would name a window the rows are not
    /// of. What a project cost over a month is #81, closed: the export already
    /// answers it from rows the archive holds.
    ///
    /// `provider` nil sums every CLI and gives each row its split; naming one
    /// takes that provider's own day, where the split would repeat the page's
    /// title on every row.
    static func projectsPage(frame: FrameData, provider: String?) -> ProjectsPage {
        let slices =
            provider.map { id in frame.providers.filter { $0.id == id } } ?? frame.providers
        let projects = provider == nil ? frame.projects : slices.first?.projects ?? []
        let cost = slices.reduce(Decimal(0)) { $0 + $1.cost }
        return ProjectsPage(
            provider: provider,
            rows: makeProjects(
                projects, totalCost: cost, limit: nil,
                contributors: provider == nil ? contributors(frame.providers) : [:]),
            residue: makeResidue(slices, split: provider == nil),
            subtitle: UsageFormat.projectsSubtitle(count: projects.count, cost: cost)
        )
    }

    /// The projects page: every repository of the day, and the line that dates
    /// and totals them.
    struct ProjectsPage: Equatable {
        /// Whose day this is, or nil for every provider summed.
        let provider: String?
        /// Unfolded, so the page is the one place the whole list exists.
        let rows: [ProjectRow]
        /// What named no repository, which is the only surface that says so.
        /// The rows are read against the total in the subtitle and cannot
        /// reach it without this, so the line carries the figure rather than
        /// only the fact.
        let residue: ProjectsResidue?
        /// When, how many, and how much — today's own total rather than the
        /// headline's, which is over whatever period the user picked.
        let subtitle: String
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
    private static func makeForge(
        _ readings: [ForgeActivityReading], period: UsagePeriod, now: Date,
        calendar: Calendar = .current
    ) -> [ForgeRow] {
        let opensAt = ForgeWindow.opens(period, now: now, calendar: calendar)
        return readings.map { reading in
            let ended =
                period == .today && !calendar.isDate(reading.readAt, inSameDayAs: now)
            let current = ended ? nil : reading
            let contributions = current.flatMap { $0.contributions(for: period) }
                .map(UsageFormat.forgeCount)
            let merged = current.flatMap { $0.merged(for: period) }.map(UsageFormat.forgeCount)
            let issues = current.flatMap { $0.issues(for: period) }.map(UsageFormat.forgeCount)
            let comments = current.flatMap { $0.comments(for: period) }.map(UsageFormat.forgeCount)
            return ForgeRow(
                id: reading.id,
                kind: reading.kind,
                host: reading.host,
                login: reading.login,
                contributions: contributions,
                merged: merged,
                issues: issues,
                comments: comments,
                readAt: reading.hasEverRead ? reading.readAt : nil,
                failure: reading.failure,
                opensAt: opensAt,
                tooltip: UsageFormat.forgeTooltip(
                    reading.kind, host: reading.host, login: reading.login, period: period,
                    boundedToOneYear: reading.activity.contributionsBoundedToOneYear),
                mergedHelp: UsageFormat.forgeMergedHelp(reading.kind),
                issuesHelp: UsageFormat.forgeIssuesHelp(reading.kind),
                commentsHelp: UsageFormat.forgeCommentsHelp(reading.kind))
        }
    }
    /// The identities page's rows, the findings first.
    ///
    /// Ordered by what the row says rather than by name: a page whose one
    /// wrong repository sorts to position nineteen is a page that has to be
    /// read rather than glanced at, and the rows that agree are the ones the
    /// user is not looking for.
    private static func makeIdentities(_ identities: [RepositoryIdentity]) -> [IdentityRow] {
        identities.map(identityRow).sorted { left, right in
            guard left.mark == right.mark else { return rank(left.mark) < rank(right.mark) }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    private static func rank(_ mark: IdentityMark) -> Int {
        switch mark {
        case .unexpected: return 0
        case .unjudged: return 1
        case .agrees: return 2
        }
    }

    private static func identityRow(_ identity: RepositoryIdentity) -> IdentityRow {
        var unexpected = false
        if case .unexpected = identity.verdict { unexpected = true }
        let origin = identity.origin
        return IdentityRow(
            id: identity.repository,
            name: identityName(identity),
            path: identity.repository,
            mark: mark(identity.verdict),
            author: UsageFormat.identityAuthor(identity.reading),
            origin: unexpected ? origin.map(UsageFormat.identityOrigin) : nil,
            expectation: UsageFormat.identityExpectation(identity.verdict, host: identity.host),
            fix: unexpected && origin?.scope == Self.localConfigScope
                ? GitIdentityReader.unsetCommand(repository: identity.repository) : nil
        )
    }

    /// The scope git names a repository's own configuration with, which is the
    /// only one `--unset` without a scope flag reaches.
    private static let localConfigScope = "local"

    private static func identityName(_ identity: RepositoryIdentity) -> String {
        guard let remote = identity.remote else {
            return UsageFormat.projectName(identity.repository)
        }
        return "\(remote.owner)/\(remote.repository)"
    }

    private static func mark(_ verdict: GitIdentityVerdict) -> IdentityMark {
        switch verdict {
        case .agrees: return .agrees
        case .unexpected: return .unexpected
        case .unjudged: return .unjudged
        }
    }

    private static func makeIdentityAlert(_ identities: [RepositoryIdentity]) -> IdentityAlert? {
        let wrong = identities.filter {
            if case .unexpected = $0.verdict { return true }
            return false
        }
        guard let summary = UsageFormat.identityAlert(wrong.map(identityName)) else { return nil }
        return IdentityAlert(
            summary: summary, repository: wrong.count == 1 ? wrong[0].repository : nil)
    }
    /// Which windows the headline may be put over: today, which needs no
    /// archive, and each of the rest the frame actually carries a total for.
    ///
    /// Read off the keys rather than from whether the frame sent anything at
    /// all. The engine sends all of them or none, so the difference is invisible
    /// in production — but taking a window the frame cannot answer as available
    /// falls it back to today's number while the control still reads `All`,
    /// which is a wrong label on a right number and the worst of the outcomes
    /// here. Today alone is both the archive switched off and a fresh install,
    /// and then there is no control at all: four windows that all answer the
    /// number already on screen are a feature rather than a reading.
    private static func availablePeriods(_ history: [UsagePeriod: UsageHistoryRollup])
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
    /// credential that is signed in — and `accounts` is the list of the others
    /// Sissy could switch to, which is a property of the keychain rather than
    /// of the frame.
    private static func makeRows(
        _ slices: [ProviderSlice],
        claudeAccounts: ClaudeAccountRegistry.Snapshot,
        status: [String: ProviderStatusReading],
        totalTokens: Int,
        limitsReading: LimitsReading,
        now: Date
    ) -> [ProviderRow] {
        slices.map { slice in
            let plan = UsageFormat.plan(
                slice.plan, tier: slice.planTier, seat: slice.account?.seat)
            return ProviderRow(
                id: slice.id,
                name: UsageFormat.providerName(slice.id),
                accounts: accountEntries(
                    readings: slice.signals.accounts,
                    // The archive of credentials Sissy could switch the CLI to
                    // is Claude Code's alone: a linked Codex account is read
                    // and never signed in with, so an account it holds no
                    // reading for is an account it holds nothing for.
                    known: slice.id == ProviderID.claudeCode
                        ? claudeAccounts : ClaudeAccountRegistry.Snapshot(),
                    provider: slice.id,
                    reading: limitsReading, now: now),
                plan: plan?.label,
                planTier: plan?.tier,
                tokens: UsageFormat.tokens(slice.tokens),
                cost: UsageFormat.cost(slice.cost),
                windows: slice.windows.map {
                    makeWindow(
                        $0, observedAt: slice.limitsObservedAt ?? now, reading: limitsReading,
                        now: now)
                },
                windowsCaption: slice.windows.isEmpty
                    ? nil
                    : slice.limitsObservedAt.map {
                        UsageFormat.windowsCaption(observedAt: $0, now: now)
                    },
                notice: UsageFormat.limitsNotice(slice.limitsState, provider: slice.id),
                account: makeAccount(slice.account),
                projects: makeProjects(slice.projects, totalCost: slice.cost),
                projectCount: slice.projects.count,
                models: makeModels(
                    slice.models, provider: slice.id, totalCost: slice.cost,
                    totalTokens: slice.tokens),
                credits: makeCredits(slice.credits, now: now),
                status: makeStatus(status[slice.id], provider: slice.id)
            )
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

    /// The Overview's gauges: one per vendor, or one per readable account of a
    /// vendor that has more than one.
    ///
    /// An account Sissy cannot read is left out here while it still appears in
    /// the picker. The picker is a list of accounts and this is a list of
    /// readings, and a row with an empty track would report headroom nobody
    /// measured.
    var gaugeRows: [GaugeRow] {
        providers.flatMap { row -> [GaugeRow] in
            let readable = row.accounts.filter(\.isReadable)
            guard readable.count > 1 else {
                return [
                    GaugeRow(
                        id: row.id, provider: row.id, account: nil, name: row.name,
                        windows: row.windows, notice: row.notice, status: row.status)
                ]
            }
            return readable.map { account in
                GaugeRow(
                    id: "\(row.id)#\(account.id)",
                    provider: row.id,
                    account: account.id,
                    name: UsageFormat.accountQualifiedName(
                        row.name, organization: account.organization, fallback: account.label),
                    windows: account.windows,
                    notice: account.notice,
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
    /// of the answers. The archive is the fallback because it is the only one
    /// that can name an account Sissy holds a credential for and no session.
    static func accountEntries(
        readings: [AccountSignals],
        known: ClaudeAccountRegistry.Snapshot,
        provider: String,
        reading limitsReading: LimitsReading,
        now: Date
    ) -> [AccountEntry] {
        let byID = Dictionary(readings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let switchable = Set(known.accounts.map(\.uuid))
        let ids = switchable.union(byID.keys)
        guard ids.count > 1 else { return [] }

        let entries = ids.map { id -> AccountEntry in
            let reading = byID[id]
            let identity = known.accounts.first { $0.uuid == id }
            let account = reading?.account ?? identity?.providerAccount
            let plan = UsageFormat.plan(
                reading?.plan ?? identity?.plan,
                tier: reading?.planTier ?? identity?.planTier,
                seat: account?.seat)
            let observedAt = reading?.limitsObservedAt
            return AccountEntry(
                id: id,
                label: UsageFormat.accountLabel(account) ?? id,
                email: account?.email,
                organization: account?.organization,
                plan: plan?.label,
                planTier: plan?.tier,
                windows: (reading?.windows ?? []).map {
                    makeWindow(
                        $0, observedAt: observedAt ?? now, reading: limitsReading, now: now)
                },
                windowsCaption: observedAt.map {
                    UsageFormat.windowsCaption(observedAt: $0, now: now)
                },
                credits: makeCredits(reading?.credits, now: now),
                notice: UsageFormat.limitsNotice(reading?.limitsState ?? .quiet, provider: provider),
                isReadable: reading != nil,
                isSignedIn: reading?.isSignedIn ?? (id == known.activeUUID),
                isSwitchable: switchable.contains(id))
        }
        return entries.sorted { lhs, rhs in
            (lhs.isSignedIn ? 0 : 1, lhs.label) < (rhs.isSignedIn ? 0 : 1, rhs.label)
        }
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
    private static func makeAccount(_ account: ProviderAccount?) -> AccountRow? {
        guard let account, account.email != nil || account.organization != nil else { return nil }
        return AccountRow(email: account.email, organization: account.organization)
    }

    /// Rows a popover can hold. Past this the answer is a report, and a
    /// report needs more than the two days the tail retains.
    private static let projectRowLimit = 5

    /// The busiest projects, with everything below them folded into one row.
    ///
    /// **Every row here is a repository**, which is what lets the section's
    /// own label count them: the fold stands for repositories too, and what
    /// named none is not a row at all but the line `makeResidue` builds for
    /// the page. It used to be the last row of this list, which put a reading
    /// that is not a project under a label counting projects, and gave the one
    /// thing on the list with nothing to open a bar, a hover and a rank.
    ///
    /// Ordered here rather than taken on trust, because this is the function
    /// that *drops* rows: a prefix over an order nobody established folds the
    /// day's largest project into "3 more projects" as readily as its
    /// smallest. A provider folds its own day out of a dictionary, whose key
    /// order is arbitrary, so the Overview's list came out ordered — it is
    /// summed through `combinedProjects` — and a provider's own page did not.
    private static func makeProjects(
        _ unordered: [ProjectTotals],
        totalCost: Decimal,
        limit: Int? = projectRowLimit,
        contributors: [String: [String: Decimal]] = [:]
    ) -> [ProjectRow] {
        let projects = FrameBuilder.orderedProjects(unordered)
        guard !projects.isEmpty else { return [] }
        let share = { (cost: Decimal) -> Double in
            guard totalCost > 0 else { return 0 }
            return NSDecimalNumber(decimal: cost).doubleValue
                / NSDecimalNumber(decimal: totalCost).doubleValue
        }
        let kept =
            limit.map { projects.count <= $0 ? projects.count : $0 - 1 }
            ?? projects.count
        var rows = projects.prefix(kept).map { project in
            ProjectRow(
                id: project.path,
                name: UsageFormat.projectName(project.path),
                owner: project.remote?.owner,
                repository: project.remote.map {
                    RepositoryLink(
                        label: "\($0.owner)/\($0.repository)", host: $0.host, page: $0.page)
                },
                tooltip: project.path,
                tokens: UsageFormat.tokens(project.tokens),
                cost: UsageFormat.cost(project.cost),
                share: share(project.cost),
                providers: providerShares(contributors[project.path] ?? [:], share: share)
            )
        }
        if kept < projects.count {
            let rest = projects.dropFirst(kept)
            let restCost = rest.reduce(Decimal(0)) { $0 + $1.cost }
            rows.append(
                ProjectRow(
                    id: Self.foldedProjectRowID,
                    name: UsageFormat.projectsFolded(count: rest.count),
                    owner: nil,
                    repository: nil,
                    tooltip: nil,
                    tokens: UsageFormat.tokens(rest.reduce(0) { $0 + $1.tokens }),
                    cost: UsageFormat.cost(restCost),
                    share: share(restCost),
                    providers: []
                ))
        }
        return rows
    }

    /// One pill per model, dearest first, or none at all.
    ///
    /// **Folded past four, which is what the width holds.** Measured
    /// 2026-09-22 at `PanelMetrics.width`: three pills want 210 pt of the 312
    /// a page has, four want 277, five want 344 and six 419. Past four the row
    /// does not degrade gracefully — both of a pill's lines shrink, and it was
    /// the money that went first, rendering `62% · $…` and `9% · $0.…`, where
    /// a truncated currency figure cannot be read at all. Pinning the figures
    /// to their ideal width only moved the damage: the row then overflowed and
    /// was clipped at both ends, losing the leading pill's first glyphs.
    ///
    /// Four is therefore the limit and it is a measurement rather than a
    /// guess: it is every model Claude ships in a day (opus, sonnet, haiku,
    /// fable) and it holds Codex's longest ids at 291 pt. The docstring here
    /// used to say **no fold**, on the grounds that the archive's busiest day
    /// held 3; that was true of the rows it described and of a block with a
    /// floor of two under it, and neither is the case any more.
    ///
    /// The fold is `projectRowLimit`'s, one pill standing for the rest, and it
    /// takes the **cheapest** because the list is dearest first — the models
    /// folded away are the ones the day did least on. It carries their summed
    /// share and their summed cost rather than a bare count, which is what
    /// `makeResidue` does for the spend no repository claims.
    ///
    /// **The percentage is a share of the money, and of the tokens as soon as
    /// any model has none.** A model the pricing sources do not know books
    /// tokens at a cost of zero, and zero is what it is *not*: the rate is
    /// unknown, which is the distinction `ProviderCredits` already holds for
    /// money and the strip holds for a day with no file. Sharing cost on a day
    /// that holds one would print that model at `0% · $0.00` beside millions
    /// of tokens — a measurement of nothing where there was a measurement, and
    /// the failure this paragraph used to claim to prevent while covering only
    /// the day where *every* model was unpriced. So the denominator is the
    /// tokens whenever a model has tokens and no cost, not only when the whole
    /// day prices at zero. The money stays on the pill either way.
    /// `FrameBuilder.orderedModels` falls back the same way, so the order and
    /// the percentages cannot disagree.
    ///
    /// **A share that rounds to nothing is worded, not rounded away.** A model
    /// worth 0.4% of the day would print `0%` beside a cost that is not zero,
    /// which is the same lie in smaller type; `<1%` is what the bar's own
    /// `BarGeometry.fillWidth` does for the identical case, where a share too
    /// small to draw still draws a stub. The percentages are therefore **not**
    /// renormalised to sum to 100 — three equal models read 33% each and sum
    /// to 99. Nobody adds four pills up, and the alternative is worse: largest
    /// remainder makes a model's own displayed share depend on which other
    /// models happen to sit beside it, so the same day could read 33% or 34%
    /// for the same money.
    ///
    /// **One model is one pill, and there is no floor.** There was, of two,
    /// for as long as the split was a list of rows under the `Today` figure:
    /// a row reading `claude-opus-5  8.1M · $8.17` under a headline reading
    /// `8.3M · $8.46` printed the same numbers twice, so a day with one model
    /// was better off silent. The pill answers a different question. It sits
    /// under the strip and what it carries that nothing else on the page does
    /// is the model's **name** — so a day spent entirely on one model is
    /// exactly the day the block is needed, because there is otherwise no
    /// surface in Sissy that says which one it was. Only the percentage is
    /// redundant at 100%, and a percentage is not what the pill is for.
    ///
    /// Empty therefore means one thing again: a provider that has read
    /// nothing.
    private static func makeModels(
        _ unordered: [ModelTotals], provider: String, totalCost: Decimal, totalTokens: Int
    ) -> [ModelRow] {
        let unpriced = unordered.contains { $0.cost == 0 && $0.tokens > 0 }
        let byCost = totalCost > 0 && !unpriced
        let total =
            byCost
            ? NSDecimalNumber(decimal: totalCost).doubleValue : Double(totalTokens)
        guard total > 0 else { return [] }
        let ordered = FrameBuilder.orderedModels(unordered)
        let rows = ordered.map { model -> ModelRow in
            let part =
                byCost
                ? NSDecimalNumber(decimal: model.cost).doubleValue : Double(model.tokens)
            return ModelRow(
                id: model.model,
                name: UsageFormat.modelName(model.model, on: provider),
                reading: UsageFormat.modelReading(
                    share: part / total,
                    cost: UsageFormat.cost(model.cost)),
                detail: UsageFormat.modelTokenDetail(
                    id: model.model,
                    input: model.totals.inputTokens,
                    output: model.totals.outputTokens,
                    cacheRead: model.totals.cacheReadTokens,
                    cacheCreation: model.totals.cacheCreationTokens)
            )
        }
        return folded(rows, of: ordered, byCost: byCost, total: total)
    }

    /// How many pills the page's width holds whole. `makeModels` carries the
    /// measurement.
    private static let modelPillLimit = 4

    /// The list as it is drawn: every pill while they fit, and otherwise the
    /// dearest few with one standing for the rest.
    private static func folded(
        _ rows: [ModelRow], of models: [ModelTotals], byCost: Bool, total: Double
    ) -> [ModelRow] {
        guard rows.count > modelPillLimit else { return rows }
        let kept = modelPillLimit - 1
        let rest = models.dropFirst(kept)
        let part = rest.reduce(0.0) {
            $0
                + (byCost
                    ? NSDecimalNumber(decimal: $1.cost).doubleValue : Double($1.tokens))
        }
        let cost = rest.reduce(Decimal(0)) { $0 + $1.cost }
        let more = ModelRow(
            id: rest.map(\.model).joined(separator: " "),
            name: UsageFormat.pillsFolded(rest.count),
            reading: UsageFormat.modelReading(
                share: total > 0 ? part / total : 0, cost: UsageFormat.cost(cost)),
            detail: rest.map(\.model).joined(separator: " · "))
        return Array(rows.prefix(kept)) + [more]
    }

    /// One pill per effort the window's turns ran at, busiest first.
    ///
    /// Drawn with `ModelPill` unchanged, and folded at `modelPillLimit` for
    /// that block's measured reason: the page is the same 312 pt wide and an
    /// effort's word is no longer than a model's.
    ///
    /// **The denominator is the turns that named an effort, not the window's
    /// turns.** A provider whose format names none contributes nothing here,
    /// and dividing by a total that counted its turns would make every pill
    /// read short — the shares would sum to a fraction of the window and say
    /// nothing about why.
    ///
    /// **A single effort's pill carries no detail.** It already says the word,
    /// the share and the count, so a hover could only repeat them — which is
    /// what `ModelPill` leaves out of its spoken label when the field is empty.
    /// The folded pill keeps one, because the efforts it stands for are the
    /// one thing it cannot show.
    ///
    /// Empty where nothing named one, which is every window whose days predate
    /// the field. A row of pills at zero would report a setting nobody chose,
    /// and an absent reading is not a reading of none — the rule the strip and
    /// the `active` figure beside it already hold.
    private static func makeEffort(_ counts: EffortCounts) -> [ModelRow] {
        let total = Double(counts.total)
        guard total > 0 else { return [] }
        let ordered = counts.ordered
        let kept = ordered.count <= modelPillLimit ? ordered.count : modelPillLimit - 1
        var rows = ordered.prefix(kept).map { share in
            ModelRow(
                id: share.effort,
                name: share.effort,
                reading: UsageFormat.effortReading(
                    share: Double(share.turns) / total, turns: share.turns),
                detail: "")
        }
        guard kept < ordered.count else { return rows }
        let rest = ordered.dropFirst(kept)
        let turns = rest.reduce(0) { $0 + $1.turns }
        rows.append(
            ModelRow(
                id: rest.map(\.effort).joined(separator: " "),
                name: UsageFormat.pillsFolded(rest.count),
                reading: UsageFormat.effortReading(share: Double(turns) / total, turns: turns),
                detail: rest.map(\.effort).joined(separator: " · ")))
        return rows
    }

    /// What the day spent outside every repository, or nil when there is none
    /// of it.
    ///
    /// Summed off the slices rather than off the combined list, because the
    /// split is per provider and the combined list is the one place that
    /// answer has already been summed away. The two agree on the total by
    /// construction — `combinedProjects` is these same rows added up.
    ///
    /// Both halves or neither. A provider republishes its project split on
    /// every read of its day where the totals beside it only move on an emit,
    /// so a coalesced emit can leave the rows describing a later instant than
    /// the header — and a remainder taken across the two has no sign worth
    /// trusting, since cache reads are most of the tokens and the least of the
    /// money. A reading that disagrees with itself is owed no line rather than
    /// a negative one.
    ///
    /// `split` is false on a provider's own page for the reason its rows carry
    /// no marks: the page's title has already named the CLI, and a mark per
    /// line would say it again.
    private static func makeResidue(_ slices: [ProviderSlice], split: Bool) -> ProjectsResidue? {
        let totalTokens = slices.reduce(0) { $0 + $1.tokens }
        let totalCost = slices.reduce(Decimal(0)) { $0 + $1.cost }
        let namedTokens = slices.reduce(0) { $0 + $1.projects.reduce(0) { $0 + $1.tokens } }
        let namedCost = slices.reduce(Decimal(0)) {
            $0 + $1.projects.reduce(Decimal(0)) { $0 + $1.cost }
        }
        guard totalTokens > namedTokens, totalCost >= namedCost else { return nil }
        let unnamed = slices.compactMap { slice -> ProviderCost? in
            let named = slice.projects.reduce(Decimal(0)) { $0 + $1.cost }
            guard slice.cost > named else { return nil }
            return ProviderCost(id: slice.id, cost: UsageFormat.cost(slice.cost - named))
        }
        return ProjectsResidue(
            tokens: UsageFormat.tokens(totalTokens - namedTokens),
            cost: UsageFormat.cost(totalCost - namedCost),
            providers: split ? unnamed : []
        )
    }

    /// One row's split, in the order the panel draws providers in rather than
    /// by what each spent.
    ///
    /// A fixed order is what lets the marks and the bar be read down a column:
    /// ordering each row by its own dearest provider puts Claude's tint on the
    /// left of one row and on the right of the next, and a reader comparing
    /// two rows has to re-read the marks to know which way round they are.
    private static func providerShares(
        _ costs: [String: Decimal], share: (Decimal) -> Double
    ) -> [ProviderShare] {
        costs
            .map { ProviderShare(id: $0.key, share: share($0.value)) }
            .sorted {
                (FrameBuilder.providerSortOrder($0.id), $0.id)
                    < (FrameBuilder.providerSortOrder($1.id), $1.id)
            }
    }

    /// What each provider spent on each path, which is the half
    /// `FrameBuilder.combinedProjects` sums away.
    private static func contributors(_ slices: [ProviderSlice]) -> [String: [String: Decimal]] {
        var out: [String: [String: Decimal]] = [:]
        for slice in slices {
            for project in slice.projects {
                out[project.path, default: [:]][slice.id, default: 0] += project.cost
            }
        }
        return out
    }

    private static let foldedProjectRowID = "sissy.projects.rest"

    private static func makeWindow(
        _ window: UsageWindow, observedAt: Date, reading: LimitsReading, now: Date
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
            pace: makePace(window, observedAt: observedAt),
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
