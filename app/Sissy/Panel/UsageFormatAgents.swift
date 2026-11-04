import Foundation

extension UsageFormat {
    // MARK: Agents

    /// Bytes at the grain a person reads them at, which is one decimal up to
    /// a gigabyte and one above it.
    ///
    /// Base ten rather than base two, because this is the figure sitting
    /// beside Activity Monitor's and macOS has counted in base ten since
    /// 10.6. A reading that said `1.81 GB` where the system says `1.94 GB`
    /// would look like Sissy measuring something else. Each step is taken on
    /// the figure as it will be printed, `networkRate`'s rule, so a footprint
    /// never reads `1000 MB`.
    static func bytes(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        return UnitStep.format(value, byteSteps) ?? String(format: "%.0f KB", value / UnitStep.kilo)
    }

    private static let byteSteps = [
        UnitStep("%.2f GB", per: UnitStep.giga, once: .whole, of: UnitStep.mega),
        UnitStep("%.0f MB", per: UnitStep.mega, once: .whole, of: UnitStep.kilo),
    ]

    /// The headline of the Sessions tab's live half.
    ///
    /// Names what is running rather than what it costs, and names it as
    /// sessions: the counted half above it says sub-agents for what a session
    /// spawned, and one word for both is the collision the tab was renamed
    /// out of.
    static func agentsRunning(_ count: Int, footprint: UInt64) -> String {
        "\(count) \(count == 1 ? "session" : "sessions") · \(bytes(footprint))"
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

    /// What the agents themselves have used since Sissy started counting:
    /// `CPU 18m 49s · 0.28 Wh since 13:10`.
    ///
    /// Watt-hours rather than joules because that is the unit a battery is
    /// read in; the figure is small, measured 2026-09-22 at 0.28 Wh for eight
    /// agents over four hours, and saying so is the reading.
    static func agentsLoad(cpu: TimeInterval, energy nanojoules: UInt64, since: Date) -> String {
        let wattHours = Double(nanojoules) / nanojoulesPerWattHour
        return "CPU \(cpuDuration(cpu)) · " + String(format: "%.2f Wh ", wattHours)
            + samplesSince(since)
    }

    /// CPU time at the grain `ps` reads it: seconds under a minute, minutes and
    /// seconds under an hour, hours and minutes above.
    static func cpuDuration(_ seconds: TimeInterval) -> String {
        let whole = Int(max(seconds, 0))
        if whole < secondsPerMinute { return "\(whole)s" }
        let minutes = whole / secondsPerMinute
        if minutes < minutesPerHour { return "\(minutes)m \(whole % secondsPerMinute)s" }
        return "\(minutes / minutesPerHour)h \(minutes % minutesPerHour)m"
    }

    /// One agent's share of the CPU since the sweep before, as a percentage of
    /// one core, which is how Activity Monitor words it and why it can pass
    /// 100%.
    static func cpuLoad(_ cores: Double) -> String {
        "\(Int((cores * percent).rounded()))%"
    }

    private static let nanojoulesPerWattHour: Double = 3_600_000_000_000
    private static let percent: Double = 100

    /// What the chart's caption says for the instant under the pointer: the
    /// time, the total, and the two agents holding the most of it.
    ///
    /// Two rather than all of them, because the caption is one line in a
    /// 312 pt column and the rows under the chart already carry the rest.
    static func chartInstant(_ instant: Date, total: UInt64, leaders: [(String, UInt64)])
        -> String
    {
        var parts = [clock(instant), bytes(total)]
        let named = leaders.prefix(chartLeaders).map { "\($0.0) \(bytes($0.1))" }
        if !named.isEmpty { parts.append(named.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    /// The left end of the chart's axis: how long ago its first sample was.
    static func chartSpan(minutes: Int) -> String {
        "\(max(minutes, 1))m ago"
    }

    private static let chartLeaders = 2

    /// The disclosure under the live half, shut by default: opens to every
    /// running session in one list, named after what its rows read by — the
    /// repository each session is working in.
    ///
    /// Dated 2026-09-28: the sweep changes the list's own length every 15 s,
    /// and the popover grows from its top edge, so a list shut until asked
    /// for is what gives the tab a height the sweep cannot move.
    ///
    /// No count: the rows are sessions and a repository can hold several, so
    /// a number beside `By repository` read as repositories, and the headline
    /// above already says how many sessions are running.
    static let sessionsDisclosure = "By repository"

    /// One count, worded so a reading of none is not mistaken for a reading
    /// that has not happened. The dash is the caller's.
    static func agentCount(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

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
        uptime(now.timeIntervalSince(started))
    }

    /// A span something has been up for, on `agentUptime`'s grain, which is
    /// the Mac's own uptime's too: `10d 17h` reads the same on both pages.
    static func uptime(_ interval: TimeInterval) -> String {
        let seconds = max(interval, 0)
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    /// The window a series of memory samples covers, which begins when Sissy
    /// did: a reading from a Mac that was asleep is not a low reading, it is
    /// no reading.
    static func samplesSince(_ since: Date) -> String {
        "since " + clock(since)
    }

    /// How long one turn ran, at the grain `cpuDuration` reads a process's
    /// time: a turn is a stretch of wall clock of the same order, and a
    /// five-minute turn read as `5m` would hide the half of it that decides
    /// whether it was long.
    static func turnDuration(milliseconds: Int) -> String {
        cpuDuration(TimeInterval(milliseconds) / millisecondsPerSecond)
    }

    private static let millisecondsPerSecond: TimeInterval = 1000

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
