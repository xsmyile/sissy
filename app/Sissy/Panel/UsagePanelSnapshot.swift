import Foundation

/// Everything numeric the usage panel renders, derived from one frame. Pure
/// by construction: no AppKit, no clock, no model access, so the panel's
/// arithmetic — shares, rollups — is testable without a running engine.
///
/// Every number is worded here rather than in a view, so the headline and the
/// rows under it round the same way and a test can hold both.
struct UsagePanelSnapshot: Equatable {
    let tokens: String
    let cost: String
    /// Tokens per hour so far today, nil on a day nothing has been spent on.
    let burn: String?
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
    /// The archive line, absent when there is no archive to show.
    let history: HistoryRow?
    /// The one gauge the Overview leads on, absent when no provider reports a
    /// window at all.

    /// What the archive adds up to over its window. `label` says which days
    /// that is: a window the archive does not reach back across is named by
    /// the day it starts on instead, so a three-day-old install does not
    /// present three days as a week.
    struct HistoryRow: Equatable {
        let label: String
        let tokens: String
        let cost: String
    }

    /// The window a provider is closest to running out of, or nil when it
    /// reports none.
    ///
    /// The most spent, ties to the shorter period. Not the shortest outright:
    /// a session bucket nobody has started sits at 0% with no reset, and
    /// leading on it says nothing while the weekly one behind it is full.
    static func binding(_ windows: [WindowRow]) -> WindowRow? {
        windows.max {
            $0.percent == $1.percent ? $0.minutes > $1.minutes : $0.percent < $1.percent
        }
    }

    struct ProviderRow: Equatable, Identifiable {
        let id: String
        let name: String
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
        let share: Double
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
    /// line, everything else worded and joined under it.
    ///
    /// The seat is deliberately absent — `UsageFormat.plan` has already
    /// folded it into the badge for the one vendor that publishes one, and a
    /// line repeating what the badge above it says is a line nobody reads.
    struct AccountRow: Equatable {
        let email: String?
        /// Organisation and renewal, joined. Nil when the vendor answered for
        /// neither.
        let details: String?
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
        /// What the row hovers: a repository's full path, or why a row that is
        /// not a repository is there. Nil on the folded row, which stands for
        /// several. A project path is a client's name as often as not, so the
        /// row shows the name and keeps the rest for a hover.
        let tooltip: String?
        let tokens: String
        let cost: String
        let share: Double
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
        let percent: Int
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

    static func make(frame: FrameData, now: Date = Date()) -> Self {
        let totalTokens = frame.providers.reduce(0) { $0 + $1.tokens }
        let totalCost = frame.providers.reduce(Decimal(0)) { $0 + $1.cost }
        let rows = makeRows(frame.providers, totalTokens: totalTokens, now: now)
        return Self(
            tokens: UsageFormat.tokens(frame.tokens),
            cost: UsageFormat.cost(frame.cost),
            burn: frame.burn.map(UsageFormat.burn),
            providers: rows,
            usedToday: frame.providers.count { $0.tokens > 0 },
            projects: makeProjects(
                frame.projects, totalTokens: totalTokens, totalCost: totalCost),
            history: makeHistory(frame.history, now: now)
        )
    }

    /// Nothing until the archive reaches past today: a window whose only day
    /// is the one the headline already prints is a second opinion on the same
    /// number, and the two are read seconds apart.
    private static func makeHistory(_ rollup: UsageHistoryRollup?, now: Date) -> HistoryRow? {
        guard let rollup, rollup.tokens > 0, let earliest = rollup.earliestDay,
            earliest < Calendar.current.startOfDay(for: now)
        else { return nil }
        return HistoryRow(
            label: UsageFormat.historyWindowLabel(
                days: rollup.days, earliestDay: rollup.earliestDay, now: now),
            tokens: UsageFormat.tokens(rollup.tokens),
            cost: UsageFormat.cost(rollup.cost)
        )
    }

    private static func makeRows(
        _ slices: [ProviderSlice],
        totalTokens: Int,
        now: Date
    ) -> [ProviderRow] {
        slices.map { slice in
            let plan = UsageFormat.plan(
                slice.plan, tier: slice.planTier, seat: slice.account?.seat)
            return ProviderRow(
                id: slice.id,
                name: UsageFormat.providerName(slice.id),
                plan: plan?.label,
                planTier: plan?.tier,
                tokens: UsageFormat.tokens(slice.tokens),
                cost: UsageFormat.cost(slice.cost),
                share: totalTokens > 0 ? Double(slice.tokens) / Double(totalTokens) : 0,
                windows: slice.windows.map { makeWindow($0, now: now) },
                windowsCaption: slice.windows.isEmpty
                    ? nil
                    : slice.limitsObservedAt.map {
                        UsageFormat.windowsCaption(observedAt: $0, now: now)
                    },
                notice: UsageFormat.limitsNotice(slice.limitsState)
                    .map { LimitsNotice(message: $0.message, action: $0.action) },
                account: makeAccount(slice.account, now: now),
                projects: makeProjects(
                    slice.projects, totalTokens: slice.tokens, totalCost: slice.cost),
                credits: makeCredits(slice.credits, now: now)
            )
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
    private static func makeAccount(_ account: ProviderAccount?, now: Date) -> AccountRow? {
        guard let account else { return nil }
        let details = UsageFormat.accountDetails(
            organization: account.organization, renewsAt: account.renewsAt, now: now)
        guard account.email != nil || details != nil else { return nil }
        return AccountRow(email: account.email, details: details)
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
                owner: project.owner,
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
                tooltip: UsageFormat.projectsUnattributedReason,
                tokens: UsageFormat.tokens(totalTokens - namedTokens),
                cost: UsageFormat.cost(unnamedCost),
                share: share(unnamedCost)
            ))
        return rows
    }

    private static let foldedProjectRowID = "sissy.projects.rest"
    private static let unattributedRowID = "sissy.projects.unattributed"

    private static func makeWindow(_ window: UsageWindow, now: Date) -> WindowRow {
        WindowRow(
            id: "\(window.minutes)-\(window.scope ?? "")",
            minutes: window.minutes,
            label: UsageFormat.windowLabel(minutes: window.minutes, scope: window.scope),
            percent: Int(window.usedPercent.rounded()),
            fraction: min(max(window.usedPercent / 100, 0), 1),
            resetsAt: window.resetsAt,
            pace: makePace(window, now: now)
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
    private static func makePace(_ window: UsageWindow, now: Date) -> Pace? {
        guard let resetsAt = window.resetsAt else { return nil }
        let duration = Double(window.minutes) * 60
        let remaining = resetsAt.timeIntervalSince(now)
        guard duration > 0, remaining > 0 else { return nil }
        let elapsed = min(max(duration - remaining, 0), duration)
        let progress = elapsed / duration
        guard progress >= paceFloor else { return nil }

        let expected = progress * fullWindowPercent
        return Pace(
            expectedFraction: progress,
            deltaPercent: Int((window.usedPercent - expected).rounded()),
            runsOutAt: runOut(window, elapsed: elapsed, remaining: remaining, now: now)
        )
    }

    /// When the rate so far exhausts the window, and nil when it does not
    /// before the reset.
    ///
    /// Nothing spent means no rate and therefore no run-out, which is the same
    /// answer as a rate slow enough to last: both are a window that survives
    /// its own reset, and the caption says so rather than naming a date past
    /// the one the row already prints.
    private static func runOut(
        _ window: UsageWindow,
        elapsed: TimeInterval,
        remaining: TimeInterval,
        now: Date
    ) -> Date? {
        let headroom = fullWindowPercent - window.usedPercent
        guard headroom > 0 else { return now }
        let rate = window.usedPercent / elapsed
        guard rate > 0 else { return nil }
        let untilEmpty = headroom / rate
        return untilEmpty >= remaining ? nil : now.addingTimeInterval(untilEmpty)
    }
}
