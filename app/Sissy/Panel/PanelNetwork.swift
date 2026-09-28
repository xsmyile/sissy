import SwiftUI

/// What the Mac's links are carrying this second, the last two minutes of it,
/// and what they have carried since boot.
///
/// **Sampled only while this page is on screen.** `UsagePanelView` asks for
/// `LiveReading.network` while the tab is selected in an open panel, and the
/// engine samples once a second until the tab switches or the panel closes;
/// with the page gone nothing samples at all. So the page opens on a dash and
/// a line that starts at its right edge, and a series never spans minutes
/// nobody watched.
///
/// **The one view that reads the sample.** `engine.networkReading` is read in
/// this body and nowhere else, so a sample invalidates this page and not the
/// panel around it: the frame, its snapshot and every other page are left
/// alone. Measured 2026-09-28 on a Mac16,8 running macOS 27.0, Debug build,
/// CPU clocks in an XCTest host: this page's update costs 1.4 to 2.4 ms of the
/// main thread a sample, the sparkline about 0.5 ms of it, where a frame
/// re-renders the panel around it for 1.9 to 2.0 ms and wakes the menu bar's
/// icon besides. Building `UsagePanelSnapshot` is not what a frame costs: it
/// takes 0.06 ms. End to end at one sample a second, the page on screen adds
/// 7.5 to 9.5 ms of process CPU a second, under 1% of a core, and after the
/// demand goes the process is back at its baseline.
///
/// **The headline does not shrink to fit.** `minimumScaleFactor` cost 0.9 ms
/// of that update, measured the same day, for a line that fits anyway:
/// `UsageFormat.networkRate` keeps every figure to three digits and a unit,
/// and the widest pair, `↓ 999 MB/s` and `↑ 999 MB/s`, measures 295 pt with
/// its swatches against the 312 pt a page has.
///
/// **Fixed in height** for `PanelMac`'s reason: the Signal row comes and goes
/// with the link, never with a sample, so nothing moves under the pointer at
/// one frame a second.
struct PanelNetwork: View {
    let engine: UsageEngineHost

    @State private var hovered: Int?

    private static let rowSpacing: CGFloat = 7
    private static let captionSize: CGFloat = 11
    private static let rowSize: CGFloat = 12
    private static let swatchWidth: CGFloat = 10
    private static let swatchHeight: CGFloat = 3
    private static let figureGap: CGFloat = 14

    var body: some View {
        let reading = engine.networkReading
        return PanelGroup {
            VStack(alignment: .leading, spacing: PanelMetrics.platterVerticalPadding) {
                headline(reading)
                NetworkSparkline(rates: reading?.rates ?? [], hovered: $hovered)
                Divider()
                VStack(alignment: .leading, spacing: Self.rowSpacing) {
                    row("Interface", value: UsageFormat.networkInterface(reading?.interface))
                    if let wifi = reading?.wifi {
                        row("Signal", value: UsageFormat.networkSignal(wifi))
                    }
                    row("Since boot", value: UsageFormat.networkSinceBoot(reading?.sinceBoot))
                }
            }
        }
        .padding(PanelMetrics.platterInset)
    }

    /// Both directions as the tab's one reading, each beside the stroke its
    /// line is drawn in, which is the sparkline's legend: the figures keep the
    /// text's own colour and the swatch carries which series is which.
    private func headline(_ reading: NetworkReading?) -> some View {
        let current = reading?.current
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Self.figureGap) {
                figure(UsageFormat.networkDown(current?.received), tint: NetworkSparkline.downTint)
                figure(UsageFormat.networkUp(current?.sent), tint: NetworkSparkline.upTint)
            }
            .font(.system(size: PanelMetrics.headlineNumber, weight: .bold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(current == nil ? Color.secondary : .primary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityRate(current))
            Text(UsageFormat.networkCaption(reading?.interface))
                .font(.system(size: Self.captionSize))
                .foregroundStyle(.secondary)
        }
    }

    private func figure(_ text: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Capsule()
                .fill(tint)
                .frame(width: Self.swatchWidth, height: Self.swatchHeight)
            Text(text)
                .contentTransition(.numericText())
        }
    }

    private func accessibilityRate(_ rate: NetworkRate?) -> String {
        guard let rate else { return "No rate yet" }
        return "Receiving " + UsageFormat.networkRate(rate.received) + ", sending "
            + UsageFormat.networkRate(rate.sent)
    }

    private func row(_ label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: Self.rowSize))
    }
}

/// The last two minutes of both directions on one scale, the newest sample at
/// the right edge.
///
/// **Laid out on the monitor's two minutes, not on the samples it has**: a
/// page opened a few seconds ago draws a short line against the right edge
/// rather than stretching those seconds across the whole width, so `2 min ago`
/// under the left edge is true from the first sample.
///
/// **One scale for both series, from zero.** Down and up are the same unit and
/// the question is how they compare, so a second axis would answer a question
/// nobody asked. The scale never falls below `scaleFloor`, so a link carrying
/// nothing but its own keep-alives stays on the baseline rather than drawing
/// its noise at full height.
///
/// Blue for down and cyan for up, checked 2026-09-28 against the dataviz
/// validator: adjacent colour-blind separation at ΔE 19.1 in light and 19.6 in
/// dark. Neither is a colour this panel warns in.
struct NetworkSparkline: View {
    let rates: [NetworkRate]
    @Binding var hovered: Int?

    static let downTint = Color.blue
    static let upTint = Color.cyan
    static let plotHeight: CGFloat = 44
    /// 100 KB/s, under which the plot does not rescale.
    static let scaleFloor: Double = 100_000
    private static let lineWidth: CGFloat = 1.5
    private static let baselineOpacity: Double = 0.2
    private static let cursorOpacity: Double = 0.5
    private static let axisSize: CGFloat = 9.5
    private static let slots = NetworkMonitor.historyLength

    @State private var width: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Canvas { context, size in draw(in: &context, size: size) }
                .frame(height: Self.plotHeight)
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
            legend
                .font(.system(size: Self.axisSize))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement()
        .accessibilityLabel("Network rate over the last two minutes")
    }

    /// The axis's two ends, or the sample under the pointer in their place:
    /// a hover replaces the caption and never the headline.
    @ViewBuilder
    private var legend: some View {
        if let hovered, hovered < rates.count {
            let rate = rates[hovered]
            Text(
                UsageFormat.networkDown(rate.received) + " · " + UsageFormat.networkUp(rate.sent)
                    + " · " + UsageFormat.age(TimeInterval(rates.count - 1 - hovered)))
        } else {
            HStack {
                Text("2 min ago")
                Spacer(minLength: 8)
                Text("now")
            }
        }
    }

    private func x(ofSample index: Int, in width: CGFloat) -> CGFloat {
        let slot = Self.slots - rates.count + index
        return width * CGFloat(slot) / CGFloat(Self.slots - 1)
    }

    private func index(at x: CGFloat) -> Int? {
        guard width > 0, !rates.isEmpty else { return nil }
        let slot = Int((x / width * CGFloat(Self.slots - 1)).rounded())
        let index = slot - (Self.slots - rates.count)
        return index >= 0 && index < rates.count ? index : nil
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
        baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
        context.stroke(baseline, with: .color(.secondary.opacity(Self.baselineOpacity)), lineWidth: 1)
        guard rates.count > 1 else { return }
        let peak = max(rates.map { max($0.received, $0.sent) }.max() ?? 0, Self.scaleFloor)
        let inset = Self.lineWidth / 2
        let y = { (value: Double) in
            inset + (size.height - 2 * inset) * (1 - CGFloat(value / peak))
        }
        for (values, tint) in [(rates.map(\.sent), Self.upTint), (rates.map(\.received), Self.downTint)] {
            var line = Path()
            line.move(to: CGPoint(x: x(ofSample: 0, in: size.width), y: y(values[0])))
            for index in 1..<values.count {
                line.addLine(to: CGPoint(x: x(ofSample: index, in: size.width), y: y(values[index])))
            }
            context.stroke(
                line, with: .color(tint),
                style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round))
        }
        if let hovered, hovered < rates.count {
            var cursor = Path()
            let at = x(ofSample: hovered, in: size.width)
            cursor.move(to: CGPoint(x: at, y: 0))
            cursor.addLine(to: CGPoint(x: at, y: size.height))
            context.stroke(cursor, with: .color(.primary.opacity(Self.cursorOpacity)), lineWidth: 1)
        }
    }
}
