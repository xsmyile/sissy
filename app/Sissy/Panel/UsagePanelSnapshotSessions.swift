import Foundation

extension UsagePanelSnapshot {
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
        /// `FrameData.history` carries them all: changing the panel's period
        /// must not cost a round trip to the engine and a frame's wait. A
        /// window the archive has not counted has no entry, and the tab then
        /// answers for today and says so.
        let counted: [UsagePeriod: Window]
        /// The window picked on the calendar, when that is the panel's period
        /// and its reading has landed. Keyed by its days so a reading of other
        /// days cannot answer for it.
        let picked: [UsageDaySpan: Window]

        /// The counts over `period`, nil where nothing has counted it.
        func window(for period: UsageRange) -> Window? {
            switch period {
            case .preset(let preset): counted[preset]
            case .days(let span): picked[span]
            }
        }

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
            /// **A window of one day only**: today, or a single day picked on
            /// the calendar whose archived file carries its minutes. A strip
            /// is a picture of one day, and a window of thirty has no single
            /// day to draw — a strip per day is the spend bar this panel
            /// already removed, and one strip averaging thirty is a day nobody
            /// worked. The caption under it reads `activity` instead, which
            /// carries its block count for every window.
            let shape: DayShape?
            /// How much of the window's input the cache answered, for the
            /// section that follows this window's picker.
            let cache: CacheReading

            init(
                counts: AgentCounts, byProvider: [ProviderCount], coverage: String?,
                activity: ActivityTotals = .none, cost: Decimal = 0, shape: DayShape? = nil,
                cache: CacheReading = .none
            ) {
                self.counts = counts
                self.byProvider = byProvider
                self.coverage = coverage
                self.activity = activity
                self.cost = cost
                self.shape = shape
                self.cache = cache
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
            let since: Date
            /// One row per running process, dearest first, which is what
            /// answers "two gigabytes of what".
            var processes: [Process]
            /// CPU and energy the agents themselves used since `countedSince`,
            /// exited ones included. Nil `countedSince` is a reading with no
            /// counters, which the page leaves unsaid rather than printing zero.
            var cpuTime: TimeInterval = 0
            var energy: UInt64 = 0
            var countedSince: Date?
            /// The hour behind the headline, split by agent. Nil until a
            /// second sample lands: one point is not a line.
            var chart: MemoryChart?

            /// How many of the dearest sessions the chart's `AgentMemoryChart`
            /// colours as their own band, the rest pooled into one grey band
            /// behind them.
            ///
            /// Was also the row list's own fold point before 2026-09-28: the
            /// list drew this many rows unasked and folded the rest behind
            /// one line. The list now draws nothing until its disclosure is
            /// opened, and opened it draws every session at once with no
            /// fold of its own, so this bound belongs to the chart alone.
            static let processRowLimit = 6

            /// The sessions dearest enough to earn the chart's own band
            /// colour; the disclosed list draws every session, this subset
            /// included, in the same order.
            var standingProcesses: [Process] {
                processes.count <= Self.processRowLimit
                    ? processes : Array(processes.prefix(Self.processRowLimit - 1))
            }
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
            /// Cores' worth of CPU since the sweep before, nil on the sweep
            /// that first saw the process.
            var cpuLoad: Double?
            /// Its load at each sample of the chart, nil where it was not
            /// running, so its lane starts where it did.
            var lane: [Double?] = []
            /// Which band of the chart is this row's, nil for a row the list
            /// folds, whose memory the chart draws in the band for the rest.
            var band: Int?
        }

        /// What the agents held over the retained hour, one band per standing
        /// row and one for everything else.
        ///
        /// **Bottom first, in the list's order**, so the band that sits on the
        /// axis is the row at the top of the list, and a band's colour is the
        /// row's lane. An agent that exits ends its band where it exited; what
        /// it held before is still in the total and still under the top edge,
        /// which is what keeps the chart the same shape the single line was.
        struct MemoryChart: Equatable {
            struct Band: Equatable {
                /// The standing row this band is, nil for the rest.
                let process: pid_t?
                let values: [UInt64]
            }

            let bands: [Band]
            let totals: [UInt64]
            let since: Date
            let interval: TimeInterval
            /// Samples at which a standing agent first appears after the chart
            /// began, which the chart marks along its axis.
            let starts: [Int]

            var peak: UInt64 { totals.max() ?? 0 }

            func instant(_ index: Int) -> Date {
                since.addingTimeInterval(Double(index) * interval)
            }

            /// The standing rows at one sample, dearest first, for the caption
            /// that replaces the resting one under the pointer.
            func leaders(at index: Int) -> [(process: pid_t, bytes: UInt64)] {
                bands.compactMap { band in
                    guard let process = band.process, index < band.values.count,
                        band.values[index] > 0
                    else { return nil }
                    return (process, band.values[index])
                }
                .sorted { $0.bytes > $1.bytes }
            }
        }

        /// What the Sessions tab's live half says while nothing is running:
        /// a Mac that has never measured and one that measured nothing are two
        /// different absences, and the dash above this line is both.
        var summary: String {
            guard let live else { return "no reading yet" }
            guard live.running > 0 else { return "no sessions running" }
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
    }

    /// What is running on this Mac right now, and what the archive has
    /// counted over the window the headline is showing: the Sessions tab's
    /// block, built only while that tab is on screen.
    ///
    /// Off `make` for the reason `projectsPage` is: the snapshot is remade on
    /// every body pass the panel takes, and this block is wanted on one tab.
    /// Measured 2026-09-29 on a release build, a frame carrying ten agents
    /// over the monitor's 240 retained samples took 214 µs to `make`, 204 µs
    /// of it here, almost all of that the chart and the rows' lanes.
    ///
    /// Today's counts come off the slices rather than out of the archive, for
    /// the reason the headline's own figure does: the archive's copy of today
    /// is written behind the tail's flush, so a count read from it would lag
    /// the one beside it. Every other window is the archive's, **including its
    /// per-provider split** — a row taken from the slices under a thirty-day
    /// heading would be today's figure wearing another window's label.
    ///
    /// `window` is the archive's reading of a picked window, which the panel
    /// fetches while a picked window is its period; it carries the same
    /// split by provider every preset's rollup does. One the archive holds no
    /// day inside answers no window at all, so the tab draws the absence the
    /// headline does rather than counts of zero.
    static func makeAgents(
        _ frame: FrameData, window: UsageHistoryRollup? = nil, now: Date = Date()
    ) -> AgentsBlock {
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
            cache: frame.cache)
        let counts = { (rollup: UsageHistoryRollup) in
            AgentsBlock.Window(
                counts: rollup.agents,
                byProvider: rollup.agentsByProvider
                    .map { id, counts in
                        AgentsBlock.ProviderCount(
                            id: id, name: UsageFormat.providerName(id), counts: counts,
                            running: running.count { $0.provider == id },
                            activity: rollup.activityByProvider[id] ?? .none)
                    }
                    .sorted { $0.name < $1.name },
                coverage: UsageFormat.periodCoverage(
                    rollup, archiveStart: frame.history[.all]?.earliestDay, now: now),
                activity: rollup.activity,
                cost: rollup.cost,
                shape: rollup.earliestDay.flatMap { day in
                    rollup.dayActivity.map {
                        AgentsBlock.DayShape(
                            blocks: $0.blocks, dayMinutes: Self.minutesInDay(containing: day))
                    }
                },
                cache: rollup.cache)
        }
        var counted: [UsagePeriod: AgentsBlock.Window] = [.today: today]
        for (period, rollup) in frame.history {
            counted[period] = counts(rollup)
        }
        var picked: [UsageDaySpan: AgentsBlock.Window] = [:]
        if let window, case .days(let span) = window.period, window.earliestDay != nil {
            picked[span] = counts(window)
        }
        return AgentsBlock(
            live: frame.agentMemory.map { memory in
                AgentsBlock.Live(
                    running: memory.current.agents.count,
                    footprint: memory.current.footprint,
                    treeFootprint: memory.current.treeFootprint,
                    peak: memory.peak,
                    since: memory.since,
                    processes: memory.current.agents.map {
                        AgentsBlock.Process(
                            id: $0.pid, provider: $0.provider, project: $0.project,
                            directory: $0.directory, footprint: $0.footprint,
                            startedAt: $0.startedAt, cpuLoad: $0.cpuLoad)
                    },
                    cpuTime: memory.cpuTime,
                    energy: memory.energy,
                    countedSince: memory.countedSince
                ).charted(memory)
            },
            counted: counted,
            picked: picked)
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
}

extension UsagePanelSnapshot.AgentsBlock.Live {
    /// This reading with its chart and its rows' lanes, from the per-agent
    /// series behind it.
    ///
    /// Only where the series is aligned with the totals and holds a line's
    /// worth of samples: a reading built without one keeps no chart, which
    /// the page draws as no chart at all.
    func charted(_ memory: AgentMemoryReading) -> Self {
        let series = memory.perAgent
        guard memory.samples.count > 1, series.count == memory.samples.count else { return self }
        var out = self
        let standing = standingProcesses
        let keys = standing.map { AgentProcess.Key(pid: $0.id, startedAt: $0.startedAt) }
        typealias Band = UsagePanelSnapshot.AgentsBlock.MemoryChart.Band
        var bands = keys.enumerated().map { index, key in
            Band(process: standing[index].id, values: series.map { $0[key]?.footprint ?? 0 })
        }
        let standingKeys = Set(keys)
        bands.append(
            Band(
                process: nil,
                values: series.map { sample in
                    sample.filter { !standingKeys.contains($0.key) }.values.reduce(0) { $0 + $1.footprint }
                }))
        let starts = keys.compactMap { key in
            series.firstIndex { $0[key] != nil }.flatMap { $0 > 0 ? $0 : nil }
        }
        out.chart = UsagePanelSnapshot.AgentsBlock.MemoryChart(
            bands: bands,
            totals: memory.samples,
            since: memory.since,
            interval: memory.interval,
            starts: starts.sorted())
        let bandOf = Dictionary(keys.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        out.processes = processes.map { row in
            var row = row
            let key = AgentProcess.Key(pid: row.id, startedAt: row.startedAt)
            row.lane = series.map { sample in sample[key].map { $0.cpuLoad ?? 0 } }
            row.band = bandOf[key]
            return row
        }
        return out
    }
}
