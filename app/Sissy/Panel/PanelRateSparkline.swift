import SwiftUI

/// Two series of the last two minutes on one scale, the newest sample at the
/// right edge: the drawing the Network and the Disk tabs share, so the two
/// sparklines mean the same by their axis and their hover.
///
/// **Laid out on the monitor's two minutes, not on the samples it has**: a
/// page opened a few seconds ago draws a short line against the right edge
/// rather than stretching those seconds across the whole width, so `2 min ago`
/// under the left edge is true from the first sample.
///
/// **One scale for both series, from zero.** The two are the same unit and
/// the question is how they compare, so a second axis would answer a question
/// nobody asked. The scale never falls below `scaleFloor`, so a link carrying
/// nothing but its own keep-alives stays on the baseline rather than drawing
/// its noise at full height.
struct RateSparkline: View {
    /// One pair a sample, so the two series cannot differ in length.
    let points: [(first: Double, second: Double)]
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
    private static let slots = NetworkMonitor.historyLength

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
        .accessibilityLabel(label)
    }

    /// The axis's two ends, or the sample under the pointer in their place:
    /// a hover replaces the caption and never the headline.
    @ViewBuilder
    private var legend: some View {
        if let hovered, hovered < count {
            Text(figures(hovered) + " · " + UsageFormat.age(TimeInterval(count - 1 - hovered)))
        } else {
            HStack {
                Text("2 min ago")
                Spacer(minLength: 8)
                Text("now")
            }
        }
    }

    private func x(ofSample index: Int, in width: CGFloat) -> CGFloat {
        let slot = Self.slots - count + index
        return width * CGFloat(slot) / CGFloat(Self.slots - 1)
    }

    private func index(at x: CGFloat) -> Int? {
        guard width > 0, !points.isEmpty else { return nil }
        let slot = Int((x / width * CGFloat(Self.slots - 1)).rounded())
        let index = slot - (Self.slots - count)
        return index >= 0 && index < count ? index : nil
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
        for (values, tint) in [(points.map(\.second), secondTint), (points.map(\.first), firstTint)] {
            var line = Path()
            line.move(to: CGPoint(x: x(ofSample: 0, in: size.width), y: y(values[0])))
            for index in 1..<values.count {
                line.addLine(to: CGPoint(x: x(ofSample: index, in: size.width), y: y(values[index])))
            }
            context.stroke(
                line, with: .color(tint),
                style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round))
        }
        if let hovered, hovered < count {
            var cursor = Path()
            let at = x(ofSample: hovered, in: size.width)
            cursor.move(to: CGPoint(x: at, y: 0))
            cursor.addLine(to: CGPoint(x: at, y: size.height))
            context.stroke(cursor, with: .color(.primary.opacity(Self.cursorOpacity)), lineWidth: 1)
        }
    }
}
