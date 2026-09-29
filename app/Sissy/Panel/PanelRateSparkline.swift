import SwiftUI

/// Two series of the last two minutes on one scale, the newest sample at the
/// right edge: the drawing the Network and the Disk tabs share, so the two
/// sparklines mean the same by their axis and their hover.
///
/// **Laid out by time over the window ending at the latest sample, not by
/// index**: a series fed every five seconds in the background and every
/// second while its page is on screen has two spacings in one line, and each
/// point sits where its own time puts it, see `LiveCadence`. A series shorter
/// than `LiveCadence.window` draws a short line against the right edge rather
/// than stretching across the whole width, so `2 min ago` under the left edge
/// is true from the first sample.
///
/// **One scale for both series, from zero.** The two are the same unit and
/// the question is how they compare, so a second axis would answer a question
/// nobody asked. The scale never falls below `scaleFloor`, so a link carrying
/// nothing but its own keep-alives stays on the baseline rather than drawing
/// its noise at full height.
struct RateSparkline: View {
    /// One sample's two figures, so the two series cannot differ in length,
    /// dated by the sample that closed its gap.
    struct Point {
        let at: Date
        let first: Double
        let second: Double
    }

    let points: [Point]
    /// The right edge: the time of the latest sample.
    let now: Date
    let firstTint: Color
    let secondTint: Color
    let scaleFloor: Double
    let label: String
    /// The two figures of the sample under the pointer, worded by the page
    /// that owns the unit.
    let figures: (Int) -> String
    @Binding var hovered: Int?

    private static let plotHeight: CGFloat = 44
    private static let lineWidth: CGFloat = 1.5
    private static let baselineOpacity: Double = 0.2
    private static let cursorOpacity: Double = 0.5
    private static let axisSize: CGFloat = 9.5
    /// How far left of the oldest point the pointer still picks it: half a
    /// watched step, the reach a slot a second gave before the points were
    /// placed by time.
    static let hoverSlack: TimeInterval = 0.5

    @State private var width: CGFloat = 0

    private var count: Int { points.count }

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
                    case .active(let location):
                        hovered = Self.index(at: location.x, of: points.map(\.at), now: now, width: width)
                    case .ended: hovered = nil
                    }
                }
            legend
                .font(.system(size: Self.axisSize))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    /// The axis's two ends, or the sample under the pointer in their place:
    /// a hover replaces the caption and never the headline.
    @ViewBuilder
    private var legend: some View {
        if let hovered, hovered < count {
            Text(figures(hovered) + " · " + UsageFormat.age(now.timeIntervalSince(points[hovered].at)))
        } else {
            HStack {
                Text("2 min ago")
                Spacer(minLength: 8)
                Text("now")
            }
        }
    }

    /// Where a point taken at `at` sits across `width`: `now` at the right
    /// edge and `LiveCadence.window` before it at the left, clamped to both,
    /// so a clock that moved cannot draw a point off the plot.
    static func x(of at: Date, now: Date, width: CGFloat) -> CGFloat {
        let fraction = 1 - now.timeIntervalSince(at) / LiveCadence.window
        return width * CGFloat(min(max(fraction, 0), 1))
    }

    /// The point nearest in time to the pointer at `x`, or nil where the
    /// pointer is left of the oldest by more than `hoverSlack`, which is
    /// minutes the series never saw.
    static func index(at x: CGFloat, of times: [Date], now: Date, width: CGFloat) -> Int? {
        guard width > 0, let oldest = times.first else { return nil }
        let pointer = now.addingTimeInterval(-LiveCadence.window * (1 - Double(x / width)))
        guard pointer >= oldest.addingTimeInterval(-hoverSlack) else { return nil }
        let distance = { (index: Int) in abs(times[index].timeIntervalSince(pointer)) }
        return times.indices.min { distance($0) < distance($1) }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
        baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
        context.stroke(baseline, with: .color(.secondary.opacity(Self.baselineOpacity)), lineWidth: 1)
        guard count > 1 else { return }
        let peak = max(points.flatMap { [$0.first, $0.second] }.max() ?? 0, scaleFloor)
        let inset = Self.lineWidth / 2
        let y = { (value: Double) in
            inset + (size.height - 2 * inset) * (1 - CGFloat(value / peak))
        }
        let xs = points.map { Self.x(of: $0.at, now: now, width: size.width) }
        for (values, tint) in [(points.map(\.second), secondTint), (points.map(\.first), firstTint)] {
            var line = Path()
            line.move(to: CGPoint(x: xs[0], y: y(values[0])))
            for index in 1..<values.count {
                line.addLine(to: CGPoint(x: xs[index], y: y(values[index])))
            }
            context.stroke(
                line, with: .color(tint),
                style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round))
        }
        if let hovered, hovered < count {
            var cursor = Path()
            let at = xs[hovered]
            cursor.move(to: CGPoint(x: at, y: 0))
            cursor.addLine(to: CGPoint(x: at, y: size.height))
            context.stroke(cursor, with: .color(.primary.opacity(Self.cursorOpacity)), lineWidth: 1)
        }
    }
}

/// One direction's current rate over a `RateSparkline`, with the swatch of
/// the series it names, so the figure reads as that series' legend.
///
/// Shared by the Network and Disk tabs, which draw the same two-series plot
/// and so owe it the same legend.
struct RateFigure: View {
    let text: String
    let tint: Color

    /// Between the two figures of one legend.
    static let gap: CGFloat = 14
    private static let swatchWidth: CGFloat = 10
    private static let swatchHeight: CGFloat = 3

    var body: some View {
        HStack(spacing: 5) {
            Capsule()
                .fill(tint)
                .frame(width: Self.swatchWidth, height: Self.swatchHeight)
            Text(text)
                .contentTransition(.numericText())
        }
    }
}
