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
        todayTokens: Int,
        todayCost: Decimal,
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
            return DayRow(
                id: UsageReaderShared.dayFormatter.string(from: day),
                label: isToday ? "Today" : day.formatted(.dateTime.weekday(.abbreviated)),
                isToday: isToday,
                cost: cost,
                fraction: Self.share(cost, of: peak),
                title: UsageFormat.dayTitle(day),
                figures: UsageFormat.dayFigures(tokens: tokens, cost: cost))
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
    static func binding(_ windows: [WindowRow]) -> WindowRow? {
        windows.min(by: bindsSooner)
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

    /// One account a vendor's row can be switched to.
    struct AccountChoice: Equatable, Identifiable {
        let id: String
        let label: String
        let isSelected: Bool
    }

    struct ProviderRow: Equatable, Identifiable {
        let id: String
        let name: String
        /// The other accounts of this vendor, for the picker on the identity
        /// line. Empty when the vendor has one account, which is most of them
        /// — a picker over a single choice is a control that does nothing.
        let accounts: [AccountChoice]
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
        /// `€58.95 of €100.00`, or the spend alone when no cap is set.
        let amount: String
        /// Absent without a cap: a percentage of no ceiling is not a number.
        let percent: Int?
        let fraction: Double
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
    }

    struct ProjectRow: Equatable, Identifiable {
        let id: String
        /// The repository's own name — the last component of its path, which
        /// is what the user calls it.
        let name: String
        /// The account the repository is pushed to, drawn quiet in front of
        /// the name. Nil when the repository names no forge, and on the two
        /// rows that stand for no repository at all.
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
        /// What the row hovers: a repository's full path, or why a row that is
        /// not a repository is there. Nil on the folded row, which stands for
        /// several. A project path is a client's name as often as not, so the
        /// row shows the name and keeps the rest for a hover.
        let tooltip: String?
        let tokens: String
        let cost: String
        let share: Double
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

    /// `selected` names which account of each vendor to draw, keyed by vendor.
    /// A vendor it does not name, or names an account the frame no longer
    /// carries, falls back to that vendor's first account — a row must not
    /// vanish because a preference outlived the account it points at.
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
            projects: makeProjects(
                frame.projects, totalTokens: totalTokens, totalCost: totalCost)
        )
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
                accounts: slice.id == ProviderID.claudeCode
                    ? switchableAccounts(claudeAccounts) : [],
                plan: plan?.label,
                planTier: plan?.tier,
                tokens: UsageFormat.tokens(slice.tokens),
                cost: UsageFormat.cost(slice.cost),
                windows: slice.windows.map {
                    makeWindow(
                        $0, observedAt: slice.limitsObservedAt ?? now, reading: limitsReading)
                },
                windowsCaption: slice.windows.isEmpty
                    ? nil
                    : slice.limitsObservedAt.map {
                        UsageFormat.windowsCaption(observedAt: $0, now: now)
                    },
                notice: UsageFormat.limitsNotice(slice.limitsState)
                    .map { LimitsNotice(message: $0.message, action: $0.action) },
                account: makeAccount(slice.account),
                projects: makeProjects(
                    slice.projects, totalTokens: slice.tokens, totalCost: slice.cost),
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

    /// The accounts the switcher offers, or none when there is nothing to
    /// switch between. One archived account is the ordinary case and a menu
    /// with a single entry is a control that does nothing.
    private static func switchableAccounts(
        _ snapshot: ClaudeAccountRegistry.Snapshot
    ) -> [AccountChoice] {
        guard snapshot.accounts.count > 1 else { return [] }
        return snapshot.accounts.map {
            AccountChoice(
                id: $0.uuid,
                label: UsageFormat.accountLabel($0),
                isSelected: $0.uuid == snapshot.activeUUID)
        }
    }

    /// The credits row, or nil when there is nothing a reader would act on.
    ///
    /// An account with the facility switched off, and one that has spent
    /// nothing against no cap, both get no row: the section exists to answer
    /// "how much of my own ceiling have I used", and neither of those has a
    /// ceiling or a spend to report. That is most accounts, and a permanent
    /// "Not enabled" under every provider page is a row that never changes.
    private static func makeCredits(_ credits: ProviderCredits?, now: Date) -> CreditsRow? {
        guard let credits, credits.isEnabled, credits.hasCap || credits.usedMinor > 0 else {
            return nil
        }
        return CreditsRow(
            amount: UsageFormat.creditsAmount(credits),
            percent: credits.hasCap ? Int((credits.fraction * 100).rounded()) : nil,
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

    /// The busiest projects, with everything below them folded into one row
    /// and whatever named no repository in a row after that, so the section
    /// adds up to the total the header prints.
    ///
    /// The limit bounds the repositories, not the section: the remainder is
    /// not a project competing for a slot, it is the rest of the day. It is
    /// drawn only under rows that do name repositories — a section whose one
    /// row says "unattributed" is the header total with a second caption.
    ///
    /// Ordered here rather than taken on trust, because this is the function
    /// that *drops* rows: a prefix over an order nobody established folds the
    /// day's largest project into "3 more projects" as readily as its
    /// smallest. A provider folds its own day out of a dictionary, whose key
    /// order is arbitrary, so the Overview's list came out ordered — it is
    /// summed through `combinedProjects` — and a provider's own page did not.
    private static func makeProjects(
        _ unordered: [ProjectTotals],
        totalTokens: Int,
        totalCost: Decimal
    ) -> [ProjectRow] {
        let projects = FrameBuilder.orderedProjects(unordered)
        guard !projects.isEmpty else { return [] }
        let share = { (cost: Decimal) -> Double in
            guard totalCost > 0 else { return 0 }
            return NSDecimalNumber(decimal: cost).doubleValue
                / NSDecimalNumber(decimal: totalCost).doubleValue
        }
        let fits = projects.count <= projectRowLimit
        let shown = fits ? projects : Array(projects.prefix(projectRowLimit - 1))
        var rows = shown.map { project in
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
                share: share(project.cost)
            )
        }
        if !fits {
            let rest = projects.dropFirst(projectRowLimit - 1)
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
                    share: share(restCost)
                ))
        }
        let namedTokens = projects.reduce(0) { $0 + $1.tokens }
        let namedCost = projects.reduce(Decimal(0)) { $0 + $1.cost }
        // Both halves or neither. A provider republishes its project split on
        // every read of its day where the totals beside it only move on an
        // emit, so a coalesced emit can leave the rows describing a later
        // instant than the header — and a remainder taken across the two has
        // no sign worth trusting, since cache reads are most of the tokens and
        // the least of the money. A reading that disagrees with itself is
        // owed no row rather than a negative one.
        guard totalTokens > namedTokens, totalCost >= namedCost else { return rows }
        let unnamedCost = totalCost - namedCost
        rows.append(
            ProjectRow(
                id: Self.unattributedRowID,
                name: UsageFormat.projectsUnattributed,
                owner: nil,
                repository: nil,
                tooltip: UsageFormat.projectsUnattributedReason,
                tokens: UsageFormat.tokens(totalTokens - namedTokens),
                cost: UsageFormat.cost(unnamedCost),
                share: share(unnamedCost)
            ))
        return rows
    }

    private static let foldedProjectRowID = "sissy.projects.rest"
    private static let unattributedRowID = "sissy.projects.unattributed"

    private static func makeWindow(
        _ window: UsageWindow, observedAt: Date, reading: LimitsReading
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
            pace: makePace(window, observedAt: observedAt)
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
