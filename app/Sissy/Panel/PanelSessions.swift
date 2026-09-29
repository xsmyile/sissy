import SwiftUI

/// The Sessions tab: how many sessions and sub-agents have run, and what the
/// sessions running now are holding.
///
/// **A tab rather than a page one level in**, decided 2026-09-28. It sat behind a
/// door at the end of the Usage tab's providers label, an 11 pt reading and a
/// chevron in front of a page as long as the Mac's and the Forge's together,
/// and the only reason it lived there was that the sessions are the CLIs' own
/// processes. What a tab is decided by is the subject of its reading, and
/// this one reads the sessions: neither money nor the machine.
///
/// **Sessions and sub-agents, never "agents".** The word meant two things on
/// this one page: a running CLI in the live half and a spawned sub-agent in
/// the counted one. A session is a CLI somebody started, running or counted,
/// and a sub-agent is what a session spawned, which is how the two counters
/// were always defined.
///
/// **The window is the panel's, chosen in the header.** It was this page's
/// own for as long as the only other control was the headline's popup, since
/// a picker on one page that moved another page's figures moved them behind
/// the user's back. A control above every tab moves nothing out of sight, and
/// three pickers answering one question in two sizes, each remembering
/// differently, is what it replaced (decided 2026-09-28). The label names the
/// window the figures are over, which is today where the archive has not
/// counted the one chosen.
///
/// **The counted half leads and the live half follows.** The live half
/// changes length with every sweep, a session starting or exiting being a
/// row, and the popover grows from its top edge, so whatever sits under that
/// list moves. Under it used to be the page's one control: the window picker
/// slid by a row for every session that came or went, on a 15 s sweep, under
/// a pointer on its way to it. With the list last, nothing that can be
/// clicked sits below a reading that moves, and the re-count sits on the
/// live half's own label, above the list it re-counts.
struct PanelSessions: View {
    let block: UsagePanelSnapshot.AgentsBlock
    /// The panel's window, which the counted half answers for.
    let period: UsagePeriod
    /// When the sweep behind the live half was taken, which the tab's own
    /// label dates since the header above belongs to the whole panel.
    let observedAt: Date?
    let refreshing: Bool
    /// Re-runs the process sweep and not the counts: those come off the tail
    /// as turns land, where the sweep is on a 15 s clock and a user who has
    /// just closed three sessions is looking at a figure that is right and
    /// reads as wrong.
    let refresh: () -> Void

    /// Local to the tab: coming back asks the question again rather than
    /// showing the list opened last time. Held here rather than by the live
    /// half, so a sweep that finds no session and then one does not shut it.
    @State private var showsAllProcesses = false

    private static let sectionSpacing: CGFloat = 10
    /// Matches the panel header's: the first minute of an age is worded in
    /// seconds.
    private static let clockTick: TimeInterval = 1
    private static let refreshSize: CGFloat = 10
    fileprivate static let rowSpacing: CGFloat = 7
    fileprivate static let headlineSize: CGFloat = 18
    fileprivate static let captionSize: CGFloat = 11
    fileprivate static let rowSize: CGFloat = 12
    private static let figureSpacing: CGFloat = 28
    private static let stripHeight: CGFloat = 8
    private static let stripSpacing: CGFloat = 5
    private static let stripCorner: CGFloat = 2
    /// Where a session's load is worth the row's one colour: most of a core,
    /// held for a whole sweep, which a session waiting on its user never
    /// spends. The figure is written whatever it is; only the colour waits.
    fileprivate static let busyLoad: Double = 0.8

    /// The window the counted half answers for: the panel's, or today where
    /// the archive has not counted that one.
    private var shownPeriod: UsagePeriod {
        block.counted[period] == nil ? .today : period
    }

    private var shown: UsagePanelSnapshot.AgentsBlock.Window? {
        block.counted[shownPeriod]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.platterGap) {
            countedSection
            if let shown, shown.cache.share != nil || shown.activity.longestTurnMilliseconds != nil {
                underTheHood(shown)
            }
            liveSection
        }
        .padding(PanelMetrics.platterInset)
    }

    // MARK: Now

    private var liveSection: some View {
        PanelGroup {
            liveLabel
        } content: {
            if let live = block.live, live.running > 0 {
                PanelSessionsLive(live: live, showsAllProcesses: $showsAllProcesses)
            } else {
                idle
            }
        }
    }

    /// The live half's label, with when its sweep was taken and the re-count
    /// at the end of it, on the label rather than in the panel's header,
    /// which dates the usage reading and carries the app's own switches.
    private var liveLabel: some View {
        HStack(spacing: 6) {
            SectionLabel(text: "Now")
            Spacer(minLength: 8)
            TimelineView(.periodic(from: .now, by: Self.clockTick)) { context in
                if let line = UsageFormat.agentsReading(
                    observedAt: observedAt, refreshing: refreshing, now: context.date)
                {
                    Text(line)
                        .font(.system(size: Self.captionSize))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: Self.refreshSize, weight: .semibold))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(refreshing)
            .help("Count the running sessions again")
        }
    }

    /// A dash and no chart, which is the panel's own rule for a reading
    /// that has not happened: a flat line at zero is a measurement, and an
    /// unmeasured Mac has not made one.
    private var idle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("—")
                .font(.system(size: Self.headlineSize, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(block.summary)
                .font(.system(size: Self.captionSize))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Counted

    /// Drawn only once a window has been counted: a platter with nothing on
    /// it would claim a reading that is not there.
    @ViewBuilder
    private var countedSection: some View {
        if let shown {
            PanelGroup {
                SectionLabel(text: UsageFormat.sessionsSectionLabel(shownPeriod))
            } content: {
                VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                    HStack(alignment: .top, spacing: Self.figureSpacing) {
                        figure(shown.counts.sessions, singular: "session", plural: "sessions")
                        figure(shown.counts.agents, singular: "sub-agent", plural: "sub-agents")
                        worked(shown.activity)
                    }
                    if shown.activity.activeMinutes > 0 { strip(shown) }
                    if !shown.byProvider.isEmpty {
                        VStack(alignment: .leading, spacing: Self.rowSpacing) {
                            ForEach(shown.byProvider) { providerRow($0) }
                        }
                    }
                    if let coverage = shown.coverage {
                        Text(coverage)
                            .font(.system(size: Self.captionSize))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func figure(_ value: Int, singular: String, plural: String) -> some View {
        reading("\(value)", caption: value == 1 ? singular : plural)
    }

    /// The worked figure, which is a duration where the two beside it are
    /// counts — hence its own builder rather than `figure`'s plural.
    ///
    /// A dash for a window the archive has no shape for, which is every day
    /// written before this shipped and every day Sissy was not running: an
    /// unmeasured day is not a day of no work, and the panel draws the two
    /// differently everywhere else.
    private func worked(_ activity: ActivityTotals) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(
                activity.activeMinutes > 0
                    ? UsageFormat.workedDuration(minutes: activity.activeMinutes) : "—"
            )
            .font(.system(size: Self.headlineSize, weight: .bold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
            .foregroundStyle(activity.activeMinutes > 0 ? Color.primary : .secondary)
            Text("active")
                .font(.system(size: Self.captionSize))
                .foregroundStyle(.secondary)
        }
    }

    /// When the day was worked, as blocks along a bar of the whole day.
    ///
    /// The picture answers what the figure cannot — whether twelve hours were
    /// one stretch or seven — and it is drawn only for today, because a window
    /// of thirty days has no single day to be a picture of.
    ///
    /// One intensity, not two. Inside a block the session's own turns and its
    /// sub-agents' alternate every few minutes, and across a bar this wide
    /// that alternation is finer than a pixel: it would draw as a moiré rather
    /// than as a reading, so the delegated share is a clause in the caption
    /// where it can be read.
    @ViewBuilder
    private func strip(_ window: UsagePanelSnapshot.AgentsBlock.Window) -> some View {
        VStack(alignment: .leading, spacing: Self.stripSpacing) {
            if let shape = window.shape {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.15))
                        ForEach(shape.blocks, id: \.lowerBound) { block in
                            let span = shape.span(block)
                            RoundedRectangle(cornerRadius: Self.stripCorner)
                                .fill(Color.accentColor)
                                .frame(
                                    width: max(
                                        (span.upperBound - span.lowerBound) * geometry.size.width,
                                        Self.stripCorner)
                                )
                                .offset(x: span.lowerBound * geometry.size.width)
                        }
                    }
                }
                .frame(height: Self.stripHeight)
                .accessibilityLabel("Worked \(shape.blocks.count) times today")
            }
            Text(UsageFormat.activityCaption(window.activity, cost: window.cost))
                .font(.system(size: Self.captionSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func providerRow(_ row: UsagePanelSnapshot.AgentsBlock.ProviderCount) -> some View {
        HStack(spacing: 6) {
            ProviderMark(id: row.id)
            Text(row.name)
                .font(.system(size: Self.rowSize))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(
                UsageFormat.agentCount(
                    row.counts.sessions, singular: "session", plural: "sessions") + " · "
                    + UsageFormat.agentCount(
                        row.counts.agents, singular: "sub-agent", plural: "sub-agents")
                    + (row.activity.activeMinutes > 0
                        ? " · " + UsageFormat.workedDuration(minutes: row.activity.activeMinutes)
                        : "")
            )
            .font(.system(size: Self.rowSize))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    // MARK: Under the hood

    /// What the cache did for the window the counted half names.
    ///
    /// **Under the counted half and not under Now**, because it is a reading of
    /// the same window: the counted section names it and this follows
    /// it, where the CPU and energy in Now are counted from when each process
    /// or Sissy started and would be mislabelled by any window at all.
    ///
    /// Drawn only for a window with something to say. One figure missing is
    /// a dash, the rule `worked` keeps: a window written before turns were
    /// timed has a share and no longest turn, and that is not a turn of zero.
    ///
    /// The saving is the caption rather than a third figure, because three
    /// figures and their captions want the whole 312 pt a page has and a
    /// four-digit saving would push the last one off it.
    private func underTheHood(_ window: UsagePanelSnapshot.AgentsBlock.Window) -> some View {
        PanelGroup {
            SectionLabel(text: "Under the hood")
        } content: {
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                HStack(alignment: .top, spacing: Self.figureSpacing) {
                    reading(
                        window.cache.share.map(UsageFormat.cacheShare),
                        caption: "of input from cache")
                    reading(
                        window.activity.longestTurnMilliseconds.map(UsageFormat.turnDuration),
                        caption: "longest turn")
                }
                if window.cache.share != nil {
                    Text("\(UsageFormat.cost(window.cache.saved)) saved by the cache at list price")
                        .font(.system(size: Self.captionSize))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func reading(_ value: String?, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value ?? "—")
                .font(.system(size: Self.headlineSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(value == nil ? Color.secondary : .primary)
            Text(caption)
                .font(.system(size: Self.captionSize))
                .foregroundStyle(.secondary)
        }
    }
}

/// The live half while sessions are running: the headline, the chart and
/// its caption, the load, and the list behind the disclosure.
///
/// Its own view because the pointer's sample lives here. A hover moves it on
/// every pointer event, and while it sat on the whole tab each one rebuilt
/// the counted half, its strip and its provider rows for a reading none of
/// them answers for; here it reaches only the chart, the caption and the
/// lanes that do.
private struct PanelSessionsLive: View {
    let live: UsagePanelSnapshot.AgentsBlock.Live
    @Binding var showsAllProcesses: Bool

    /// The chart sample under the pointer, which the caption and every lane
    /// answer for while it is set.
    @State private var hoveredSample: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(UsageFormat.agentsRunning(live.running, footprint: live.footprint))
                .font(.system(size: PanelSessions.headlineSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            if let chart = live.chart {
                AgentMemoryChart(chart: chart, hovered: $hoveredSample)
            }
            Text(caption)
                .font(.system(size: PanelSessions.captionSize))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let countedSince = live.countedSince {
                Text(
                    UsageFormat.agentsLoad(
                        cpu: live.cpuTime, energy: live.energy, since: countedSince)
                )
                .font(.system(size: PanelSessions.captionSize))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help(
                    "What the sessions themselves used since Sissy started counting, "
                        + "including sessions that have since exited. "
                        + "What they started, a build or a dev server, is not in it.")
            }
            processes
        }
    }

    /// Under the pointer the caption answers for the instant it is on, and at
    /// rest for the hour: the rule the day strip keeps, where a hover replaces
    /// the caption and never the headline, so the figure a reader came for
    /// does not change on the pointer's way to the chart.
    private var caption: String {
        guard let chart = live.chart, let index = hoveredSample, index < chart.totals.count else {
            return UsageFormat.samplesSince(live.since) + " · "
                + UsageFormat.agentsWithChildren(live.treeFootprint)
        }
        let names = Dictionary(
            live.processes.map { ($0.id, UsageFormat.agentProcessName($0)) },
            uniquingKeysWith: { first, _ in first })
        return UsageFormat.chartInstant(
            chart.instant(index), total: chart.totals[index],
            leaders: chart.leaders(at: index).compactMap { leader in
                names[leader.process].map { ($0, leader.bytes) }
            })
    }

    /// One disclosure row, and behind it every running session.
    ///
    /// **Closed by default**, dated 2026-09-28: the list changes length on
    /// every 15 s sweep and the popover grows from its top edge, so a list
    /// open by default moved everything under it on every re-count. Closed,
    /// the tab holds a stable height, and what a closed list gives up the
    /// chart's hover caption already answers — it names the two sessions
    /// holding the most.
    ///
    /// Opened, it draws every running session — the rows a row limit used to
    /// keep standing and the ones it folded, together — as one list with no
    /// fold of its own. This is what answers "two gigabytes of what", and it
    /// is why a row names a repository at all: the totals above say how
    /// much, and only the rows say *where*. The repository rather than the
    /// directory, resolved the way a project row's is, so two worktrees of
    /// one checkout read as the one project they are — and the path stays on
    /// the hover, because a path is a client's name as often as not.
    private var processes: some View {
        VStack(alignment: .leading, spacing: PanelSessions.rowSpacing) {
            processDisclosure
            if showsAllProcesses {
                ForEach(live.processes) { processRow($0) }
            }
        }
        .padding(.top, 2)
    }

    private var processDisclosure: some View {
        Button {
            showsAllProcesses.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: showsAllProcesses ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                Text(UsageFormat.sessionsDisclosure)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func processRow(_ row: UsagePanelSnapshot.AgentsBlock.Process) -> some View {
        HStack(spacing: 6) {
            ProviderMark(id: row.provider)
            Text(UsageFormat.agentProcessName(row))
                .font(.system(size: PanelSessions.rowSize))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(row.project == nil ? Color.secondary : .primary)
            Spacer(minLength: 8)
            if !row.lane.isEmpty {
                CPULane(
                    lane: row.lane, tint: AgentMemoryChart.bandTint(row.band),
                    hovered: hoveredSample)
            }
            if let load = row.cpuLoad {
                Text(UsageFormat.cpuLoad(load) + " ·")
                    .font(.system(size: PanelSessions.rowSize))
                    .monospacedDigit()
                    .foregroundStyle(
                        load >= PanelSessions.busyLoad ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)
                    )
                    .lineLimit(1)
                    .help("CPU since the last sweep, as a share of one core")
            }
            Text(
                UsageFormat.bytes(row.footprint) + " · "
                    + UsageFormat.agentUptime(since: row.startedAt)
            )
            .font(.system(size: PanelSessions.rowSize))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .help(row.directory ?? "The kernel would not say where this session is working")
    }
}

/// The retained hour, split by session and stacked, the dearest at the axis.
///
/// **Filled, where the single line it replaced was not.** A fill under one
/// series that hovers near its own peak shades most of the box and reads as a
/// quantity instead of a shape; here the fill *is* the reading, because what
/// the chart answers that the line could not is whose the memory was.
///
/// **One hue in steps, never a colour per project.** Eight sessions in three
/// repositories would repeat a project's colour across bands and read as one
/// series; a step of the accent per standing row and grey for the rest is the
/// list's own order drawn, and it is the colour each row's lane carries.
///
/// **Scaled from zero**, for the reason the line was: a quiet hour that moved
/// by 40 MB stays flat, and that flatness is the reading.
struct AgentMemoryChart: View {
    let chart: UsagePanelSnapshot.AgentsBlock.MemoryChart
    @Binding var hovered: Int?

    static let plotHeight: CGFloat = 44
    private static let tickHeight: CGFloat = 4
    private static let axisSize: CGFloat = 9.5
    /// Opacity of the accent for each standing band, dearest first: one step
    /// per session the chart colours as its own band, which is
    /// `processRowLimit` sessions before the rest pool into one grey band.
    nonisolated static let bandOpacities: [Double] = [1, 0.78, 0.6, 0.45, 0.33, 0.24]
    private static let restOpacity: Double = 0.2
    private static let cursorOpacity: Double = 0.5
    private static let secondsPerMinute: Double = 60

    static func bandTint(_ band: Int?) -> Color {
        guard let band, band < bandOpacities.count else {
            return Color.secondary.opacity(restOpacity)
        }
        return Color.accentColor.opacity(bandOpacities[band])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Canvas { context, size in draw(in: &context, size: size) }
                .frame(height: Self.plotHeight + Self.tickHeight + 2)
                .contentShape(.rect)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: {
                    width = $0
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): hovered = index(at: location.x)
                    case .ended: hovered = nil
                    }
                }
            HStack {
                Text(UsageFormat.chartSpan(minutes: spanMinutes))
                Spacer(minLength: 8)
                Text("peak " + UsageFormat.bytes(chart.peak))
            }
            .font(.system(size: Self.axisSize))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
        }
        .accessibilityElement()
        .accessibilityLabel(
            "Session memory over the last \(spanMinutes) minutes, peaking at "
                + UsageFormat.bytes(chart.peak))
    }

    private var spanMinutes: Int {
        Int((Double(max(chart.totals.count - 1, 0)) * chart.interval / Self.secondsPerMinute).rounded())
    }

    /// The plot's width, for turning a hover's x into a sample: the hover
    /// arrives in the same coordinate space the canvas draws in.
    @State private var width: CGFloat = 0

    private func index(at x: CGFloat) -> Int? {
        guard width > 0, chart.totals.count > 1 else { return nil }
        let step = width / CGFloat(chart.totals.count - 1)
        return min(max(Int((x / step).rounded()), 0), chart.totals.count - 1)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let count = chart.totals.count
        guard count > 1 else { return }
        let peak = Double(max(chart.peak, 1))
        let step = size.width / CGFloat(count - 1)
        let y = { (bytes: UInt64) in Self.plotHeight * (1 - CGFloat(Double(bytes) / peak)) }
        var base = [UInt64](repeating: 0, count: count)
        for (position, band) in chart.bands.enumerated() {
            let top = zip(base, band.values).map { $0 + $1 }
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y(top[0])))
            for index in 1..<count { path.addLine(to: CGPoint(x: CGFloat(index) * step, y: y(top[index]))) }
            for index in stride(from: count - 1, through: 0, by: -1) {
                path.addLine(to: CGPoint(x: CGFloat(index) * step, y: y(base[index])))
            }
            path.closeSubpath()
            let isRest = band.process == nil
            context.fill(path, with: .color(Self.bandTint(isRest ? nil : position)))
            base = top
        }
        for start in chart.starts {
            var tick = Path()
            let x = CGFloat(start) * step
            tick.move(to: CGPoint(x: x, y: Self.plotHeight + 2))
            tick.addLine(to: CGPoint(x: x, y: Self.plotHeight + 2 + Self.tickHeight))
            context.stroke(tick, with: .color(.secondary), lineWidth: 1)
        }
        if let hovered, hovered < count {
            var cursor = Path()
            let x = CGFloat(hovered) * step
            cursor.move(to: CGPoint(x: x, y: 0))
            cursor.addLine(to: CGPoint(x: x, y: Self.plotHeight))
            context.stroke(cursor, with: .color(.primary.opacity(Self.cursorOpacity)), lineWidth: 1)
        }
    }
}

/// One session's hour, as a strip of cells whose depth is its CPU.
///
/// The same hour the chart above draws, compressed into the row, so a row
/// says whether its session is working or has sat open and idle for half of
/// it: memory says what a session holds, and only the load says whether it
/// is doing anything with it. A cell before the session started is not
/// drawn, because a session that did not exist yet did not idle.
struct CPULane: View {
    let lane: [Double?]
    let tint: Color
    let hovered: Int?

    static let width: CGFloat = 70
    private static let height: CGFloat = 9
    private static let cells = 36
    private static let floorOpacity: Double = 0.12
    private static let cellGap: CGFloat = 0.5

    var body: some View {
        Canvas { context, size in
            let cellWidth = size.width / CGFloat(Self.cells)
            for cell in 0..<Self.cells {
                guard let load = load(of: cell) else { continue }
                let rect = CGRect(
                    x: CGFloat(cell) * cellWidth, y: 0,
                    width: max(cellWidth - Self.cellGap, 0.5), height: size.height)
                let depth = Self.floorOpacity + (1 - Self.floorOpacity) * min(load, 1)
                context.fill(Path(rect), with: .color(tint.opacity(depth)))
            }
            if let hovered, lane.count > 1 {
                let x = CGFloat(hovered) / CGFloat(lane.count - 1) * size.width
                var cursor = Path()
                cursor.move(to: CGPoint(x: x, y: -1))
                cursor.addLine(to: CGPoint(x: x, y: size.height + 1))
                context.stroke(cursor, with: .color(.primary.opacity(0.6)), lineWidth: 1)
            }
        }
        .frame(width: Self.width, height: Self.height)
        .accessibilityHidden(true)
    }

    /// The mean load over one cell's samples, nil where the session was not
    /// running in any of them.
    private func load(of cell: Int) -> Double? {
        guard !lane.isEmpty else { return nil }
        let from = cell * lane.count / Self.cells
        let to = max((cell + 1) * lane.count / Self.cells, from + 1)
        let readings = lane[from..<min(to, lane.count)].compactMap { $0 }
        guard !readings.isEmpty else { return nil }
        return readings.reduce(0, +) / Double(readings.count)
    }
}
