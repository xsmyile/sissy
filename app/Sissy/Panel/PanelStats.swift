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
/// The one line the Overview does carry is the live half, because that *is* a
/// "can I keep working" reading: a rate limit and the Mac's memory are the two
/// things that stop work now. That line is also the only door to this page, so
/// it is drawn whether or not anything is running.
///
/// **The window is this page's own.** It used to be the headline's, which was
/// wrong twice over: the Overview shows none of these figures, so sharing the
/// selection bought nothing, and changing it here moved the money headline
/// behind the user's back. Local means it resets on the way out, which is the
/// arrangement `PanelIdentities.showsAll` already has and for the same reason
/// — a page that opens on the answer to the question before last has to be
/// read before it can be glanced at.
struct PanelStats: View {
    let block: UsagePanelSnapshot.AgentsBlock

    @State private var window = UsagePanelSnapshot.AgentsBlock.defaultPeriod

    private static let sectionSpacing: CGFloat = 16
    private static let labelSpacing: CGFloat = 10
    private static let rowSpacing: CGFloat = 7
    private static let headlineSize: CGFloat = 18
    private static let captionSize: CGFloat = 11
    private static let rowSize: CGFloat = 12
    private static let sparklineHeight: CGFloat = 26
    private static let figureSpacing: CGFloat = 28
    private static let stripHeight: CGFloat = 8
    private static let stripSpacing: CGFloat = 5
    private static let stripCorner: CGFloat = 2
    /// What two pills leave between them, the same gap `PanelDayBlock` sets
    /// for the row it draws with the same component.
    private static let pillGap: CGFloat = 4

    /// The chosen window, falling back to today for a period the archive has
    /// stopped answering for while the page was open.
    private var shown: UsagePanelSnapshot.AgentsBlock.Window? {
        block.counted[window] ?? block.counted[.today]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            liveSection
            Divider()
            countedSection
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
            if !live.samples.isEmpty {
                HStack(alignment: .center, spacing: 8) {
                    Sparkline(samples: live.samples)
                        .frame(height: Self.sparklineHeight)
                    Text(UsageFormat.bytes(live.peak))
                        .font(.system(size: Self.captionSize))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Text(
                UsageFormat.samplesSince(live.since) + " · "
                    + UsageFormat.agentsWithChildren(live.treeFootprint)
            )
            .font(.system(size: Self.captionSize))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            processes(live.processes)
        }
    }

    /// One row per running agent.
    ///
    /// This is what answers "two gigabytes of what", and it is why the reading
    /// names a repository at all: the totals above say how much, and only the
    /// rows say *where*. The repository rather than the directory, resolved the
    /// way a project row's is, so two worktrees of one checkout read as the one
    /// project they are — and the path stays on the hover, because a path is a
    /// client's name as often as not.
    private func processes(_ rows: [UsagePanelSnapshot.AgentsBlock.Process]) -> some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    ProviderMark(id: row.provider)
                    Text(UsageFormat.agentProcessName(row))
                        .font(.system(size: Self.rowSize))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(row.project == nil ? Color.secondary : .primary)
                    Spacer(minLength: 8)
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
        }
        .padding(.top, 2)
    }

    /// A dash and no sparkline, which is the panel's own rule for a reading
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
                if !shown.effort.isEmpty { effortPills(shown.effort) }
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

    /// At what effort the window was worked, as a pill per setting.
    ///
    /// **Here rather than on a provider's own page**, where the day's block
    /// answers where the money went: an effort changes no rate, so it splits
    /// no spend. It is also all but constant within a day — measured
    /// 2026-09-22, 99.7% of this machine's turns ran at one value — and unlike
    /// a model's name it is a setting the user chose rather than something to
    /// discover. Over a window the same figure stops repeating and starts
    /// answering: "the whole week ran at xhigh" is worth a line where "today
    /// ran at xhigh" is not.
    ///
    /// Under the per-provider rows, inside the section that already owns a
    /// period picker — which is what lets this inherit a window rather than
    /// invent a second selector in a 340 pt panel.
    private func effortPills(_ rows: [UsagePanelSnapshot.ModelRow]) -> some View {
        HStack(spacing: Self.pillGap) {
            ForEach(rows) { ModelPill(row: $0) }
            Spacer(minLength: 0)
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

/// The memory series, drawn as a line.
///
/// **Unfilled.** A fill under a series that hovers near its own peak shades
/// most of the box, which reads as a quantity rather than as a shape and hides
/// the only thing the graph is for — whether the number is climbing.
///
/// **Scaled from zero**, so a quiet hour that moved by 40 MB stays a flat line
/// rather than becoming a mountain range. That flatness is the reading: the
/// question is whether memory is growing, and a steady line answers it.
private struct Sparkline: View {
    let samples: [UInt64]

    var body: some View {
        GeometryReader { geometry in
            let peak = max(samples.max() ?? 1, 1)
            let step =
                samples.count > 1 ? geometry.size.width / CGFloat(samples.count - 1) : 0
            let points = samples.enumerated().map { index, value in
                CGPoint(
                    x: CGFloat(index) * step,
                    y: geometry.size.height * (1 - CGFloat(Double(value) / Double(peak)))
                )
            }
            line(points)
                .stroke(.tint, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }

    private func line(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }
}
