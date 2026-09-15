import Foundation

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

    /// The line under a limit bar: the pace where there is one, and when the
    /// window rolls over, joined.
    ///
    /// Nil for a window the vendor has not started, which has neither — the
    /// bar at zero is the whole statement, and a caption saying so twice is
    /// noise on the one row that has nothing to report.
    static func windowCaption(
        _ window: UsagePanelSnapshot.WindowRow,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        var parts: [String] = []
        if let pace = window.pace {
            parts.append(paceCaption(deltaPercent: pace.deltaPercent, runsOutAt: pace.runsOutAt))
        }
        if let resetsAt = window.resetsAt {
            parts.append("resets " + resetLabel(resetsAt, now: now, calendar: calendar))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// When a window rolls over. A clock time while that is unambiguous, the
    /// weekday once it is not — a bare "13:00" three days out reads as today.
    ///
    /// The cut is the calendar day rather than a 24-hour horizon: at 22:00 a
    /// five-hour window resetting at 01:00 is three hours away, and "01:00"
    /// there reads as this morning, already past. The weekday carries no
    /// clock time because the panel gives this column 74 points and the
    /// window's own label shares them.
    static func resetLabel(
        _ resetsAt: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        if calendar.isDate(resetsAt, inSameDayAs: now) {
            return resetsAt.formatted(.dateTime.hour().minute())
        }
        return resetsAt.formatted(.dateTime.weekday(.abbreviated))
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

    /// Names the window the archive line covers. The asked-for width while
    /// the archive reaches back across all of it, and the first day it holds
    /// once it does not — a total labelled "Last 7 days" on an install three
    /// days old is a number nobody can read correctly.
    static func historyWindowLabel(
        days: Int,
        earliestDay: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: today)
        guard let earliestDay, let start,
            calendar.startOfDay(for: earliestDay) > start
        else { return "Last \(days) days" }
        return "Since \(earliestDay.formatted(.dateTime.day().month(.abbreviated)))"
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
    static func limitsNotice(_ state: ProviderLimitsState) -> (message: String, action: String?)? {
        switch state {
        case .quiet:
            return nil
        case .needsAuthorization:
            return ("Sissy needs your permission to read Claude Code's token again", "Allow")
        case .refused:
            return ("Keychain access was refused, so the limits stay hidden", "Try again")
        case .signedOut:
            return ("Claude Code is not signed in on this Mac", nil)
        case .sessionExpired:
            return ("The claude.ai session has ended", "Import again")
        }
    }

    /// Everything on the account line except the address: the organisation
    /// the seat belongs to, and when the subscription renews.
    ///
    /// Nil rather than an empty string when neither vendor answered, so the
    /// caller drops the line instead of drawing a blank one. A renewal
    /// already past is dropped on its own: the claim is read off a file the
    /// CLI refreshes on its own schedule, so a stale date is the ordinary
    /// case and "renewed 3 Aug" answers nothing.
    static func accountDetails(
        organization: String?,
        renewsAt: Date?,
        now: Date = Date()
    ) -> String? {
        var parts: [String] = []
        if let organization, !organization.isEmpty { parts.append(organization) }
        if let renewsAt, renewsAt > now {
            parts.append("renews " + renewsAt.formatted(.dateTime.day().month(.abbreviated)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Why a provider's page shows no limit windows, when nothing went wrong.
    ///
    /// The blank is not a fault and must not read as one. On Codex the
    /// windows ride the CLI's own events, so an idle session simply has not
    /// sent one. On Claude Code a switch in Settings is what turns them on at
    /// all, and `limitsEnabled` is what stops this telling someone who has
    /// already flipped it to go and flip it — a reading that has not landed
    /// yet and a module that was never switched on look identical from here,
    /// and only the app knows which it is.
    static func noWindowsCaption(_ id: String, limitsEnabled: Bool) -> String {
        switch ProviderKey.vendor(of: id) {
        case ProviderID.claudeCode where !limitsEnabled:
            return "Switch on Claude Code limits in Settings to see this account's windows."
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

    /// What pressing refresh on a provider actually does, said before it is
    /// pressed.
    ///
    /// The two are not the same action and the button must not pretend they
    /// are: on Claude Code it re-reads the keychain with the dialog allowed,
    /// which is a permission prompt someone is about to meet. On Codex the
    /// limits ride the CLI's own events, so no button can make them arrive —
    /// all a refresh can honestly touch is the account and the plan.
    static func refreshHelp(_ id: String) -> String {
        switch ProviderKey.vendor(of: id) {
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
        switch ProviderKey.vendor(of: id) {
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

    /// The same row name for a surface that holds the user's own label rather
    /// than the vendor's answer for the account — Settings, which lists
    /// accounts before any of them has produced a reading.
    static func providerName(_ id: String, named label: String?) -> String {
        let name = providerName(id)
        let qualifier = label.flatMap { $0.isEmpty ? nil : $0 } ?? ProviderKey(id: id).account
        guard let qualifier else { return name }
        return "\(name) · \(qualifier)"
    }

    private static func accountQualifier(_ id: String, account: ProviderAccount?) -> String? {
        if let organization = account?.organization, !organization.isEmpty { return organization }
        if let email = account?.email, let local = email.split(separator: "@").first {
            return String(local)
        }
        return ProviderKey(id: id).account
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

    /// What the rest of the day is called when no row can name it. Deliberately
    /// not a name: the money was counted, and the one thing Sissy will not do
    /// is invent a repository for it.
    static let projectsUnattributed = "Unattributed"

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
    static func creditsAmount(_ credits: ProviderCredits) -> String {
        let used = money(credits.used, currency: credits.currency)
        guard credits.hasCap else { return used }
        return "\(used) of \(money(credits.cap, currency: credits.currency))"
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
        } else if credits.hasCap {
            parts.append("\(money(credits.remaining, currency: credits.currency)) left")
        }
        if let balance = credits.balance {
            parts.append("\(money(balance, currency: credits.currency)) prepaid")
        }
        parts.append(observedLabel(credits.observedAt, now: now, calendar: calendar))
        return parts.joined(separator: " · ")
    }

    /// When a cached reading was taken. A clock time for today, the weekday
    /// and the time once it is not — the same cut `resetLabel` makes, but
    /// keeping the clock, because this column is the width of a caption and
    /// "how old" is the whole point of it.
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

    private static func money(_ amount: Decimal, currency: String) -> String {
        amount.formatted(.currency(code: currency).precision(.fractionLength(2)))
    }
}
