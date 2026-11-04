import Foundation

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
    ///
    /// A floor is the one figure that is compacted, as `10k+`: it is the
    /// ceiling GitLab stopped counting at (`GitLabActivityFeed.countCeiling`)
    /// rather than a count, and printing it in full would read as exactly ten
    /// thousand.
    static func forgeCount(_ count: Int, atLeast: Bool = false) -> String {
        guard atLeast else {
            return forgeCountFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
        }
        return "\(count / thousand)k+"
    }

    private static let thousand = 1_000

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
        case .redirected: "sent Sissy to another host"
        case .noCredential: "no token"
        case .credentialUnreadable: "the keychain would not answer"
        }
    }

    /// The end of a forge section's heading: what the row is doing, or what
    /// went wrong, and how old the figures under it are.
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
    static func forgeNotice(
        failure: ForgeReadFailure?, readAt: Date?, refreshing: Bool, now: Date = Date()
    ) -> String? {
        if refreshing { return "refreshing…" }
        guard let readAt else { return failure.map(forgeFailure) }
        let read = age(now.timeIntervalSince(readAt))
        if let failure { return forgeFailure(failure) + " · last read " + read }
        return "read " + read
    }

    /// An instant as the clock on the wall reads it, in the user's own zone
    /// and locale: the one form every surface words a time of day in.
    ///
    /// A `Date.FormatStyle` held once rather than a `DateFormatter` made per
    /// call: measured 2026-09-29, the formatter cost 48.5 µs a call against
    /// 0.7 µs for the held style, which the chart's hover pays per pointer
    /// move, and both answered the same string in eight locales. The style
    /// is on `.autoupdatingCurrent`, so it follows a locale changed while
    /// Sissy runs.
    static func clock(_ instant: Date) -> String {
        clockStyle.format(instant)
    }

    private static let clockStyle = Date.FormatStyle.dateTime.hour().minute()

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
    /// button: 312 pt already has the login truncating before the figures do.
    static func forgeTooltip(
        _ kind: ForgeKind, host: String, login: String?, period: UsageRange,
        boundedToOneYear: Bool
    ) -> String {
        var lines = [forgeName(kind) + " · " + host]
        if let login { lines.append("Read as \(login)") }
        switch kind {
        case .gitHub:
            lines.append("Contributions as GitHub counts them")
        case .gitLab:
            lines.append("Events GitLab recorded for you")
        }
        if period == .preset(.all), boundedToOneYear {
            lines.append("Contributions reach back one year; the counts beside them are every one")
        }
        lines.append("Right-click to refresh now")
        return lines.joined(separator: "\n")
    }

    /// The hover line for a row carrying a floor, which names the ceiling
    /// GitLab stopped counting at so `10k+` is not read as a rounding.
    static let forgeFloorNote =
        "GitLab stops counting at " + forgeCount(GitLabActivityFeed.countCeiling) + " events, so "
        + forgeCount(GitLabActivityFeed.countCeiling, atLeast: true) + " is at least that many"

    /// The heading over one forge's section: whose figures, and the window
    /// they are over, for the reason the project section names its own day —
    /// the block under a control is the one that has to say which choice it is
    /// answering.
    ///
    /// **A section a forge rather than one block of rows**, as of 2026-09-28. The
    /// age sat in a caption under each row and the latest event had to share
    /// that caption with it: measured 2026-09-28 at 11 pt, `read 2m ago` and
    /// its gap take about 63 of the 310 pt inside a platter, which cut a push
    /// to `feat/background-rate-log` short of its repository. The age moved up
    /// to the heading, where the projects' own count sits, and the event has
    /// the platter's width. It also draws what the figures already obey: two
    /// forges count two things and never add, so they are two blocks.
    ///
    /// `name` is the vendor's name, or the host where two connections are to
    /// the same vendor, which `UsagePanelSnapshot.makeForge` decides.
    static func forgeSectionLabel(_ name: String, period: UsageRange) -> String {
        name + " · " + periodInline(period)
    }

    /// The Actions block's heading, naming the month the allowance is for:
    /// it follows its own reset rather than the panel's period, so the period
    /// heading the section above it carries would name the wrong window.
    static func actionsTitle(resetsAt: Date) -> String {
        let month = resetsAt.addingTimeInterval(-1)
        return "Actions minutes · "
            + month.formatted(Date.FormatStyle(timeZone: .gmt).month(.wide))
    }

    /// An owner's minutes, for the row whose plan has no allowance Sissy knows.
    static func actionsMinutes(_ minutes: Double) -> String {
        "\(Int(minutes.rounded()).formatted()) min"
    }

    /// What an allowance spent in full means for CI, or what was billed past it.
    static func actionsState(_ quota: ActionsQuota, resetsAt: Date) -> String {
        if quota.billed > 0 { return "Billed past the allowance" }
        switch quota.overrun {
        case .stops: return "CI stopped until " + sinceDay(resetsAt)
        case .bills: return "Billed past the allowance from now on"
        case nil: return "Allowance spent until " + sinceDay(resetsAt)
        }
    }

    /// The repository and runner that cost the most, and how much of the
    /// month that was: `try-on-buddy · macOS 80%`.
    static func actionsSpender(_ spender: ActionsSpender) -> String {
        "\(spender.repository) · \(spender.runner) \(Int((spender.share * 100).rounded()))%"
    }

    /// A gaugeless row whose month has ended: the dash every window with no
    /// reading prints, rather than last month's minutes under this month.
    static let actionsNoReading = "—"

    static let actionsNeedsUserScope =
        "Your own minutes need the user scope on the token"

    /// Where and when, joined on with its leading separator: the half of the
    /// line the row keeps whole while the half before it shortens.
    ///
    /// The age is worded on the row's own clock for the reason `forgeNotice`'s
    /// is: the frame arrives every five to thirty minutes and the event only
    /// gets older between them.
    static func forgeEventTail(_ event: ForgeEvent, now: Date = Date()) -> String {
        [event.repository, age(now.timeIntervalSince(event.at))]
            .compactMap { $0 }
            .map { " · " + $0 }
            .joined()
    }

    /// What was done and to what, which is the half of the line a long branch
    /// is in.
    static func forgeEventDone(_ event: ForgeEvent) -> String {
        let hasTarget = event.target != nil
        let verb: String
        switch event.action {
        case .pushed: verb = hasTarget ? "pushed to" : "pushed"
        case .opened, .openedIssue: verb = "opened"
        case .merged: verb = "merged"
        case .commented: verb = hasTarget ? "commented on" : "commented"
        case .reviewed: verb = "reviewed"
        }
        return [verb, event.target].compactMap { $0 }.joined(separator: " ")
    }

    /// The heading over the Sessions tab's counted half, for the reason the
    /// forge's names its window.
    static func sessionsSectionLabel(_ period: UsageRange) -> String {
        "Sessions and sub-agents · " + periodInline(period)
    }

    /// What the day strip says to VoiceOver, `Worked in 4 blocks · Sun 11 Oct`,
    /// naming its day because the strip is drawn for past days as well.
    static func workedBlocksLabel(_ blocks: Int, period: UsageRange) -> String {
        "Worked in " + agentCount(blocks, singular: "block", plural: "blocks") + " · "
            + periodInline(period)
    }
}
