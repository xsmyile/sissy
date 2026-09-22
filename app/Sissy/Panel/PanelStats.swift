import SwiftUI

/// How many agents have run, and what the ones running now are holding.
///
/// **A page of the panel rather than a tab of Settings**, on the grounds
/// `PanelIdentities` is: Settings holds switches and this has no lever on it
/// at all. And **not a tile on the Overview**, which answers whether there is
/// room to keep working and nothing else — a lifetime count belongs to the
/// question a person asks at the end of a period, not to the one they ask
/// while working.
///
/// The one reading the Overview does carry is the live half, because that *is*
/// a "can I keep working" reading: a rate limit and the Mac's memory are the
/// two things that stop work now. It sits at the end of the providers label and
/// is the only door to this page, so it is drawn whether or not anything is
/// running.
///
/// **The window is this page's own.** It used to be the headline's, which was
/// wrong twice over: the Overview shows none of these figures, so sharing the
/// selection bought nothing, and changing it here moved the money headline
/// behind the user's back. Local means it resets on the way out, which is the
/// arrangement `PanelIdentities.showsAll` already has and for the same reason
/// — a page that opens on the answer to the question before last has to be
/// read before it can be glanced at.
///
/// **The counted half leads and the live half follows**, although the door
/// to the page is the live reading. The live half changes length with every
/// sweep — an agent starting or exiting is a row — and the popover grows from
/// its top edge, so whatever sits under that list moves. Under it used to be
/// the page's one control: the window picker slid by a row for every agent
/// that came or went, on a 15 s sweep, under a pointer on its way to it. With
/// the list last, nothing that can be clicked sits below a reading that moves.
struct PanelStats: View {
    let block: UsagePanelSnapshot.AgentsBlock

    @State private var window = UsagePanelSnapshot.AgentsBlock.defaultPeriod
    /// Local to the page for the reason `window` is: coming back asks the
    /// question again rather than showing the list opened last time.
    @State private var showsAllProcesses = false
    /// The chart sample under the pointer, which the caption and every lane
    /// answer for while it is set.
    @State private var hoveredSample: Int?

    private static let sectionSpacing: CGFloat = 16
    private static let labelSpacing: CGFloat = 10
    private static let rowSpacing: CGFloat = 7
    private static let headlineSize: CGFloat = 18
    private static let captionSize: CGFloat = 11
    private static let rowSize: CGFloat = 12
    private static let figureSpacing: CGFloat = 28
    private static let stripHeight: CGFloat = 8
    private static let stripSpacing: CGFloat = 5
    private static let stripCorner: CGFloat = 2
    /// Where an agent's load is worth the row's one colour: most of a core,
    /// held for a whole sweep, which a session waiting on its user never
    /// spends. The figure is written whatever it is; only the colour waits.
    private static let busyLoad: Double = 0.8

    /// The chosen window, falling back to today for a period the archive has
    /// stopped answering for while the page was open.
    private var shown: UsagePanelSnapshot.AgentsBlock.Window? {
        block.counted[window] ?? block.counted[.today]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            countedSection
            if let shown, let share = shown.cache.share {
                Divider()
                underTheHood(shown.cache, share: share)
            }
            Divider()
            liveSection
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 12)
    }

    // MARK: Now

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: Self.labelSpacing) {
            SectionLabel(text: "Now")
            if let live = block.live, live.running > 0 {
                running(live)
            } else {
                idle
            }
        }
    }

    private func running(_ live: UsagePanelSnapshot.AgentsBlock.Live) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(UsageFormat.agentsRunning(live.running, footprint: live.footprint))
                .font(.system(size: Self.headlineSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            if let chart = live.chart {
                AgentMemoryChart(chart: chart, hovered: $hoveredSample)
            }
            Text(caption(live))
                .font(.system(size: Self.captionSize))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let countedSince = live.countedSince {
                Text(
                    UsageFormat.agentsLoad(
                        cpu: live.cpuTime, energy: live.energy, since: countedSince)
                )
                .font(.system(size: Self.captionSize))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help(
                    "What the agents themselves used since Sissy started counting, "
                        + "including agents that have since exited. "
                        + "What they started, a build or a dev server, is not in it.")
            }
            processes(live)
        }
    }

    /// Under the pointer the caption answers for the instant it is on, and at
    /// rest for the hour: the rule the day strip keeps, where a hover replaces
    /// the caption and never the headline, so the figure a reader came for
    /// does not change on the pointer's way to the chart.
    private func caption(_ live: UsagePanelSnapshot.AgentsBlock.Live) -> String {
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

    /// One row per running agent.
    ///
    /// This is what answers "two gigabytes of what", and it is why the reading
    /// names a repository at all: the totals above say how much, and only the
    /// rows say *where*. The repository rather than the directory, resolved the
    /// way a project row's is, so two worktrees of one checkout read as the one
    /// project they are — and the path stays on the hover, because a path is a
    /// client's name as often as not.
    ///
    /// Past `processRowLimit` the rest fold behind one row carrying what they
    /// hold, and open *under* it, so the control stays where the pointer is —
    /// the arrangement the identities page's disclosure has.
    private func processes(_ live: UsagePanelSnapshot.AgentsBlock.Live) -> some View {
        let folded = live.foldedProcesses
        return VStack(alignment: .leading, spacing: Self.rowSpacing) {
            ForEach(live.standingProcesses) { processRow($0) }
            if !folded.isEmpty {
                processDisclosure(folded)
                if showsAllProcesses {
                    ForEach(folded) { processRow($0) }
                }
            }
        }
        .padding(.top, 2)
    }

    private func processDisclosure(_ folded: [UsagePanelSnapshot.AgentsBlock.Process])
        -> some View
    {
        Button {
            showsAllProcesses.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: showsAllProcesses ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                Text(
                    UsageFormat.agentsFolded(
                        folded.count, footprint: folded.reduce(0) { $0 + $1.footprint })
                )
                .monospacedDigit()
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
                .font(.system(size: Self.rowSize))
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
                    .font(.system(size: Self.rowSize))
                    .monospacedDigit()
                    .foregroundStyle(
                        load >= Self.busyLoad ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)
                    )
                    .lineLimit(1)
                    .help("CPU since the last sweep, as a share of one core")
            }
            Text(
                UsageFormat.bytes(row.footprint) + " · "
                    + UsageFormat.agentUptime(since: row.startedAt)
            )
            .font(.system(size: Self.rowSize))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .help(row.directory ?? "The kernel would not say where this agent is working")
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

    private var countedSection: some View {
        VStack(alignment: .leading, spacing: Self.labelSpacing) {
            HStack(spacing: 6) {
                SectionLabel(text: "Sessions and agents")
                Spacer(minLength: 0)
                periodPicker
            }
            if let shown {
                HStack(alignment: .top, spacing: Self.figureSpacing) {
                    figure(shown.counts.sessions, singular: "session", plural: "sessions")
                    figure(shown.counts.agents, singular: "agent", plural: "agents")
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

    private func figure(_ value: Int, singular: String, plural: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(.system(size: Self.headlineSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(value == 1 ? singular : plural)
                .font(.system(size: Self.captionSize))
                .foregroundStyle(.secondary)
        }
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
                        row.counts.agents, singular: "agent", plural: "agents")
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

    /// What the cache did for the window the picker above names.
    ///
    /// **Under the counted half and not under Now**, because it is a reading of
    /// the same window: the picker is the counted section's and this follows
    /// it, where the CPU and energy in Now are counted from when each process
    /// or Sissy started and would be mislabelled by any window at all.
    ///
    /// Drawn only for a window that sent input. A window with none has no
    /// share to state, and a section whose one figure is a dash is a heading
    /// with nothing under it.
    private func underTheHood(_ cache: CacheReading, share: Double) -> some View {
        VStack(alignment: .leading, spacing: Self.labelSpacing) {
            SectionLabel(text: "Under the hood")
            HStack(alignment: .top, spacing: Self.figureSpacing) {
                reading(UsageFormat.cacheShare(share), caption: "of input from cache")
                reading(UsageFormat.cost(cache.saved), caption: "saved at list price")
            }
        }
    }

    private func reading(_ value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: Self.headlineSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(caption)
                .font(.system(size: Self.captionSize))
                .foregroundStyle(.secondary)
        }
    }

    private var periodPicker: some View {
        Picker("", selection: $window) {
            ForEach(block.periods, id: \.self) { option in
                Text(UsageFormat.periodLabel(option)).tag(option)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
    }
}

/// The retained hour, split by agent and stacked, the dearest at the axis.
///
/// **Filled, where the single line it replaced was not.** A fill under one
/// series that hovers near its own peak shades most of the box and reads as a
/// quantity instead of a shape; here the fill *is* the reading, because what
/// the chart answers that the line could not is whose the memory was.
///
/// **One hue in steps, never a colour per project.** Eight agents in three
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
    /// per row the list can draw without folding, which is
    /// `processRowLimit` — six when exactly six agents run.
    static let bandOpacities: [Double] = [1, 0.78, 0.6, 0.45, 0.33, 0.24]
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
            "Agent memory over the last \(spanMinutes) minutes, peaking at "
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

/// One agent's hour, as a strip of cells whose depth is its CPU.
///
/// The same hour the chart above draws, compressed into the row, so a row
/// says whether its agent is working or has sat open and idle for half of
/// it: memory says what a session holds, and only the load says whether it
/// is doing anything with it. A cell before the agent started is not drawn,
/// because an agent that did not exist yet did not idle.
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

    /// The mean load over one cell's samples, nil where the agent was not
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
