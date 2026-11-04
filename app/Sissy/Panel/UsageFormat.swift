import Foundation

/// One step of a unit cascade: print in a unit once a figure, read the way it
/// would be printed, reaches a limit.
///
/// Deciding on the printed figure rather than the raw one is what keeps a reading
/// from saying `1000 MB` or `10.0 MB/s`.
struct UnitStep {
    /// How the figure a step decides on would read.
    enum Reading {
        case exact
        case whole
        case oneDecimal

        fileprivate func printed(_ figure: Double) -> Double {
            switch self {
            case .exact: figure
            case .whole: figure.rounded()
            case .oneDecimal: (figure * 10).rounded() / 10
            }
        }
    }

    static let kilo: Double = 1_000
    static let mega: Double = 1_000_000
    static let giga: Double = 1_000_000_000
    static let tera: Double = 1_000_000_000_000
    /// The figure a step usually waits for, which is the one the unit below it
    /// must never print.
    static let unitLimit: Double = 1_000

    let format: String
    let unit: Double
    let reading: Reading
    let scale: Double
    let limit: Double

    /// Prints in `unit` once `value / scale`, read as `reading`, reaches `limit`.
    init(
        _ format: String, per unit: Double, once reading: Reading, of scale: Double,
        reaches limit: Double = unitLimit
    ) {
        self.format = format
        self.unit = unit
        self.reading = reading
        self.scale = scale
        self.limit = limit
    }

    /// `value` in the first of `steps` it reaches, largest unit first, and nil
    /// when it reaches none of them.
    static func format(_ value: Double, _ steps: [Self]) -> String? {
        for step in steps where step.reading.printed(value / step.scale) >= step.limit {
            return String(format: step.format, value / step.unit)
        }
        return nil
    }
}

/// Display formatters shared by the menubar menu and the usage panel.
///
/// The only place a number on screen is worded. The frame carries the day's
/// raw totals, so rounding is the surface's business rather than the engine's
/// — which is what let the engine stop shipping a second set of formatters
/// shaped for a 128×64 display nothing renders to any more.
enum UsageFormat {
    /// A token count to one decimal of the largest unit it reaches: thousands,
    /// millions or billions.
    ///
    /// Each step is taken on the figure as it will be printed, `networkRate`'s
    /// rule, so a count never reads `1000.0K` or `1000.0M`. Billions are there
    /// because cache reads on a busy Claude Code account run to billions
    /// over a month, and the `30 days` and `All` headlines would otherwise
    /// print thousands of millions.
    static func tokens(_ tokens: Int) -> String {
        UnitStep.format(Double(tokens), tokenSteps) ?? "\(tokens)"
    }

    private static let tokenSteps = [
        UnitStep("%.1fB", per: UnitStep.giga, once: .oneDecimal, of: UnitStep.mega),
        UnitStep("%.1fM", per: UnitStep.mega, once: .oneDecimal, of: UnitStep.kilo),
        UnitStep("%.1fK", per: UnitStep.kilo, once: .exact, of: 1),
    ]

    static func cost(_ cost: Decimal) -> String {
        String(format: "$%.2f", NSDecimalNumber(decimal: cost).doubleValue)
    }

    /// A share of input the cache answered, to a tenth of a point.
    ///
    /// Tenths because the reading lives in the high nineties, where whole
    /// points would print the same figure for a week that halved its fresh
    /// input. Truncated rather than rounded, so a window that sent one fresh
    /// token never reads `100.0%`.
    static func cacheShare(_ share: Double) -> String {
        let permille = (min(max(share, 0), 1) * permillePerWhole).rounded(.down)
        return String(format: "%.1f%%", permille / permillePerPercent)
    }

    private static let permillePerWhole: Double = 1000
    private static let permillePerPercent: Double = 10

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
    ///
    /// `terse` drops the word "updated" and nothing else, for a header that
    /// cannot fit the whole sentence on one line. Measured 2026-09-29 on the
    /// home header, whose three controls leave the line 167 pt while the
    /// period button is shown: `updated just now · awake 1h 2m` wants 168.8
    /// and wrapped, growing the header by a line while the panel sat open.
    /// Neither clause has a ceiling, since neither `age` nor `held` has a unit
    /// past the hour: measured the same day, `updated 59m ago · awake 123h
    /// 59m` wants 192.4 and its terse form 145.9. The word goes rather than
    /// the hold because the hold is the clause that carries its own noun; the
    /// age reads as a time without one.
    static func reading(
        age interval: TimeInterval, holding: TimeInterval?, refreshing: Bool,
        terse: Bool = false
    ) -> String {
        let dated = terse ? age(interval) : "updated " + age(interval)
        let reading = refreshing ? "refreshing…" : dated
        guard let holding else { return reading }
        return reading + " · awake " + held(holding)
    }

    /// The widest full `reading` the line can show before the hold next
    /// grows a digit, which is what a header measures to choose between the
    /// full and the terse wording.
    ///
    /// Choosing on the live sentence instead flipped the word "updated" on
    /// and off as the clock ran: measured 2026-09-29 against the 167 pt home
    /// line with a hold of `1h 2m`, `just now` wanted 168.8, `5s ago` 160.6,
    /// `10s ago` 167.6 and `10m ago` 171.4, so the line changed shape several
    /// times a minute under a pointer that had not moved. Measured on this
    /// template, the choice holds for the whole of an hour of hold and moves
    /// only when the hours gain a digit. The age is the widest a live reading
    /// shows, two digits of minutes, and the minutes of the hold are two
    /// digits for the same reason. Refreshing is left out because it is
    /// narrower, so the wording a refresh ends on is the one it started on.
    static func widestReading(holding: TimeInterval?) -> String {
        let widestAge = TimeInterval(minutesPerHour * secondsPerMinute - 1)
        let widestHold = holding.map { held in
            let hours = (Int(max(held, 0)) / secondsPerMinute) / minutesPerHour
            return TimeInterval(hours * minutesPerHour * secondsPerMinute) + widestAge
        }
        return reading(age: widestAge, holding: widestHold, refreshing: false)
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
        "Keep awake · holding " + held(interval)
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

    /// What each ceiling on `Always` is called, in the picker Settings offers
    /// them from. Spelled out rather than run through `countdown`, which
    /// words a time left on a clock rather than a length someone chooses.
    static func keepAwakeCeilingTitle(_ ceiling: KeepAwakeCeiling) -> String {
        guard let hours = ceiling.hours else { return "Never" }
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    /// What each battery floor is called, in the picker Settings offers them
    /// from.
    static func lidBatteryFloorTitle(_ floor: LidBatteryFloor) -> String {
        floor.percent.map { "\($0)%" } ?? "Never"
    }

    /// What the screen half of the hold is called, in Settings and in the
    /// cup's menu, for the reason `keepAwakeTitle` is one switch: one setting
    /// worded twice reads as two.
    static let keepScreenAwakeTitle = "Keep the screen on too"

    /// What the lid half of the hold is called, in Settings and in the
    /// confirmation that switches it on.
    static let keepAwakeWithLidClosedTitle = "Keep working with the lid closed"

    /// The keep-awake button's tooltip: what the Mac is doing, what a click
    /// would do to it, and where the modes a click cannot reach are, together
    /// with the screen switch that hangs beside them.
    ///
    /// Names the lid in every wording that claims the Mac stays up, because
    /// the assertions hold off *idle* sleep and nothing else: unless the lid
    /// half is in force, a MacBook closed on a running agent sleeps anyway,
    /// and someone who learns that from a lost run blames Sissy for it. A
    /// running hold words the lid from `coversLid`, which is the effect; the
    /// states holding nothing yet word it from `lidClosedSetting`, which is
    /// what a hold would take.
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
    static func keepAwakeHelp(
        _ state: KeepAwakeState, arming: KeepAwakeMode, lidClosedSetting: Bool = false
    ) -> String {
        let modes = " · right-click for the other modes and the screen"
        let lid = lidClosedSetting ? "closing the lid keeps it working" : "closing the lid sleeps it anyway"
        switch (state.mode, state.active) {
        case (.off, _):
            return "Keep this Mac awake, \(keepAwakeTitle(arming).lowercased()) · " + lid + modes
        case (_, true):
            let since = state.since.map { " since " + clock($0) } ?? ""
            let what =
                state.coversScreen
                ? "Keeping this Mac and its screen awake\(since), so it will not lock."
                : "Keeping this Mac awake\(since). The screen still sleeps and locks."
            let held =
                state.coversLid
                ? " Closing the lid keeps it working" : " Closing the lid sleeps it anyway"
            return what + held + " · click to allow sleep" + modes
        case (.auto, false):
            return "Waiting for the agents · the Mac will be held while they work · " + lid + modes
        case (.on, false):
            return "Switched on · the Mac is not being held awake" + modes
        }
    }

    /// The keep-awake button's state as VoiceOver speaks it: the cup's tint is
    /// the only thing on screen that says a hold is in force, and the tooltip
    /// is read after a pause if at all. Said from what the Mac is doing, the
    /// way the tooltip leads, so a mode that holds nothing yet is not heard as
    /// a hold.
    static func keepAwakeValue(_ state: KeepAwakeState) -> String {
        switch (state.mode, state.active) {
        case (.off, _): "Off"
        case (_, true): holdingValue
        case (.auto, false): "Waiting for the agents"
        case (.on, false): "Switched on, not holding"
        }
    }

    /// The status item's state as VoiceOver speaks it, one clause per mark the
    /// icon draws: the shut eye, the lit eye and the dot. Empty when none is
    /// drawn, since a resting Sissy has nothing to report.
    static func statusItemValue(_ icon: SissyModel.StatusIconSnapshot) -> String {
        var clauses: [String] = []
        if icon.isAsleep { clauses.append("Sleeping") }
        if icon.isHolding { clauses.append(holdingValue) }
        if let level = icon.macLevel, level > .normal { clauses.append("Mac at " + macLevel(level)) }
        return clauses.joined(separator: ", ")
    }

    private static let holdingValue = "Holding this Mac awake"

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
    /// A window the vendor has not started has neither, and says when it
    /// will: its period runs from the first message. It used to say nothing,
    /// and on the Overview that left one account's row a line short of the
    /// rows around it with no reason given (2026-10-14).
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
        if window.isUnstarted { return unstartedCaption }
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

    static let unstartedCaption = "starts on first use"

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
    ///
    /// A picked window is measured against `archiveStart`, the first day the
    /// whole archive holds, rather than against a width ending today, which
    /// would call every past window whole, or against the window's own first
    /// filed day, which would call a window opening on an idle Saturday short.
    /// One whose days hold no file at all says so, since its zero is no
    /// reading rather than a quiet window.
    static func periodCoverage(
        _ rollup: UsageHistoryRollup,
        archiveStart: Date? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        switch rollup.period {
        case .preset(let period):
            return shortfall(
                days: period.days, earliestDay: rollup.earliestDay,
                now: now, calendar: calendar
            ).map(since)
        case .days(let span):
            guard rollup.earliestDay != nil else { return notRunning }
            guard let archiveStart, calendar.startOfDay(for: archiveStart) > span.from else {
                return nil
            }
            return since(archiveStart)
        }
    }

    /// What a window or a day the archive holds no file for says in place of
    /// a figure.
    static let notRunning = "Sissy was not running"

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
        return "Since " + sinceDay(day)
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
        guard let start = UsagePeriod.start(days: days, now: now, calendar: calendar),
            calendar.startOfDay(for: earliestDay) > start
        else { return nil }
        return earliestDay
    }

    /// Lowercase because it lands mid-line, after the tokens it qualifies.
    private static func since(_ day: Date) -> String {
        "since " + sinceDay(day)
    }

    /// The first day a window holds, as both labels above word it: `11 Sept`.
    static func sinceDay(_ day: Date) -> String {
        day.formatted(.dateTime.day().month(.abbreviated))
    }

    /// The period control's own label for a window, in its menu.
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

    /// A window as the reading it heads names it: `Today`, `7 days`,
    /// `30 days`, `All time`.
    ///
    /// Every tab that follows the period names it on its own first line,
    /// because the control is an icon in the header: it answers which window
    /// is chosen only once it is opened, and a figure that does not say what
    /// it is over is the stale-looking number the popup on the headline's row
    /// used to prevent. `All` becomes `All time` here, since a bare `All`
    /// heading a figure reads as a quantifier rather than a window.
    static func periodHeading(_ period: UsagePeriod) -> String {
        period == .all ? "All time" : periodLabel(period)
    }

    /// Any window as its reading names it: a preset by its heading, days
    /// picked on the calendar by their dates, `Wed 1 Oct` or `22 Sept to 2 Oct`.
    static func periodHeading(
        _ range: UsageRange, now: Date = Date(), calendar: Calendar = .current
    ) -> String {
        switch range {
        case .preset(let period): periodHeading(period)
        case .days(let span): spanHeading(span, now: now, calendar: calendar)
        }
    }

    /// The same window mid-line, after a separator: a preset lowercased the
    /// way a section's heading has always carried it, and dates as they are,
    /// since a lowercased weekday reads as a typo.
    static func periodInline(
        _ range: UsageRange, now: Date = Date(), calendar: Calendar = .current
    ) -> String {
        switch range {
        case .preset(let period): periodHeading(period).lowercased()
        case .days(let span): spanHeading(span, now: now, calendar: calendar)
        }
    }

    /// Days picked on the calendar: one day by its weekday and date, a run by
    /// its two ends. The year is said only when the window is not this year's,
    /// which an archive kept long enough can reach.
    static func spanHeading(
        _ span: UsageDaySpan, now: Date = Date(), calendar: Calendar = .current
    ) -> String {
        let withYear =
            !calendar.isDate(span.from, equalTo: now, toGranularity: .year)
            || !calendar.isDate(span.to, equalTo: now, toGranularity: .year)
        var day = Date.FormatStyle.dateTime.day().month(.abbreviated)
        day.timeZone = calendar.timeZone
        if withYear { day = day.year() }
        guard span.from != span.to else { return day.weekday(.abbreviated).format(span.from) }
        return day.format(span.from) + " to " + day.format(span.to)
    }

    /// The period control's hover: the window it is set to and both of its
    /// gestures, since nothing on a 26 pt circle can show that it has two.
    static func periodHelp(_ range: UsageRange, now: Date = Date()) -> String {
        "Period: " + periodHeading(range, now: now)
            + "\nClick for the calendar, right-click for the presets"
    }

    /// The help on a tab whose page reads the moment, where the control is
    /// disabled rather than hidden.
    static let periodHelpMoment = "This tab reads the moment and has no period"

    /// The calendar's caption over a month it has not been pointed into: the
    /// month, and how many of its days so far the archive holds. The count is
    /// left off while the month is being read, where `0 of 31` would claim an
    /// empty archive for a reading that has not landed.
    static func calendarMonth(
        _ month: Date, covered: Int?, days: Int, now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        var style = Date.FormatStyle.dateTime.month(.wide)
        style.timeZone = calendar.timeZone
        if !calendar.isDate(month, equalTo: now, toGranularity: .year) { style = style.year() }
        guard let covered else { return style.format(month) }
        return "\(style.format(month)) · \(covered) of \(days) days"
    }

    /// A strip over a window of days: the window as its headline names it,
    /// and how many of its days the archive holds where it does not hold
    /// them all.
    static func spanStripLabel(_ window: String, covered: Int, days: Int) -> String {
        guard covered < days else { return window }
        return "\(window) · \(covered) of \(days) days"
    }

    /// A provider's spend over a window that does not reach today, where the
    /// row has no gauge to draw.
    static func providerSpend(tokens: Int, cost: Decimal) -> String {
        "\(self.tokens(tokens)) · \(self.cost(cost))"
    }

    /// What the window's sessions came to for one provider, under its spend:
    /// the two counts and how long it was worked, the last only where the
    /// archive measured any.
    static func providerWork(_ counts: AgentCounts, activity: ActivityTotals) -> String {
        var parts = [
            counts.sessions == 1 ? "1 session" : "\(counts.sessions) sessions",
            counts.agents == 1 ? "1 sub-agent" : "\(counts.agents) sub-agents",
        ]
        if activity.activeMinutes > 0 {
            parts.append(workedDuration(minutes: activity.activeMinutes) + " active")
        }
        return parts.joined(separator: " · ")
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

    /// A strip bar's own name when it stands for more than a day: a whole
    /// month or year by its name, and any other stretch, a week or the part
    /// of a month or year the window cuts into, by its two ends, so the hover
    /// names exactly the days the figure beside it sums.
    static func stripBucketTitle(
        _ bucket: UsageDaySpan, unit: Calendar.Component, now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        guard bucket.from != bucket.to else { return dayTitle(bucket.from) }
        let whole = calendar.dateInterval(of: unit, for: bucket.from).map {
            $0.start == bucket.from && calendar.date(byAdding: .day, value: -1, to: $0.end) == bucket.to
        }
        switch unit {
        case .month where whole == true:
            return calendarMonth(bucket.from, covered: nil, days: 0, now: now, calendar: calendar)
        case .year where whole == true:
            var style = Date.FormatStyle.dateTime.year()
            style.timeZone = calendar.timeZone
            return style.format(bucket.from)
        default:
            return spanHeading(bucket, now: now, calendar: calendar)
        }
    }

    /// A day bar's own figures, since the strip carries no axis to read one
    /// off.
    ///
    /// A day with no reading says what happened rather than naming a figure:
    /// the archive holds nothing for a day Sissy was not running, and "—"
    /// there would read as a day that cost nothing.
    static func dayFigures(tokens: Int?, cost: Decimal?) -> String {
        guard let tokens, let cost else { return notRunning }
        return "\(self.tokens(tokens)) · \(self.cost(cost))"
    }

    static let secondsPerMinute = 60
    static let minutesPerHour = 60
    private static let minutesPerDay = 1440

    /// The plan as the badge says it, plus the limit tier when the tier
    /// belongs to a different plan than the account's own.
    ///
    /// The vendor's own word leads wherever it sends one (`name`). Failing
    /// that, a tier on the plan it decorates folds into one thing, and a tier
    /// on another plan goes to the row's tooltip, because "Team 5x" is a plan
    /// nobody sells. The two tiers of `soldTierNames` go nowhere on another
    /// plan: the seat already names what it pays for, and Anthropic no longer
    /// sells a plan with a multiplier in its name to compare it to.
    static func plan(
        _ plan: String?, tier: String?, seat: String? = nil, name: String? = nil
    ) -> (label: String, tier: String?)? {
        guard let plan, let label = words(plan) else { return nil }
        let named = name ?? seatLabel(plan: plan, seat: seat) ?? label
        let parts = tierParts(tier)
        guard let base = parts.base else { return (named, nil) }
        if let tier, let sold = soldTierNames[tier] {
            return (base == plan && name == nil ? sold : named, nil)
        }
        if base == plan {
            if name != nil { return (named, nil) }
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

    /// What Anthropic sells each Max tier as since the rename of 2026-10-30,
    /// which left the tokens as they were. A map for the reason `teamSeatLabels`
    /// may be one: it only answers for a reading that carries no word of the
    /// vendor's, an older CLI's or an identity filed before `planName` was
    /// read, and any other tier falls through to the derived wording.
    private static let soldTierNames = [
        "max_20x": "Ultra",
        "max_5x": "Max",
    ]

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
    ///
    /// Claude Code's absent credential is worded as a missing stored login
    /// rather than a missing sign-in: the CLI runs just as well on an API key,
    /// a cloud provider or a token in the environment, none of which it
    /// stores, and telling those users they are signed out is false.
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
            let message =
                isCodex
                ? "\(cli) is not signed in on this Mac"
                : "No stored Claude login to read limits from"
            return .init(message: message, action: nil, kind: .refresh)
        case .sessionExpired:
            let ended = isCodex ? "The OpenAI sign-in" : "The claude.ai session"
            return .init(message: "\(ended) has ended", action: "Link again", kind: .link)
        case .sessionUnreadable:
            return .init(
                message: "Sissy could not read this account's saved claude.ai session",
                action: "Link again", kind: .link)
        case .credentialRefused:
            // No action, deliberately. The credential is the CLI's own and
            // the CLI rotates it on its own schedule, so every button this row
            // could carry would either do nothing or send someone to re-link
            // an account that is not linked.
            let remedy = isCodex ? "until you run codex login" : "until the CLI renews it"
            return .init(
                message: "\(vendor) refused \(cli)'s sign-in, so the limits stay hidden "
                    + remedy,
                action: nil, kind: .refresh)
        case .rateLimited(let until):
            return .init(
                message: "\(vendor) is not answering for limits until "
                    + clock(until),
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
            return "Codex reports its limits on its own turns. The next one fills this in."
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

    static func humanised(_ raw: String) -> String {
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
    /// Both vendors answer the press the same way: `refreshProvider(id:)`
    /// re-reads every limits reader the provider has (the CLI's credential
    /// and each claude.ai session for Claude, each `CodexUsageSource` for
    /// Codex) and then the account and the plan. Neither raises a dialog,
    /// because the CLI's keychain item is read through `/usr/bin/security`,
    /// so the tooltip warns of nothing. A provider with no limits reader
    /// can only be read again.
    static func refreshHelp(_ id: String) -> String {
        switch id {
        case ProviderID.claudeCode, ProviderID.codex:
            return "Read the limits and the account again"
        default:
            return "Read this provider again"
        }
    }

    /// How much a live plot holds, in minutes, read off `LiveCadence.window`
    /// so the copy under the Network and Disk plots cannot say two minutes
    /// once the series holds some other length.
    private static var liveWindowMinutes: Int {
        Int(LiveCadence.window) / secondsPerMinute
    }

    /// The left end of a live plot's axis.
    static var liveWindowStart: String { "\(liveWindowMinutes) min ago" }

    /// The caption under the Disk tab's plot.
    static var liveWindowCaption: String { "last \(liveWindowMinutes) minutes" }

    /// A live plot's accessibility label: what it plots, over the window it
    /// holds.
    static func liveWindowLabel(_ subject: String) -> String {
        "\(subject) over the last \(liveWindowMinutes) minutes"
    }

    /// What the panel says under "No session logs found": the log trees
    /// Sissy is reading, and that none of them holds a log yet.
    ///
    /// Only the trees of the providers that are switched on, for the reason
    /// the header asks `isMetering` before it counts: naming a tree Sissy was
    /// told not to read sends someone looking in it. With none switched on
    /// there is no tree to name, and the way forward is the switch.
    static func emptyLogTrees(_ paths: [String]) -> String {
        guard let last = paths.last else { return "Switch a provider on in Settings to start counting." }
        guard paths.count > 1 else { return "Sissy reads \(last). It has nothing in it." }
        let listed = paths.dropLast().joined(separator: ", ") + " and " + last
        let none = paths.count == 2 ? "Neither has" : "None of them has"
        return "Sissy reads \(listed). \(none) anything in it."
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

    /// What one account is called in the picker.
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

    /// What a project is called: the last component of its path, which is the
    /// repository's own name. Two unrelated repositories sharing a basename
    /// render the same label and are told apart by the tooltip — the accepted
    /// cost of a row that reads like the name the user uses.
    static func projectName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// What a model is called on the page of the provider that ran it: the
    /// vendor's own id, with a trailing release date taken off and the
    /// vendor's own name taken off the front.
    ///
    /// **Two rules about the shape, never a table of names.** There is no
    /// hand-maintained rate table in Sissy and a display-name map would be
    /// the same regression with different values — a model shipped tomorrow
    /// would read as nothing until somebody cut a release. So the id is shown
    /// as the vendor spells it, the way `UsageWindow.scope` already is, and
    /// only two things come off, both of them mechanical.
    ///
    /// The **date suffix**, because it says nothing to a reader:
    /// `claude-haiku-4-5-20251001` is the same model as `claude-haiku-4-5`
    /// wherever it appears. Measured 2026-09-21 across 47 archived days on
    /// the author's machine, none of the 5 ids seen carried one, which is
    /// exactly why this cannot be a list.
    ///
    /// The **vendor prefix**, because the page's own header already prints it
    /// — and because it is what makes the block fit. Measured 2026-09-22 at
    /// `PanelMetrics.width`: four pills carrying the full ids want 378 pt of
    /// the 312 a page has, and the same four want 249.5 pt without the
    /// prefix. It is taken off only when the leading dash-delimited token is
    /// the provider's own name, which `providerName` already answers, so a
    /// provider whose models do not start with it keeps them whole: `gpt` is
    /// not `Codex`, so nothing comes off `gpt-5-codex`, while a future
    /// `codex-mini` on that page would read `mini`. Deriving it from the name
    /// already on the header is what keeps this a rule rather than the list
    /// the first paragraph forbids.
    ///
    /// The raw id stays reachable: `modelTokenDetail` prints it.
    static func modelName(_ id: String, on provider: String) -> String {
        let dated = withoutDateSuffix(id)
        let parts = dated.split(separator: "-")
        guard parts.count > 1,
            parts[0].caseInsensitiveCompare(providerName(provider)) == .orderedSame
        else { return dated }
        return parts.dropFirst().joined(separator: "-")
    }

    private static func withoutDateSuffix(_ id: String) -> String {
        let parts = id.split(separator: "-")
        guard let last = parts.last, last.count == modelDateSuffixLength,
            last.allSatisfy(\.isNumber), parts.count > 1
        else { return id }
        return parts.dropLast().joined(separator: "-")
    }

    /// Eight digits, which is the only suffix `withoutDateSuffix` takes off.
    private static let modelDateSuffixLength = 8

    /// One model pill's second line: its share of the day and what it cost.
    ///
    /// The two together because the choice between them was a false one. The
    /// percentage answers which model the day went to and the money answers
    /// what that was worth, and a pill carrying one of them sends the reader
    /// to the other surface for the other half. The separator is the panel's
    /// own, and the pair is the shape `creditsReading` already uses for a
    /// figure and its share.
    ///
    /// **A share that is not zero never reads as zero.** Rounding a model
    /// worth 0.4% of the day to `0%` prints nothing spent beside a cost that
    /// says otherwise, which is what `BarGeometry.fillWidth` already refuses
    /// to do for a bar too short to draw. A share of exactly zero is a real
    /// reading and keeps its `0%`. The other end holds the same rule: a share
    /// short of the whole reads `>99%`, since `100%` beside a `<1%` pill on
    /// the same row claims the whole day for one model while the other says
    /// it was not.
    static func modelReading(share: Double, cost: String) -> String {
        "\(percentShare(share)) · \(cost)"
    }

    /// One model row's hover and its accessibility label: the id as the vendor
    /// spells it, then the four token counters apart.
    ///
    /// The four rather than the total, because that is the reading ccusage's
    /// own breakdown carries and the split cannot be recovered from a sum. It
    /// is here rather than on the row because four unlabelled figures in
    /// 312 pt would need a header line, and the panel has no table anywhere
    /// in it.
    static func modelTokenDetail(
        id: String, input: Int, output: Int, cacheRead: Int, cacheCreation: Int
    ) -> String {
        [
            id,
            "in \(tokens(input))",
            "out \(tokens(output))",
            "cache read \(tokens(cacheRead))",
            "cache write \(tokens(cacheCreation))",
        ].joined(separator: " · ")
    }

    /// What the pill standing for the folded rest is called, whether the row
    /// is one of models or one of efforts.
    ///
    /// Shorter than `projectsFolded`'s sentence because it has to fit a pill
    /// beside three others rather than a row of its own, and the word it drops
    /// is the one the block's own context supplies. Always plural for that
    /// function's reason: folding a single leftover would save no width.
    static func pillsFolded(_ count: Int) -> String {
        "+\(count) more"
    }

    /// One effort inside a model's run: the vendor's word and that effort's
    /// share of what the model spent over the window.
    ///
    /// **The share and not the money**, measured 2026-09-22 at
    /// `PanelMetrics.width`: a run carrying a currency figure per effort wants
    /// 324 pt at three efforts and 430 at four, against the 312 a page has,
    /// while the shares alone want 264 pt at four. The money is on the row's
    /// hover, where a figure that cannot be read at all is worse than a figure
    /// one gesture away.
    ///
    /// **A share of the money**, which is what makes the run comparable with
    /// the model pills above it — of the tokens instead as soon as any model
    /// in the window has tokens and no cost, the rule `makeModels` already
    /// holds for the same reason. `<1%` rather than `0%` for that block's
    /// reason too: a share too small to round is not a share of nothing, and
    /// `>99%` rather than `100%` for one short of the whole.
    /// Nil is the spend whose lines named no effort, worded with the term the
    /// projects list already uses for a reading that resolves to nothing. It
    /// is what lets the run reach the pill above it rather than describing a
    /// fraction of it as the whole.
    static func effortShare(_ effort: String?, share: Double) -> String {
        "\(effort ?? effortUnattributed) \(percentShare(share))"
    }

    /// A share in whole points that never rounds to either end it has not
    /// reached: `<1%` for one that is not zero, `>99%` for one that is not
    /// the whole.
    private static func percentShare(_ share: Double) -> String {
        let percent = Int((share * 100).rounded())
        if percent <= 0, share > 0 { return "<1%" }
        if percent >= 100, share < 1 { return ">99%" }
        return "\(percent)%"
    }

    /// What the run calls spend the lines named no effort for.
    static let effortUnattributed = "unattributed"

    /// What the `By effort` row and page say their window is: the strip's own
    /// width, and how much of it the archive actually reaches when it falls
    /// short.
    ///
    /// The short form because the strip's caption on the provider page already
    /// spells the coverage out in a sentence; saying it twice in two idioms is
    /// how a panel this narrow stops being read.
    static func effortWindow(covered: Int, of days: Int) -> String {
        covered >= days ? "\(days) days" : "\(covered) of \(days) days"
    }

    /// What one model spent over the effort window, beside its name on the
    /// effort page.
    static func effortTotal(cost: String, turns: Int) -> String {
        "\(cost) · " + agentCount(turns, singular: "turn", plural: "turns")
    }

    /// One effort row's hover and its accessibility label, which are the same
    /// sentence: what each effort cost and how many turns it took, since
    /// neither fits the run beside it.
    static func effortDetail(_ splits: [(effort: String?, cost: String, turns: Int)]) -> String {
        splits
            .map {
                "\($0.effort ?? effortUnattributed) \($0.cost) · "
                    + agentCount($0.turns, singular: "turn", plural: "turns")
            }
            .joined(separator: " · ")
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

    /// What the projects page says under its title: the window it is of, how
    /// many repositories it names, and what that window came to.
    ///
    /// The rows' own total, which is the headline's only on the combined page:
    /// a provider's page lists that provider's day, and the archive keeps no
    /// split by repository per provider, so its rows are today's whatever the
    /// panel's period is and the subtitle names today for them.
    static func projectsSubtitle(
        count: Int, cost: Decimal, period: UsageRange = .preset(.today)
    ) -> String {
        "\(periodInline(period)) · \(projectsCount(count)) · \(self.cost(cost))"
    }

    /// The Overview's projects heading, naming the window its rows are over.
    static func projectsSectionLabel(_ period: UsageRange) -> String {
        "By project · " + periodInline(period)
    }

    /// The projects page with nothing on it, which is a window that has spent
    /// nothing yet rather than a page that failed to load. Reachable only by
    /// a day rolling over under an open page, or by a picked window ending
    /// while it is open, since the row that opens it belongs to a section that
    /// does not exist while the list is empty.
    static let projectsEmpty = "Nothing in this window names a repository."

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
        "Counted in the total, but its working directory names no repository. It is "
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
            return clock(observedAt)
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
