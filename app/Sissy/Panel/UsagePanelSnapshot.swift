import Foundation

/// Everything numeric the usage panel renders, derived from one frame. Pure
/// by construction: no AppKit, no clock, no model access, so the panel's
/// arithmetic — shares, day-over-day delta — is testable without a running
/// engine.
///
/// Totals come from the frame's raw `providers` slices rather than its
/// pre-formatted scalars, so the big number, the rows and the delta all
/// agree to the penny.
struct UsagePanelSnapshot: Equatable {
    let tokens: String
    let cost: String
    let burn: String
    let delta: TokenDelta?
    let providers: [ProviderRow]
    /// Today's spend by project, the busiest first, the tail folded into one
    /// row and whatever named no repository in a last row of its own. Empty
    /// when nothing today names a project, and the panel then draws no section
    /// rather than a heading over nothing.
    let projects: [ProjectRow]
    /// The archive line, absent when there is no archive to show.
    let history: HistoryRow?
    /// The one gauge the Overview leads on, absent when no provider reports a
    /// window at all.
    let headroom: HeadroomRow?

    /// Day-over-day change in tokens. Absent when the frame carries no
    /// yesterday yet, or when yesterday was zero and a percentage would be
    /// undefined. Note the comparison is today-so-far against yesterday's
    /// full day — daily totals are the only granularity the engine keeps.
    struct TokenDelta: Equatable {
        let percent: Int
        let direction: DeltaDirection
    }

    enum DeltaDirection: Equatable {
        case up
        case down
        case flat
    }

    /// What the archive adds up to over its window. `label` says which days
    /// that is: a window the archive does not reach back across is named by
    /// the day it starts on instead, so a three-day-old install does not
    /// present three days as a week.
    struct HistoryRow: Equatable {
        let label: String
        let tokens: String
        let cost: String
    }

    /// The tightest rate-limit window Sissy can see, and whose it is.
    ///
    /// One bar rather than every provider's every window, because the
    /// question it answers is single: is there room to keep working. The
    /// answer is whichever window has the least of it left — a session bucket
    /// at 20% says nothing while the weekly one behind it sits at 95%, and a
    /// headline that led on the roomier of the two would be reassuring and
    /// wrong. Ties go to the shorter window, which is the one that binds
    /// first.
    ///
    /// It names its provider because it can be either, and a gauge that does
    /// not say whose it is cannot be acted on.
    struct HeadroomRow: Equatable {
        let providerID: String
        let providerName: String
        let window: WindowRow
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
        let id: Int
        let label: String
        let percent: Int
        let fraction: Double
        let resetsAt: Date
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
            tokens: frame.providers.isEmpty ? frame.tokens : UsageFormat.tokens(totalTokens),
            cost: frame.providers.isEmpty ? "$\(frame.cost)" : UsageFormat.cost(totalCost),
            burn: frame.burn,
            delta: makeDelta(today: totalTokens, prevTokens: frame.prevTokens),
            providers: rows,
            projects: makeProjects(
                frame.projects, totalTokens: totalTokens, totalCost: totalCost),
            history: makeHistory(frame.history, now: now),
            headroom: makeHeadroom(rows)
        )
    }

    /// The window with the least headroom left, across every provider.
    ///
    /// Read off the rows rather than off the slices so the gauge the Overview
    /// leads on and the gauge its provider's page repeats are the same
    /// object, down to the pace: two derivations of one reading is two
    /// readings that can disagree by a rounding.
    private static func makeHeadroom(_ rows: [ProviderRow]) -> HeadroomRow? {
        var tightest: HeadroomRow?
        for row in rows {
            for window in row.windows {
                guard let held = tightest else {
                    tightest = HeadroomRow(
                        providerID: row.id, providerName: row.name, window: window)
                    continue
                }
                let binds =
                    window.percent == held.window.percent
                    ? window.id < held.window.id
                    : window.percent > held.window.percent
                if binds {
                    tightest = HeadroomRow(
                        providerID: row.id, providerName: row.name, window: window)
                }
            }
        }
        return tightest
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

    private static func makeDelta(today: Int, prevTokens: Int?) -> TokenDelta? {
        guard let prevTokens, prevTokens > 0, today > 0 else { return nil }
        let ratio = Double(today - prevTokens) / Double(prevTokens)
        let percent = Int((abs(ratio) * 100).rounded())
        if percent == 0 {
            return TokenDelta(percent: 0, direction: .flat)
        }
        return TokenDelta(percent: percent, direction: today > prevTokens ? .up : .down)
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
                notice: UsageFormat.limitsNotice(slice.limitsState)
                    .map { LimitsNotice(message: $0.message, action: $0.action) },
                account: makeAccount(slice.account, now: now),
                projects: makeProjects(
                    slice.projects, totalTokens: slice.tokens, totalCost: slice.cost)
            )
        }
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
    private static func makeProjects(
        _ projects: [ProjectTotals],
        totalTokens: Int,
        totalCost: Decimal
    ) -> [ProjectRow] {
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
                    tooltip: nil,
                    tokens: UsageFormat.tokens(rest.reduce(0) { $0 + $1.tokens }),
                    cost: UsageFormat.cost(restCost),
                    share: share(restCost)
                ))
        }
        let namedTokens = projects.reduce(0) { $0 + $1.tokens }
        let namedCost = projects.reduce(Decimal(0)) { $0 + $1.cost }
        guard totalTokens > namedTokens else { return rows }
        let unnamedCost = totalCost - namedCost
        rows.append(
            ProjectRow(
                id: Self.unattributedRowID,
                name: UsageFormat.projectsUnattributed,
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
            id: window.minutes,
            label: UsageFormat.windowLabel(minutes: window.minutes),
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
    /// that no longer exists.
    private static func makePace(_ window: UsageWindow, now: Date) -> Pace? {
        let duration = Double(window.minutes) * 60
        let remaining = window.resetsAt.timeIntervalSince(now)
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
