import SwiftUI

/// How many agents have run, and what the ones running now are holding.
///
/// **A page of the panel rather than a tab of Settings**, on the grounds
/// `PanelIdentities` is: Settings holds switches and this has no lever on it
/// at all. And **not a tile on the Overview**, which answers whether there is
/// room to keep working and nothing else — a lifetime count belongs to the
/// question a person asks at the end of a period, not to the one they ask
/// while working, and putting it up there is the decorative signal on the cost
/// axis this panel already refuses.
///
/// The one line the Overview does carry is the live half, because that *is* a
/// "can I keep working" reading: a rate limit and the Mac's memory are the two
/// things that stop work now, where what a period cost is asked afterwards.
/// That line is also the only door to this page, so it is drawn whether or not
/// anything is running.
struct PanelStats: View {
    let block: UsagePanelSnapshot.AgentsBlock
    let period: UsagePeriod
    let periods: [UsagePeriod]
    let coverage: String?
    let selectPeriod: (UsagePeriod) -> Void

    private static let sectionSpacing: CGFloat = 16
    private static let labelSpacing: CGFloat = 10
    private static let rowSpacing: CGFloat = 8
    private static let headlineSize: CGFloat = 18
    private static let captionSize: CGFloat = 11
    private static let rowSize: CGFloat = 12
    private static let sparklineHeight: CGFloat = 28

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
        VStack(alignment: .leading, spacing: 6) {
            Text(UsageFormat.agentsRunning(live.running, footprint: live.footprint))
                .font(.system(size: Self.headlineSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            if !live.samples.isEmpty {
                HStack(alignment: .bottom, spacing: 8) {
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
        }
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
            HStack(alignment: .top, spacing: 24) {
                figure(block.counted.sessions, singular: "session", plural: "sessions")
                figure(block.counted.agents, singular: "agent", plural: "agents")
            }
            if !block.byProvider.isEmpty {
                VStack(alignment: .leading, spacing: Self.rowSpacing) {
                    ForEach(block.byProvider) { row in
                        providerRow(row)
                    }
                }
            }
            if let coverage {
                Text(coverage)
                    .font(.system(size: Self.captionSize))
                    .foregroundStyle(.secondary)
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
            )
            .font(.system(size: Self.rowSize))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    /// The same control the headline carries, so the two blocks are read over
    /// the window the person already chose rather than over one this page
    /// picked for them.
    private var periodPicker: some View {
        Picker("", selection: Binding(get: { period }, set: selectPeriod)) {
            ForEach(periods, id: \.self) { option in
                Text(UsageFormat.periodLabel(option)).tag(option)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
    }
}

/// The memory series, drawn as a filled line.
///
/// Scaled from zero rather than from the lowest sample: the question is how
/// much of the Mac the agents are holding, and a line auto-scaled to its own
/// range turns a quiet hour that moved by 40 MB into a mountain range.
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
                    y: geometry.size.height
                        * (1 - CGFloat(Double(value) / Double(peak)))
                )
            }
            ZStack {
                filled(points, to: geometry.size.height)
                    .fill(.tint.opacity(0.18))
                line(points)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
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

    /// The same line closed along the baseline. `baseline` is the view's own
    /// height because a `Path`'s origin is its top-left, so zero is the top of
    /// the box and closing there would shade the empty half.
    private func filled(_ points: [CGPoint], to baseline: CGFloat) -> Path {
        var path = line(points)
        guard let first = points.first, let last = points.last else { return path }
        path.addLine(to: CGPoint(x: last.x, y: baseline))
        path.addLine(to: CGPoint(x: first.x, y: baseline))
        path.closeSubpath()
        return path
    }
}
