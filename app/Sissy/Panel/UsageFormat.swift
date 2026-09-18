import Foundation

/// Which end of a rate-limit window its gauge prints: what has been spent, or
/// what is still there.
///
/// A wording rather than a measurement. The vendor publishes one number and
/// both readings are that number, so this never reaches `WindowRow.percent` —
/// which is what orders the windows and what decides when the Overview's
/// figure goes orange, and both have to land in the same place whichever way
/// the user reads the bar. For the same reason the bar itself always fills
/// with what has been spent: the pace mark sits at `elapsed / duration`, and a
/// fill measured from the other end would put the mark on the wrong side of it.
enum LimitsReading: String, Codable, CaseIterable, Sendable {
    /// What the window has taken, which is what the vendor reports.
    case used
    /// What is left of it — the same reading, subtracted.
    case left
}

/// Display formatters shared by the menubar menu and the usage panel.
///
/// The only place a number on screen is worded. The frame carries the day's
/// raw totals, so rounding is the surface's business rather than the engine's
/// — which is what let the engine stop shipping a second set of formatters
/// shaped for a 128×64 display nothing renders to any more.
enum UsageFormat {
    static func tokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        }
        if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        }
        return "\(tokens)"
    }

    static func cost(_ cost: Decimal) -> String {
        String(format: "$%.2f", NSDecimalNumber(decimal: cost).doubleValue)
    }

    /// Tokens per hour, worded like any other token count. Takes a rate rather
    /// than an optional so the absence of one stays a question the caller
    /// answers: a day with no spend has no rate, and "0/h" is a claim about
    /// pace rather than the absence of one.
    static func burn(_ tokensPerHour: Double) -> String {
        tokens(Int(tokensPerHour.rounded()))
    }

    /// The line under a header's title: when the reading on screen landed, or
    /// that it is being fetched again right now.
    ///
    /// One function for both headers, so home and a provider's page cannot
    /// word the same state differently. The age is dropped rather than shown
    /// beside the word: it is about to be replaced, and a number counting up
    /// next to "refreshing" is the reading contradicting itself.
    ///
    /// `holding` is how long the Mac has been held awake, which rides this
    /// line rather than a readout of its own beside the cup: a bare duration
    /// next to a button is a number with no noun, and here it is one clause
    /// of the sentence that already dates everything else on screen. It
    /// carries that noun with it, because at the end of the line it would be
    /// a bare number again. A refresh does not take it away — the hold is not
    /// the thing being re-read.
    ///
    /// It trails rather than leads for a layout reason, not a rhetorical one:
    /// the line is left-aligned, and the hold both appears from nothing and
    /// grows a unit at the hour. Leading, every one of those shoves the age
    /// sideways under a title that has not moved. Trailing, the clause that
    /// is always there stays put and the one that comes and goes does so at
    /// the end, where nothing follows it.
    static func reading(
        age interval: TimeInterval, holding: TimeInterval?, refreshing: Bool
    ) -> String {
        let reading = refreshing ? "refreshing…" : "updated " + age(interval)
        guard let holding else { return reading }
        return reading + " · awake " + held(holding)
    }

    /// The providers block's one-line recap: how many of the CLIs Sissy is
    /// metering have spent anything today.
    ///
    /// Honest by construction — the frame carries a slice only for a provider
    /// that spent tokens today, and `metering` counts the ones a reader was
    /// actually built for, so a CLI switched off is in neither number.
    ///
    /// Nil below two providers, where it is not a recap but a restatement of
    /// the single row beneath it.
    static func providersRecap(used: Int, metering: Int) -> String? {
        guard metering > 1 else { return nil }
        return "\(used) of \(metering) used today"
    }

    /// Coarse age of the last frame, for the panel's header. Deliberately
    /// one unit and no seconds past a minute: the line is a reassurance that
    /// the reading is live, not a stopwatch.
    static func age(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        return "\(minutes / 60)h ago"
    }

    /// The status item's one keep-awake line, shown only while a hold is
    /// actually in force.
    ///
    /// The menu stopped offering the three modes once the panel carried them:
    /// what it keeps is the diagnostic, because a hold nobody can see is a
    /// battery complaint with no path back to its cause, and a right-click on
    /// the menu bar is the shortest path there is.
    static func keepAwakeHolding(_ interval: TimeInterval) -> String {
        "Keep awake — holding · " + held(interval)
    }

    /// How long the keep-awake hold has been in force, for the panel's
    /// control.
    ///
    /// A stopwatch where `age` is a reassurance, which is why the two do not
    /// share an implementation: this one keeps both units past the hour,
    /// because the distance between a hold taken an hour ago and one taken
    /// this morning is the whole point of showing it. Seconds stay out — a
    /// hold ticking by the second reads as something counting down to an
    /// event, and nothing here expires.
    static func held(_ interval: TimeInterval) -> String {
        let minutes = max(Int(interval) / secondsPerMinute, 0)
        if minutes < 1 { return "<1m" }
        if minutes < minutesPerHour { return "\(minutes)m" }
        let hours = minutes / minutesPerHour
        let remainder = minutes % minutesPerHour
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }

    /// What each keep-awake mode is called, everywhere it is offered.
    ///
    /// Three surfaces list the modes — the panel button's menu, the right-click
    /// menu and Settings — and the words have to be the same in all three or
    /// the same setting reads as two. A `switch` rather than a table so a mode
    /// added to the engine cannot compile until it has been named here.
    static func keepAwakeTitle(_ mode: KeepAwakeMode) -> String {
        switch mode {
        case .off: return "Never"
        case .auto: return "While agents are working"
        case .on: return "Always"
        }
    }

    /// The keep-awake button's tooltip: what the Mac is doing, what a click
    /// would do to it, and where the modes a click cannot reach are.
    ///
    /// Names the lid in every wording that claims the Mac stays up, because
    /// the assertion holds off *idle* sleep and nothing else: a MacBook closed
    /// on a running agent sleeps anyway, and someone who learns that from a
    /// lost run blames Sissy for it.
    ///
    /// The screen clause follows `coversScreen`, which is the effect and not
    /// the setting, so a display assertion power management refused stops this
    /// promising a screen that is already dimming. The off state claims
    /// nothing about the screen at all — what a click would hold depends on a
    /// setting this tooltip is not the place to teach.
    ///
    /// The off state *does* name the mode a click would arm, which is what
    /// `arming` carries. The button is a two-position switch over three modes
    /// and the third is invisible until it is on: someone who chose "while
    /// agents are working", switched it off and came back to a relaunched
    /// Sissy would otherwise get a permanent hold from a click that looked
    /// like the one they made last time. The gesture that reaches the other
    /// two is named on every state, and named as the right-click rather than
    /// the press — "hold" is the verb this whole control already uses for what
    /// it does to the Mac.
    static func keepAwakeHelp(_ state: KeepAwakeState, arming: KeepAwakeMode) -> String {
        let modes = " · right-click for the other modes"
        switch (state.mode, state.active) {
        case (.off, _):
            return "Keep this Mac awake, \(keepAwakeTitle(arming).lowercased()) · "
                + "closing the lid still sleeps it" + modes
        case (_, true):
            let since = state.since.map { " since \($0.formatted(.dateTime.hour().minute()))" } ?? ""
            let what =
                state.coversScreen
                ? "Keeping this Mac and its screen awake\(since), so it will not lock."
                : "Keeping this Mac awake\(since) — the screen still sleeps and locks."
            return what + " Closing the lid sleeps it anyway · click to allow sleep" + modes
        case (.auto, false):
            return "Waiting for the agents · the Mac will be held while they work · "
                + "closing the lid sleeps it anyway" + modes
        case (.on, false):
            return "Switched on · the Mac is not being held awake" + modes
        }
    }

    /// A window's gauge, in the reading the user chose.
    ///
    /// `left` is floored at zero. A vendor can report past 100% and the used
    /// reading keeps that overshoot, because there the figure above the
    /// ceiling is the honest one; from the other end it would be a negative
    /// headroom, and nobody is owed less than nothing.
    static func windowPercent(_ percent: Int, as reading: LimitsReading) -> String {
        switch reading {
        case .used: return "\(percent)%"
        case .left: return "\(max(fullWindowPercent - percent, 0))%"
        }
    }

    /// The same figure with the word that says which end of the window it is.
    ///
    /// For the tooltip, where there is room for it. On the row the bar beside
    /// it carries that, and the noun would cost the column its width.
    static func windowReading(_ percent: Int, as reading: LimitsReading) -> String {
        "\(windowPercent(percent, as: reading)) \(reading.rawValue)"
    }

    private static let fullWindowPercent = 100

    /// What the Settings picker calls each end of a window. Said in terms of
    /// the window rather than of the number — "Used" and "Left" alone are two
    /// adjectives with no subject, and the row's own label supplies it once.
    static func limitsReadingTitle(_ reading: LimitsReading) -> String {
        switch reading {
        case .used: return "What is spent"
        case .left: return "What is left"
        }
    }

    /// Compact name for a rate-limit window, derived from its length so a
    /// vendor that ships a bucket Sissy has never seen still gets a label.
    static func windowLabel(minutes: Int, scope: String? = nil) -> String {
        guard let scope, !scope.isEmpty else { return period(minutes) }
        return "\(period(minutes)) · \(scope)"
    }

    /// The two periods both vendors meter get the word they are known by;
    /// anything else is named by its length. A name rather than a duration
    /// because the row now leads with it: "5h" as a heading reads as a
    /// measurement, where "Session" says what is being measured.
    private static func period(_ minutes: Int) -> String {
        switch minutes {
        case minutesPerSession: return "Session"
        case minutesPerWeek: return "Weekly"
        default:
            if minutes % minutesPerDay == 0 { return "\(minutes / minutesPerDay)d" }
            if minutes % minutesPerHour == 0 { return "\(minutes / minutesPerHour)h" }
            return "\(minutes)m"
        }
    }

    private static let minutesPerSession = 300
    private static let minutesPerWeek = 10_080

    /// The line under a limit bar: the pace where there is one, and how long
    /// until the window rolls over, joined. Both halves are durations off the
    /// same `now`, which is what lets them be read against each other.
    ///
    /// Nil for a window the vendor has not started, which has neither — the
    /// bar at zero is the whole statement, and a caption saying so twice is
    /// noise on the one row that has nothing to report.
    ///
    /// A window that has rolled over since the reading says so instead, and in
    /// the past tense: everything else on that row describes the period that
    /// ended, and a countdown to a reset already gone counts down to nothing.
    /// It is dated through `observedLabel` rather than `resetLabel` because
    /// the question has turned from "how long has this got" into "when did
    /// this end", which is a moment rather than a duration.
    static func windowCaption(
        _ window: UsagePanelSnapshot.WindowRow,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        if window.hasRolledOver {
            guard let resetsAt = window.resetsAt else { return nil }
            let rolled = observedLabel(resetsAt, now: now, calendar: calendar)
            return "rolled over \(rolled) · awaiting a reading"
        }
        var parts: [String] = []
        if let pace = window.pace {
            parts.append(
                paceCaption(
                    deltaPercent: pace.deltaPercent, runsOutAt: pace.runsOutAt, now: now))
        }
        if let resetsAt = window.resetsAt, let label = resetLabel(resetsAt, now: now) {
            parts.append("resets " + label)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// How long a window has left, rather than the moment it ends.
    ///
    /// A clock time and a weekday both answer "when", and neither answers "how
    /// much longer" — which is the only form this reading is acted on in, and
    /// the whole of what the row is asked. The weekday could not even bound
    /// it: measured 2026-09-18 at 23:52, a session 2h 27m from its reset said
    /// "resets Sat", the same two words a window six days out would get, and
    /// Codex's own session — resetting at 04:38 the next morning — said them
    /// too. A five-hour period described as a weekday reads as a daily one.
    ///
    /// What the weekday was there for was real: the cut was the calendar day
    /// rather than a 24-hour horizon because at 22:00 a bare "01:00" three
    /// hours out reads as this morning, already past. A duration has neither
    /// failure, and it is the unit the pace beside it already speaks, so
    /// "Runs out in 1d 9h · resets in 5d 14h" is one comparison rather than
    /// two clocks the reader converts between.
    ///
    /// Nil past the reset rather than "in 0m", which is the formatter claiming
    /// a period is about to turn over when it already has. That state has its
    /// own wording, and the row draws no bar under it — a window with nothing
    /// left to count has no duration to answer in, so this says nothing rather
    /// than saying zero. Optional rather than left to the caller because the
    /// caption's own `hasRolledOver` is frozen at the snapshot while this is
    /// re-read on the clock, and only one of the two can notice the crossing.
    static func resetLabel(_ resetsAt: Date, now: Date = Date()) -> String? {
        guard resetsAt >= now else { return nil }
        return "in " + countdown(resetsAt.timeIntervalSince(now))
    }

    /// The line under a limit bar: how far off even consumption the window is,
    /// and what the rate so far does to it before the reset.
    ///
    /// "On pace" rather than "0% in reserve", which reads as a measurement of
    /// nothing. The two words for the sign are the point — a reserve is
    /// headroom still in hand, a deficit is headroom already spent — because
    /// the number alone does not say which side of the mark you are on, and
    /// the mark's colour is not available to a screen reader.
    static func paceCaption(
        deltaPercent: Int,
        runsOutAt: Date?,
        now: Date = Date()
    ) -> String {
        let standing: String
        switch deltaPercent {
        case 0: standing = "On pace"
        case ..<0: standing = "\(-deltaPercent)% in reserve"
        default: standing = "\(deltaPercent)% in deficit"
        }
        guard let runsOutAt else { return "\(standing) · Lasts until reset" }
        let left = runsOutAt.timeIntervalSince(now)
        guard left > 0 else { return "\(standing) · Out of headroom" }
        return "\(standing) · Runs out in \(countdown(left))"
    }

    /// How long until something runs out, in the two largest units that apply.
    ///
    /// Deliberately not `held`: that one is a stopwatch on a hold that never
    /// expires and stops at hours, while this counts down across days. "2d
    /// 15h" and "16h 31m" are both readings someone acts on, and a weekly
    /// window renders the first.
    static func countdown(_ interval: TimeInterval) -> String {
        let minutes = max(Int(interval) / secondsPerMinute, 0)
        if minutes >= minutesPerDay {
            let days = minutes / minutesPerDay
            let hours = (minutes % minutesPerDay) / minutesPerHour
            return hours == 0 ? "\(days)d" : "\(days)d \(hours)h"
        }
        if minutes >= minutesPerHour {
            let rest = minutes % minutesPerHour
            return rest == 0 ? "\(minutes / minutesPerHour)h" : "\(minutes / minutesPerHour)h \(rest)m"
        }
        return "\(minutes)m"
    }

    /// How far back the archive reaches, said only when it falls short of the
    /// window on screen.
    ///
    /// The control beside the number already names the period, so repeating
    /// "Last 7 days" under it adds nothing. What the control cannot say is that
    /// the archive holds four of those seven days — and a total labelled by a
    /// width it does not have is a daily average a reader computes wrong and
    /// cannot tell they did.
    ///
    /// `all` always names its first day: that day is the whole of what
    /// "everything kept" means, and without it the widest window is the one
    /// reading on the panel that never says what it covers.
    static func periodCoverage(
        _ rollup: UsageHistoryRollup,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        shortfall(
            days: rollup.period.days, earliestDay: rollup.earliestDay,
            now: now, calendar: calendar
        ).map(since)
    }

    /// Names the window a reading covers: its width while the archive reaches
    /// back across all of it, and the first day it holds once it does not.
    ///
    /// A label where `periodCoverage` is an admission. A surface that names the
    /// period elsewhere — the headline, whose control says `7 days` — wants
    /// nothing said when the archive covers it; one that names it nowhere else,
    /// like a strip of day bars, needs the width either way.
    static func historyWindowLabel(
        days: Int,
        earliestDay: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        guard
            let day = shortfall(
                days: days, earliestDay: earliestDay, now: now, calendar: calendar)
        else { return "Last \(days) days" }
        return "Since \(day.formatted(.dateTime.day().month(.abbreviated)))"
    }

    /// The first day the archive holds inside a window, when it falls short of
    /// that window, and nil when it reaches back across the whole of it.
    ///
    /// The one piece of arithmetic under both labels, so a window can never be
    /// called short by one of them and whole by the other. `days` of nil is an
    /// unbounded window, which has no width to fall short of and therefore
    /// always names its first day.
    private static func shortfall(
        days: Int?, earliestDay: Date?, now: Date, calendar: Calendar
    ) -> Date? {
        guard let earliestDay else { return nil }
        guard let days else { return earliestDay }
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: today),
            calendar.startOfDay(for: earliestDay) > start
        else { return nil }
        return earliestDay
    }

    /// Lowercase because it lands mid-line, after the tokens it qualifies.
    private static func since(_ day: Date) -> String {
        "since \(day.formatted(.dateTime.day().month(.abbreviated)))"
    }

    /// The control's own label for a window, which is the only place the period
    /// is named now that the line under the number admits coverage instead.
    ///
    /// The widest is `All`, meaning everything the archive kept — which
    /// `historyRetentionDays` bounds, at 90 days by default.
    ///
    /// It was briefly "Everything kept", because measured against an archive
    /// five days old the word promised a lifetime and delivered $2,100 where
    /// the CLI's own logs held $4,615. That was copy compensating for a
    /// defect: the archive started the day it shipped on the machine, and the
    /// label was carrying the apology. #151 fixes the cause, and `All` is then
    /// true of what Sissy holds. The number of days stays out of the label
    /// either way — the retention is a ceiling rather than what is there, so
    /// naming it would be a larger promise than `All` ever was, and the
    /// coverage line under the number is what admits a short archive.
    static func periodLabel(_ period: UsagePeriod) -> String {
        switch period {
        case .today: "Today"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .all: "All"
        }
    }

    /// Names the window a strip of day bars covers, and says how much of it
    /// the archive actually answers for.
    ///
    /// The coverage half is not decoration. The strip has a bar's worth of
    /// space per day and no axis, so a day Sissy was not running for is a
    /// small mark that a reader can take for a quiet day. Counting the days
    /// that carry a reading is what makes the difference legible without
    /// putting a legend under a seven-bar chart.
    static func dayStripLabel(
        days: Int,
        covered: Int,
        earliestDay: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let window = historyWindowLabel(
            days: days, earliestDay: earliestDay, now: now, calendar: calendar)
        guard covered < days else { return window }
        return "\(window) · \(covered) of \(days) days"
    }

    /// A day bar's own name, which the strip's header takes while the pointer
    /// is on that bar.
    static func dayTitle(_ day: Date) -> String {
        day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// A day bar's own figures, since the strip carries no axis to read one
    /// off.
    ///
    /// A day with no reading says what happened rather than naming a figure:
    /// the archive holds nothing for a day Sissy was not running, and "—"
    /// there would read as a day that cost nothing.
    static func dayFigures(tokens: Int?, cost: Decimal?) -> String {
        guard let tokens, let cost else { return "Sissy was not running" }
        return "\(self.tokens(tokens)) · \(self.cost(cost))"
    }

    private static let secondsPerMinute = 60
    private static let minutesPerHour = 60
    private static let minutesPerDay = 1440

    /// The plan as the badge says it, plus the limit tier when the tier
    /// belongs to a different plan than the account's own.
    ///
    /// A Max account metered at `max_5x` reads as one thing, "Max 5x". A Team
    /// seat metered at the same tier does not: "Team 5x" is a plan nobody
    /// sells, so the badge stays "Team" and the tier goes to the row's
    /// tooltip. Folding is therefore conditional on the tier naming the plan
    /// it decorates.
    static func plan(_ plan: String?, tier: String?, seat: String? = nil) -> (
        label: String, tier: String?
    )? {
        guard let plan, let label = words(plan) else { return nil }
        let named = seatLabel(plan: plan, seat: seat) ?? label
        let parts = tierParts(tier)
        guard let base = parts.base else { return (named, nil) }
        if base == plan {
            return (parts.multiplier.map { "\(named) \($0)" } ?? named, nil)
        }
        guard let baseLabel = words(base) else { return (named, nil) }
        return (named, parts.multiplier.map { "\(baseLabel) \($0)" } ?? baseLabel)
    }

    /// Anthropic's two Team seats, and the words it sells them under. The
    /// plan alone reads as one product where the seats are priced and
    /// entitled differently, and "Team" is what someone on either one sees
    /// today.
    private static let teamSeatLabels = [
        "team_standard": "Team Standard",
        "team_tier_1": "Team Premium",
    ]

    private static let teamPlanToken = "team"

    /// The seat the account holds, where the vendor's token names one this
    /// build knows.
    ///
    /// A map, which everything else here refuses to be — with the one
    /// property that makes this one safe: an unknown token falls back to the
    /// plan's own label, which is exactly what renders today. A seat a vendor
    /// ships tomorrow therefore costs a word rather than a wrong one, and no
    /// release. It decorates `team` alone, so it cannot rename a plan the
    /// account is not on.
    private static func seatLabel(plan: String, seat: String?) -> String? {
        guard plan == teamPlanToken, let seat else { return nil }
        return teamSeatLabels[seat]
    }

    /// A vendor token as words: `plus` → "Plus", `edu_plus` → "Edu Plus".
    /// Derived rather than mapped for the same reason as
    /// `windowLabel(minutes:)` — the two CLIs between them publish a dozen
    /// tiers and add to the list without asking, and a table here would show
    /// nothing for the one that arrived after the release. Both vendors emit
    /// lowercase `snake_case`, and the engine passes the token through
    /// verbatim.
    private static func words(_ token: String) -> String? {
        let parts = token.split(separator: "_").map { $0.capitalized }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Splits a tier into the plan it meters and the multiplier on it:
    /// `max_5x` → (`max`, "5x"), `pro` → (`pro`, nil). The multiplier is
    /// recognised by shape rather than by a list, and stays verbatim — "5X"
    /// is not how anyone writes it.
    private static func tierParts(_ tier: String?) -> (base: String?, multiplier: String?) {
        guard let tier, !tier.isEmpty else { return (nil, nil) }
        guard let separator = tier.lastIndex(of: "_") else { return (tier, nil) }
        let suffix = String(tier[tier.index(after: separator)...])
        guard suffix.hasSuffix("x"), suffix.count > 1,
            suffix.dropLast().allSatisfy(\.isNumber)
        else { return (tier, nil) }
        return (String(tier[tier.startIndex..<separator]), suffix)
    }

    /// What a provider row says when its limits are missing for a reason
    /// somebody can act on, and what the control beside it offers.
    ///
    /// Every wording names what to do rather than what failed: the log
    /// already had the diagnosis and nobody read it. `.quiet` is the common
    /// case and says nothing at all — a row that explains itself every time
    /// it is fine is a row nobody reads when it is not.
    ///
    /// The one wording that names neither is the vendor refusing to answer,
    /// because there is nothing to do and no button that would help — and it
    /// is still the most important of them, since it is the only state where
    /// the windows themselves stay on screen with an age that keeps growing.
    ///
    /// Its deadline is a clock time and deliberately not `resetLabel`: the
    /// sentence says "until", which takes a moment, where that one answers in
    /// how long. The two were once the same call, and it read the deadline in
    /// whole days — measured, a 1800 s block beginning at 23:50 said "until
    /// Fri", which is the same half-hour described as two days.
    /// Why a row has no reading, in the vendor's own words.
    ///
    /// Provider-aware because every sentence here names something: the CLI
    /// that is signed out, the vendor that is refusing, the sign-in that has
    /// ended. Said in one vendor's vocabulary they are worse than silence — a
    /// Codex row reading "Claude Code is not signed in on this Mac" sends
    /// somebody to fix the wrong terminal.
    static func limitsNotice(
        _ state: ProviderLimitsState,
        provider: String
    ) -> UsagePanelSnapshot.LimitsNotice? {
        let cli = providerName(provider)
        let isCodex = provider == ProviderID.codex
        let vendor = isCodex ? "OpenAI" : "Anthropic"
        switch state {
        case .quiet:
            return nil
        case .needsAuthorization:
            // Two different items: the CLI's own token for Claude Code, and
            // the sign-in Sissy holds for a linked account. Both are read out
            // of the keychain and both recover on one click.
            let secret = isCodex ? "this account's sign-in" : "\(cli)'s token"
            return .init(
                message: "Sissy needs your permission to read \(secret) again",
                action: "Allow", kind: .refresh)
        case .refused:
            return .init(
                message: "Keychain access was refused, so the limits stay hidden",
                action: "Try again", kind: .refresh)
        case .signedOut:
            return .init(
                message: "\(cli) is not signed in on this Mac", action: nil, kind: .refresh)
        case .sessionExpired:
            let ended = isCodex ? "The OpenAI sign-in" : "The claude.ai session"
            return .init(message: "\(ended) has ended", action: "Link again", kind: .link)
        case .credentialRefused:
            // No action, deliberately. The credential is Claude Code's own and
            // the CLI rotates it on its own schedule, so every button this row
            // could carry would either do nothing or send someone to re-link
            // an account that is not linked.
            return .init(
                message: "\(vendor) refused \(cli)'s sign-in, so the limits stay hidden "
                    + "until the CLI renews it",
                action: nil, kind: .refresh)
        case .rateLimited(let until):
            return .init(
                message: "\(vendor) is not answering for limits until "
                    + until.formatted(.dateTime.hour().minute()),
                action: nil, kind: .refresh)
        }
    }

    /// Why a provider's page shows no limit windows, when nothing went wrong.
    ///
    /// The blank is not a fault and must not read as one. On Codex the
    /// windows ride the CLI's own events, so an idle session simply has not
    /// sent one; on Claude Code they come off a poll of the credential the CLI
    /// already keeps, so the first reading may not have landed yet. Neither
    /// sentence may send anyone to Settings: the switch that used to gate
    /// Claude's limits is gone, and a caption pointing at a control that is
    /// not there is worse than the blank it was explaining.
    static func noWindowsCaption(_ id: String) -> String {
        switch id {
        case ProviderID.claudeCode:
            return "Waiting for the first reading of this account's windows."
        case ProviderID.codex:
            return "Codex reports its limits on its own turns — the next one fills this in."
        default:
            return "This provider reports no subscription limits."
        }
    }

    /// When the windows on screen were taken.
    ///
    /// The gauges get an age for the reason the credits row does: neither is
    /// fetched on demand. Codex publishes its buckets on its own turns, so a
    /// Mac left idle shows numbers from the last one; Claude's come off a poll
    /// five minutes apart. Without this the only date on the page is the
    /// frame's, which the *other* provider's activity moves — a Codex turn
    /// landing made an untouched Claude window read as just updated.
    static func windowsCaption(
        observedAt: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        "Read " + observedLabel(observedAt, now: now, calendar: calendar)
    }

    /// What a provider's status row says.
    ///
    /// The vendor's own sentence wherever there is one, so a wording it
    /// changes needs no release. Sissy only words the one case the vendor
    /// cannot: a feed that has never answered, which is a gap in Sissy's
    /// reading and deliberately not an outage.
    static func statusLabel(_ description: String?) -> String {
        let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return "Status unavailable" }
        return trimmed
    }

    /// How long ago Sissy read that page — never how long ago the vendor
    /// touched it.
    ///
    /// Measured 2026-09-15: OpenAI's own `updated_at` read `2026-07-09`,
    /// because it moves on incidents rather than on polls. It is also what
    /// makes a failed poll honest, since a fetch that fails publishes nothing
    /// and this age is then the only thing on the row that moves.
    static func statusAge(checkedAt: Date, now: Date = Date()) -> String {
        "checked " + age(now.timeIntervalSince(checkedAt))
    }

    /// One component's own status, worded.
    ///
    /// The vendor's tokens where they are known, and a humanised form of
    /// whatever else arrives — `partial_outage` reads "Partial outage" either
    /// way, so a vocabulary a vendor extends still prints as itself rather
    /// than as a blank or as the raw token. That is the same division `plan`
    /// is on: the token travels, the app words it, and no release is needed
    /// for a new one.
    static func componentStatus(_ raw: String) -> String {
        switch raw {
        case "operational": return "Operational"
        case "degraded_performance": return "Degraded"
        case "partial_outage": return "Partial outage"
        case "major_outage": return "Major outage"
        case "full_outage": return "Full outage"
        case "under_maintenance": return "Maintenance"
        default: return humanised(raw)
        }
    }

    private static func humanised(_ raw: String) -> String {
        let words = raw.split(separator: "_").joined(separator: " ")
        guard let first = words.first else { return raw }
        return first.uppercased() + words.dropFirst()
    }

    /// The whole status row as one sentence, for the tooltip and for
    /// VoiceOver — which is what keeps the colour on the Overview's provider
    /// name from being the only carrier of it.
    static func statusSummary(
        provider: String, label: String, checkedAt: Date?, now: Date = Date()
    ) -> String {
        let head = "\(providerName(provider)) · \(label)"
        guard let checkedAt else { return head }
        return head + " · " + statusAge(checkedAt: checkedAt, now: now)
    }

    /// What pressing refresh on a provider actually does, said before it is
    /// pressed.
    ///
    /// The two are not the same action and the button must not pretend they
    /// are: on Claude Code it re-reads the keychain with the dialog allowed,
    /// which is a permission prompt someone is about to meet. On Codex the
    /// limits ride the CLI's own events, so no button can make them arrive —
    /// all a refresh can honestly touch is the account and the plan.
    static func refreshHelp(_ id: String) -> String {
        switch id {
        case ProviderID.claudeCode:
            return "Read the limits again · may ask for keychain access"
        case ProviderID.codex:
            return "Read the account again · the limits arrive with the next Codex turn"
        default:
            return "Read this provider again"
        }
    }

    /// What a provider's row is called.
    ///
    /// The name of the account, not of the CLI that logs it — which is why
    /// Anthropic's is "Claude" and not "Claude Code". The row carries an
    /// address, an organisation and a plan, and every one of those belongs to
    /// a Claude account rather than to the binary that wrote the JSONL; the
    /// status feed this will grow is `status.claude.com`, which is the same
    /// account's service. It also puts the pair on one footing, since "Codex"
    /// is already how that one is said.
    ///
    /// Everything that talks about the *CLI* keeps the CLI's full name:
    /// whose token is in the keychain, what is not signed in on this Mac,
    /// which switch turns the limits on. Those sentences are about Claude
    /// Code, and shortening them there would make them wrong — a Mac with
    /// Claude open in a browser and no CLI installed is exactly the case
    /// "Claude is not signed in" would misreport.
    static func providerName(_ id: String) -> String {
        switch id {
        case ProviderID.claudeCode: return "Claude"
        case ProviderID.codex: return "Codex"
        default: return id
        }
    }

    /// What a row is called when the same vendor answers for more than one
    /// account.
    ///
    /// The vendor's name alone stops identifying a row the moment a second
    /// account of it appears, and two rows both reading "Claude" is the
    /// failure this whole feature exists to remove — one of them is a work
    /// seat and the user cannot tell which. The qualifier is the account's own
    /// organisation, which is the name the vendor itself puts on it and the
    /// one the user recognises; an account that names none falls back to the
    /// local part of its address, and one that names neither to the key it was
    /// added under, because a row has to be callable something.
    ///
    /// Deliberately not applied when a vendor has one account: the overwhelming
    /// majority of installs have exactly that, and "Claude · Personal" on a Mac
    /// with one Claude account is noise dressed as information.
    static func providerName(_ id: String, distinguishedBy account: ProviderAccount?) -> String {
        let name = providerName(id)
        guard let qualifier = accountQualifier(id, account: account) else { return name }
        return "\(name) · \(qualifier)"
    }

    /// What one account is called in the switcher.
    ///
    /// The address is what a user recognises an account by — it is what they
    /// typed to sign in — with the organisation behind it for an account whose
    /// address the vendor does not report. An account the vendor named neither
    /// for falls back to its own id rather than to the CLI's name, because two
    /// such accounts would otherwise render the same word and the menu would
    /// offer a choice nobody could make.
    static func accountLabel(_ identity: ClaudeAccountIdentity) -> String {
        accountLabel(identity.providerAccount) ?? identity.uuid
    }

    /// The same rule for a reading's own account, which is what a row that has
    /// one is named from. Nil where the vendor answered for neither, so the
    /// caller falls back to the uuid rather than printing an empty row.
    static func accountLabel(_ account: ProviderAccount?) -> String? {
        if let email = account?.email, !email.isEmpty { return email }
        if let organization = account?.organization, !organization.isEmpty { return organization }
        return nil
    }

    private static func accountQualifier(_ id: String, account: ProviderAccount?) -> String? {
        if let organization = account?.organization, !organization.isEmpty { return organization }
        if let email = account?.email, let local = email.split(separator: "@").first {
            return String(local)
        }
        return nil
    }

    /// What a project is called: the last component of its path, which is the
    /// repository's own name. Two unrelated repositories sharing a basename
    /// render the same label and are told apart by the tooltip — the accepted
    /// cost of a row that reads like the name the user uses.
    static func projectName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// Always plural: the fold only happens past the row limit, and folding a
    /// single leftover would save no row, so the folded row never stands for
    /// fewer than two projects.
    static func projectsFolded(count: Int) -> String {
        "\(count) more projects"
    }

    /// How long the list behind a section's own row is. Singular at one,
    /// because that row is a sentence rather than a figure.
    static func projectsCount(_ count: Int) -> String {
        count == 1 ? "1 project" : "\(count) projects"
    }

    /// What the projects page says under its title: the day it is of, how many
    /// repositories it names, and what that day came to.
    ///
    /// The day's own total rather than the headline's. The headline is over
    /// whatever period the control is set to and these rows are today's alone,
    /// so repeating it here would put one window's money over another's rows.
    static func projectsSubtitle(count: Int, cost: Decimal) -> String {
        "today · \(projectsCount(count)) · \(self.cost(cost))"
    }

    /// The projects page with nothing on it, which is a day that has spent
    /// nothing yet rather than a page that failed to load. Reachable only by
    /// a day rolling over under an open page, since the row that opens it
    /// belongs to a section that does not exist while the list is empty.
    static let projectsEmpty = "Nothing today names a repository yet."

    /// What the rest of the day is called when no row can name it, as the line
    /// under the list says it. Deliberately not a name: the money was counted,
    /// and the one thing Sissy will not do is invent a repository for it.
    ///
    /// The `+` is the whole of why a figure may sit under a list without being
    /// in it — it says the line adds to the rows above rather than standing
    /// beside them, which is what a list read against a total needs to close.
    static func projectsUnattributed(tokens: String, cost: String) -> String {
        "+ \(tokens) · \(cost) unattributed"
    }

    /// Why a row that is not a repository is in the list, for the hover. Both
    /// halves are real and neither is a fault: a CLI that works out of its own
    /// scratch directory never names one, and a checkout deleted since cannot
    /// be walked up from any more.
    static let projectsUnattributedReason =
        "Counted in the total, but its working directory names no repository — "
        + "a CLI's own scratch directory, or a checkout deleted since."
    /// The credits headline: what has been charged, against the cap when one
    /// is set.
    ///
    /// Both halves go through the account's own currency rather than the
    /// machine's, because the cap is a figure the user typed on the vendor's
    /// site and a euro rendered as a dollar is a different number.
    ///
    /// A vendor answering only for what is left leads on the balance instead:
    /// there is no spend to put first and no cap to put it against, and the
    /// figure someone opens this section for is the one they have.
    ///
    /// Nil where the reading names neither, which is a reading of nothing — an
    /// empty headline over a bar and a caption would say the vendor answered
    /// and hide what it answered with.
    static func creditsAmount(_ credits: ProviderCredits) -> String? {
        guard let used = credits.used else {
            return credits.balance.map { amount($0, in: credits.unit) }
        }
        let spent = amount(used, in: credits.unit)
        guard let cap = credits.cap, credits.hasCap else { return spent }
        return "\(spent) of \(amount(cap, in: credits.unit))"
    }

    /// The credits headline: the figure, and the share of the cap it is where
    /// the vendor named a cap to take a share of.
    ///
    /// The two sit together because the second is a percentage *of* the first,
    /// and because a vendor that answers a balance and no ceiling — which is
    /// Codex on every block measured — has only the one figure to print. A
    /// percentage that had to be suppressed separately would be a second place
    /// to remember that.
    static func creditsReading(amount: String, percent: Int?) -> String {
        guard let percent else { return amount }
        return "\(amount) · \(percent)%"
    }

    /// The line under the credits bar: what is left, and when the vendor last
    /// answered.
    ///
    /// The age is not decoration. The figure is read out of the cache the CLI
    /// keeps, so it is only ever as current as that CLI's last fetch, and a
    /// spend shown without one is a claim of being live that this source
    /// cannot make.
    static func creditsCaption(
        _ credits: ProviderCredits,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        var parts: [String] = []
        if credits.capReached {
            parts.append("Cap reached")
        } else if let remaining = credits.remaining, credits.hasCap {
            parts.append("\(amount(remaining, in: credits.unit)) left")
        }
        if let balance = credits.balance, credits.usedMinor != nil {
            parts.append("\(amount(balance, in: credits.unit)) prepaid")
        }
        parts.append(observedLabel(credits.observedAt, now: now, calendar: calendar))
        return parts.joined(separator: " · ")
    }

    /// When a cached reading was taken. A clock time for today, the weekday
    /// and the time once it is not.
    ///
    /// A moment rather than the elapsed duration `resetLabel` answers in: a
    /// reading dated "3d 4h ago" is a subtraction the reader has to undo to
    /// place it, where a reset is only ever asked how far off it is.
    static func observedLabel(
        _ observedAt: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        if calendar.isDate(observedAt, inSameDayAs: now) {
            return observedAt.formatted(.dateTime.hour().minute())
        }
        return observedAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// One credits figure in the unit its vendor answered in.
    ///
    /// The count keeps two decimals at most and prints none it does not need,
    /// where the money keeps exactly two: a balance is a quantity and `0.00`
    /// credits reads as money that is not money, while a price with one
    /// decimal reads as a typo.
    private static func amount(_ value: Decimal, in unit: CreditsUnit) -> String {
        switch unit {
        case .money(let currency, _):
            return value.formatted(.currency(code: currency).precision(.fractionLength(2)))
        case .credits:
            let count = value.formatted(.number.precision(.fractionLength(0...2)))
            return value == 1 ? "\(count) credit" : "\(count) credits"
        }
    }
}

/// How the panel words an account of a vendor that has more than one.
extension UsageFormat {
    /// A vendor's name with the account qualifying it, for the Overview row
    /// that has to tell two accounts of one vendor apart.
    ///
    /// The organisation rather than the address: it is shorter, it is what the
    /// user calls the account, and an email would push every track right by
    /// however long that address happens to be. The label is the fallback for
    /// a personal account, which names no organisation.
    static func accountQualifiedName(
        _ provider: String, organization: String?, fallback: String
    ) -> String {
        "\(provider) · \(organization ?? fallback)"
    }

    /// Said on the page of an account Sissy knows but holds no reading for:
    /// it has an archived credential and no live source, which is every
    /// account signed into this CLI that has not had a session linked to it.
    ///
    /// Worded as a state rather than an instruction while the control that
    /// would fix it does not exist yet. A sentence telling someone to press a
    /// button that is not there is worse than one that simply says what is
    /// true.
    /// The organisations of one account, labelled for someone choosing between
    /// them.
    ///
    /// The plan rather than the name, because claude.ai auto-generates the
    /// name of the organisation a personal plan comes with and does it in more
    /// than one shape — measured 2026-09-16, `<name>'s Individual Org` on one
    /// account and `<email>'s Organization` on another. Recognising that from
    /// the string would be a regex over the vendor's English copy; the plan is
    /// a field, and it is the same token the badge beside the account is
    /// already worded from.
    ///
    /// The name comes back only where it is needed: two organisations on one
    /// plan are told apart by nothing else, and an organisation whose plan the
    /// vendor did not name has only its name to go on.
    static func organizationChoices(
        _ organizations: [ClaudeWebOrganization]
    ) -> [(id: String, label: String)] {
        let labels = organizations.map { plan($0.plan, tier: nil, seat: nil)?.label }
        var counts: [String: Int] = [:]
        for label in labels.compactMap({ $0 }) { counts[label, default: 0] += 1 }
        return zip(organizations, labels).map { organization, label in
            guard let label else { return (organization.id, organization.name) }
            guard counts[label] == 1 else {
                return (organization.id, "\(label) · \(organization.name)")
            }
            return (organization.id, label)
        }
    }

    /// What a workspace is called where one has to be picked or named.
    ///
    /// The vendor's own name, with what it *is* beside it only when that adds
    /// something: a personal account and a workspace can share a name on one
    /// login, and `personal` is the word OpenAI itself uses. A structure this
    /// build does not know is printed humanised rather than dropped, the same
    /// rule a status token takes.
    static func workspaceLabel(_ workspace: CodexWorkspace) -> String {
        guard let structure = workspace.structure, !structure.isEmpty,
            structure.lowercased() != workspace.name.lowercased()
        else { return workspace.name }
        return "\(workspace.name) · \(humanised(structure))"
    }

    static let unlinkedAccountCaption =
        "Sissy has no live source for this account, so it cannot read its limits."

    // MARK: Git identities

    /// Who a commit in a repository would be signed as, or why nobody would.
    ///
    /// A failure is quoted rather than reworded: git's own sentence names the
    /// condition precisely — dubious ownership, a missing directory, a
    /// repository it will not open — and a paraphrase would lose the part the
    /// user has to act on.
    static func identityAuthor(_ reading: GitIdentityReading) -> String {
        switch reading {
        case .author(let author):
            return "\(author.name) <\(author.email)>"
        case .unset:
            return "No identity resolves here — git would refuse the commit"
        case .unreadable(let message):
            let first = message.split(separator: "\n").first.map(String.init) ?? message
            return first.isEmpty ? "Git could not read this repository" : first
        }
    }

    /// Where the address came from, which is the half that says what to change.
    static func identityOrigin(_ origin: GitConfigOrigin) -> String {
        "\(origin.scope) · \(origin.file)"
    }

    /// What the forge expects, for a repository that does not meet it.
    ///
    /// The count is what makes it evidence rather than an opinion: a row that
    /// merely says a name is wrong is a rule the user has to take on trust,
    /// where one that says how many repositories on that forge disagree can be
    /// checked.
    static func identityExpectation(_ verdict: GitIdentityVerdict, host: String?) -> String? {
        guard case .unexpected(let expected, let agreeing) = verdict else { return nil }
        let forge = host ?? "this forge"
        let repositories = agreeing == 1 ? "repository" : "repositories"
        return "\(forge) — \(agreeing) \(repositories) there commit as \(expected.name)"
    }

    /// The Overview's one line, and nothing at all where every repository
    /// agrees with its forge.
    ///
    /// One repository is named, because naming it is the whole of the
    /// remaining work; several are counted, because a list does not fit a line
    /// and the page behind it is where a list belongs.
    static func identityAlert(_ unexpected: [String]) -> String? {
        switch unexpected.count {
        case 0: return nil
        case 1: return "\(unexpected[0]) commits under an unexpected name"
        default: return "\(unexpected.count) repositories commit under an unexpected name"
        }
    }

    /// The control that opens the repositories the page did not need to show.
    static func identityDisclosure(all: Int) -> String {
        "Show all \(all)"
    }

    /// What the page says under its rows.
    ///
    /// The count is of what was read, not of what the ledger holds: a checkout
    /// that has been deleted is not a repository that went unchecked, and
    /// counting it would make the page claim a shortfall it does not have.
    static func identityFooter(checked: Int) -> String {
        "\(checked) \(checked == 1 ? "repository" : "repositories") checked"
    }

    // MARK: Agents

    /// Bytes at the grain a person reads them at, which is one decimal up to
    /// a gigabyte and one above it.
    ///
    /// Base ten rather than base two, because this is the figure sitting
    /// beside Activity Monitor's and macOS has counted in base ten since
    /// 10.6. A reading that said `1.81 GB` where the system says `1.94 GB`
    /// would look like Sissy measuring something else.
    static func bytes(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if value >= 1_000_000_000 {
            return String(format: "%.2f GB", value / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.0f MB", value / 1_000_000)
        }
        return String(format: "%.0f KB", value / 1_000)
    }

    /// The Overview's one line about agents, and the Stats page's headline.
    ///
    /// Names what is running rather than what it costs: the row exists to
    /// answer whether there is room to keep working, which is the same
    /// question the gauges above it answer on a different axis.
    static func agentsRunning(_ count: Int, footprint: UInt64) -> String {
        "\(count) \(count == 1 ? "agent" : "agents") · \(bytes(footprint))"
    }

    /// What the agents have started alongside themselves — a build, a dev
    /// server, a language server.
    ///
    /// Measured 2026-09-18, eight agents held 1.94 GB and the trees under them
    /// 4.88 GB, so this is not a rounding on the figure above it but the other
    /// half of the answer to why a Mac is struggling.
    static func agentsWithChildren(_ tree: UInt64) -> String {
        "\(bytes(tree)) with what they started"
    }

    /// One count, worded so a reading of none is not mistaken for a reading
    /// that has not happened. The dash is the caller's.
    static func agentCount(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    /// The window a series of memory samples covers, which begins when Sissy
    /// did: a reading from a Mac that was asleep is not a low reading, it is
    /// no reading.
    /// What a running agent's row is called: the repository it is working in,
    /// rendered as its last component exactly as a project row is.
    ///
    /// A directory git could not name a repository for gets the vendor's name
    /// instead of the path. A CLI's own scratch area is not a project, and a
    /// row named after a path Sissy cannot verify is the invented attribution
    /// `ProjectResolver` refuses to make.
    static func agentProcessName(_ row: UsagePanelSnapshot.AgentsBlock.Process) -> String {
        guard let project = row.project else { return providerName(row.provider) }
        return (project as NSString).lastPathComponent
    }

    /// How long a process has been up, at the grain a person reads it: minutes
    /// under an hour, hours and minutes under a day, days and hours above.
    ///
    /// Deliberately *not* called time worked. A process says nothing about
    /// which of its minutes were spent on a turn, and an agent left open
    /// overnight has been up for twelve hours and working for none of them.
    static func agentUptime(since started: Date, now: Date = Date()) -> String {
        let seconds = max(now.timeIntervalSince(started), 0)
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    static func samplesSince(_ since: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("jm")
        return "since \(formatter.string(from: since))"
    }

    /// A worked duration, in the shape the figure beside it is read at a
    /// glance: `12h03` above an hour, `47m` below one.
    ///
    /// Zero-padded minutes above the hour so a column of days stays aligned
    /// and `9h05` cannot be misread as `9h50`.
    ///
    /// Deliberately not `countdown`, on the grounds that one is deliberately
    /// not `held`: that reads "12h 3m", two tokens sized to what is left of
    /// something, where this is a headline figure standing beside two counts
    /// and changing width with the window a click away — `78h12` for a week.
    static func workedDuration(minutes: Int) -> String {
        let clamped = max(minutes, 0)
        guard clamped >= minutesPerHour else { return "\(clamped)m" }
        return String(format: "%dh%02d", clamped / minutesPerHour, clamped % minutesPerHour)
    }

    /// What the strip under the figure says, which is everything the picture
    /// cannot: how the day broke up, how much of it was delegated, and what an
    /// hour of it cost.
    ///
    /// The sub-agent share is dropped where there is none rather than printed
    /// as zero — a day nothing was delegated on is most days, and a clause
    /// that never changes is one nobody reads. The rate is dropped under an
    /// hour, where dividing a few minutes into a day's spend invents a figure
    /// that swings by the minute.
    static func activityCaption(_ activity: ActivityTotals, cost: Decimal) -> String {
        var parts = [agentCount(activity.blocks, singular: "block", plural: "blocks")]
        if activity.delegatedMinutes > 0 {
            parts.append(
                "\(workedDuration(minutes: activity.delegatedMinutes)) of it sub-agents")
        }
        if activity.activeMinutes >= minutesPerHour, cost > 0 {
            let hours = Double(activity.activeMinutes) / Double(minutesPerHour)
            parts.append("\(hourlyRate(NSDecimalNumber(decimal: cost).doubleValue / hours))/h")
        }
        return parts.joined(separator: " · ")
    }

    /// What an hour of the window cost.
    ///
    /// Whole dollars above ten, against the `$0.00` every other money figure
    /// on this panel wears: those are amounts that were actually charged,
    /// where this is a division by a duration measured to the minute, and
    /// cents on it would be a precision the reading does not have.
    private static func hourlyRate(_ perHour: Double) -> String {
        perHour >= wholeDollarRateFloor
            ? String(format: "$%.0f", perHour) : String(format: "$%.2f", perHour)
    }

    private static let wholeDollarRateFloor: Double = 10
}

/// What a failed account switch says.
///
/// Each case is a different thing for the user to do, which is why they are
/// not one sentence: an account that has never signed in needs a login, and a
/// keychain that said no needs the user to allow it.
enum ClaudeAccountSwitchCopy {
    /// Asked before the credential is written, because the write reaches a
    /// program that is not Sissy and a menu item that does it silently is a
    /// footgun whatever its tooltip says.
    static func confirmTitle(_ label: String) -> String {
        "Switch Claude Code to \(label)?"
    }

    /// The sentence a user cannot work out for themselves, measured
    /// 2026-09-16: Claude Code holds its account for the life of a session and
    /// rewrites the credential on every token refresh, so a `claude` that is
    /// already running puts its own account back within minutes. Sissy cannot
    /// prevent that — the slot is the CLI's — so the only honest thing is to
    /// say it before the switch rather than let the row quietly revert.
    static let confirmBody =
        "Your next `claude` starts as it. A session that is already open will switch it back "
        + "when it next refreshes its token, so quit it first."

    /// Said on the same row as the two buttons: the account being left is not
    /// lost, which is the whole reason this is safe to offer at all.
    static let confirmReassurance = "Sissy keeps the account you are leaving."

    static let useInCLI = "Use in CLI"
    /// Marks the account the CLI is on, which is the one whose future spend
    /// lands in the day beside it. Only shown once there is more than one.
    static let signedInBadge = "· in CLI"
    static let confirmAction = "Switch"
    static let confirmCancel = "Cancel"

    /// Shown while the credential is written and the reading behind it
    /// re-read. It is a keychain write plus a network round trip, so without
    /// it the panel sits unchanged for seconds and the click reads as nothing.
    static func switching(_ label: String) -> String {
        "Switching to \(label)…"
    }

    static func failure(_ why: ClaudeAccountRegistry.Failure) -> String {
        switch why {
        case .notArchived:
            return "Sissy has no saved sign-in for that account yet. Sign into it once with claude /login"
        case .keychain:
            return "The keychain would not accept the change, so the signed-in account is unchanged"
        }
    }
}

/// How the panel words a connected forge's two counters.
extension UsageFormat {

    /// The name a forge answers to on a row and in a control.
    static func forgeName(_ kind: ForgeKind) -> String {
        switch kind {
        case .gitHub: "GitHub"
        case .gitLab: "GitLab"
        }
    }

    /// A contribution or merge count, grouped and never abbreviated.
    ///
    /// Deliberately not `tokens`, which compacts: a token count is read as a
    /// magnitude where these are read as exact figures, and "1.2K
    /// contributions" is the same as not answering. Four digits is the widest
    /// a year of them reaches — measured 2026-09-17, 4125 and 3673 on the two
    /// forges of one account — so the grouped form still fits the row.
    static func forgeCount(_ count: Int) -> String {
        forgeCountFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    private static let forgeCountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    /// What the mark beside the merge count means, in the vendor's own noun.
    ///
    /// The word left the row when the mark arrived: `merged` cost the line
    /// seven characters to say what a git-merge glyph in purple says without
    /// any, and purple is the one colour neither forge paints an open request
    /// — green is open on both and red is closed on both. What a glyph cannot
    /// do is introduce itself, which is what this is for.
    static func forgeMergedHelp(_ kind: ForgeKind) -> String {
        switch kind {
        case .gitHub: "Pull requests you opened and had merged"
        case .gitLab: "Merge requests you opened and had merged"
        }
    }

    /// What the mark beside the issue count means.
    ///
    /// Opened, not open: it is a count of what happened inside the window the
    /// control names, like the two figures beside it, and the hover is where a
    /// row this narrow can say which of the two it is.
    static func forgeIssuesHelp(_ kind: ForgeKind) -> String {
        "Issues you opened on " + forgeName(kind)
    }

    /// What the mark beside the comment count means.
    ///
    /// Each vendor's own scope rather than one sentence for both, because the
    /// two are not the same set and the row is where somebody would otherwise
    /// assume they are: GitHub's figure is comments on issues and on pull
    /// request conversations and cannot include a review left on a diff, where
    /// GitLab's is everything it filed as a comment. Naming the surfaces is
    /// also what keeps the hover honest about the one it leaves out.
    static func forgeCommentsHelp(_ kind: ForgeKind) -> String {
        switch kind {
        case .gitHub: "Comments you wrote on issues and pull requests"
        case .gitLab: "Comments you wrote on issues and merge requests"
        }
    }

    /// Why a forge would not answer, in the one sentence every surface that
    /// reports it uses.
    ///
    /// A refused token and a host that could not be reached are separate
    /// sentences because they need separate things from the user, and neither
    /// of them is a zero: this user's own GitLab routes over a tunnel, so a
    /// laptop off the VPN would otherwise report a day with no work on it.
    static func forgeFailure(_ failure: ForgeReadFailure) -> String {
        switch failure {
        case .unauthorized: "the token was refused"
        case .rateLimited: "asked to slow down"
        case .unreachable: "could not be reached"
        case .malformed: "answered something Sissy could not read"
        case .noCredential: "no token"
        case .credentialUnreadable: "the keychain would not answer"
        }
    }

    /// The line under a forge row: what it is doing, or what went wrong, and
    /// how old the figures beside it are.
    ///
    /// **A healthy row dates itself**, which is the whole of what it used to be
    /// missing. The poll runs every five to thirty minutes, so a count that is
    /// current and a count taken before the merge the user is looking for are
    /// the same three digits, and the row had no way to say which it was. The
    /// panel's own header has always dated its reading this way; this is the
    /// block whose cadence makes it worth repeating. Printing it only past
    /// some staleness was the other way to word it and it has no honest
    /// threshold to use: the interval is picked after each round, with jitter,
    /// and the loop keeps it to itself.
    ///
    /// **A failure now says both.** The age alone stood for it while a healthy
    /// row was silent; with one that is not, a reason left out would read as an
    /// ordinary reading that happened to be old.
    ///
    /// `readAt` is nil for a connection that has never once answered. There is
    /// no reading to date — `ForgeActivityReading.unavailable` stamps the
    /// attempt, not a read — so that row gets the reason by itself.
    ///
    /// **A window the vendor has not started counting says so instead of its
    /// age**, which is `ForgeWindow.opens` and only ever `today`. Both forges
    /// bucket in whole UTC days named by the local date, so east of Greenwich
    /// the row spends the length of the offset over a day the vendor has not
    /// opened: measured 2026-09-19 at 01:01+02:00, GitLab answered `x-total: 0`
    /// for it against 8 events it had already recorded since local midnight,
    /// all of them filed under the previous UTC day. The figures are absent
    /// there rather than zero, so without this the row is a bare dash under an
    /// account that is working — the one state on this line a user reads as a
    /// fault. It is worded before the age and after the failure: an age dates a
    /// reading this window has none of, and a token the vendor is refusing is
    /// the more actionable of the two.
    static func forgeNotice(
        _ failure: ForgeReadFailure?, readAt: Date?, opensAt: Date? = nil, refreshing: Bool,
        now: Date = Date()
    ) -> String? {
        if refreshing { return "refreshing…" }
        guard let readAt else { return failure.map(forgeFailure) }
        let read = age(now.timeIntervalSince(readAt))
        if let failure { return forgeFailure(failure) + " · last read " + read }
        if let opensAt, let label = resetLabel(opensAt, now: now) {
            return "counted in UTC days · today opens " + label
        }
        return "read " + read
    }

    /// The hover for a forge row: what each figure counts, in the vendor's own
    /// terms, plus the caveat the window carries.
    ///
    /// It says what it counts because the two vendors do not count the same
    /// thing and the row has room for neither explanation: GitHub answers with
    /// its own contribution total and GitLab with the events it recorded. And
    /// on the widest window it says that GitHub's contributions reach back a
    /// year where the merge count beside them reaches back for ever, which is
    /// the one place `All` means two things on one line.
    ///
    /// It also names the right-click, where the keep-awake control names its
    /// own and for the same reason: a gesture nothing advertises is a feature
    /// only whoever wrote it can find, and this row has nowhere to put a
    /// button — 340 pt already has the login truncating before the figures do.
    static func forgeTooltip(
        _ kind: ForgeKind, host: String, login: String?, period: UsagePeriod,
        boundedToOneYear: Bool
    ) -> String {
        var lines = [forgeName(kind) + " · " + host]
        if let login { lines.append("Read as \(login)") }
        switch kind {
        case .gitHub:
            lines.append("Contributions as GitHub counts them, in its own whole UTC days")
        case .gitLab:
            lines.append("Events GitLab recorded for you, in its own whole UTC days")
        }
        if period == .all, boundedToOneYear {
            lines.append("Contributions reach back one year; the counts beside them are every one")
        }
        lines.append("Right-click to refresh now")
        return lines.joined(separator: "\n")
    }

    /// The heading over the forge rows, naming the window they are over for
    /// the reason the project section names its own day: the block under a
    /// control is the one that has to say which choice it is answering.
    static func forgeSectionLabel(_ period: UsagePeriod) -> String {
        let window = period == .all ? "all time" : periodLabel(period).lowercased()
        return "Contributions · " + window
    }
}
