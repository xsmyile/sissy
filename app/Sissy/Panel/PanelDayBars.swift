import SwiftUI

/// The strip's geometry, apart from its drawing, so the bar and the space it
/// sits in can be asserted without rendering anything — the same shape
/// `BarGeometry` and `StatusTreeGeometry` take.
///
/// Measured 2026-09-15 at `PanelMetrics.width`: seven days over 312 pt of
/// content is a 44.6 pt slot and a 27.6 pt bar, which is wide enough to carry
/// a weekday under it. Fourteen days loses the labels and thirty collapses
/// them to an ellipsis, which is what settles the window at a week — and a
/// month-shape is #81's question on #81's axis anyway.
enum DayBarGeometry {
    static let plotHeight: CGFloat = 52
    static let labelHeight: CGFloat = 13
    static let plotLabelGap: CGFloat = 5
    static let headerGap: CGFloat = 8
    /// Shared by the bar and by nothing else, so the mark and the space it
    /// sits in cannot drift apart.
    static let barWidthRatio: CGFloat = 0.62
    static let cornerRadius: CGFloat = 1.5
    /// A day that cost something always draws, however little: a bar rounded
    /// away to nothing is indistinguishable from the dot that means there was
    /// no reading at all.
    static let minBarHeight: CGFloat = 2
    static let absentDotSize: CGFloat = 2
    /// Today is still being counted, so it is drawn as a bar that has not
    /// finished rather than as one of the closed days beside it.
    static let todayOpacity: Double = 0.45

    /// The plot and the weekdays under it. It does not vary with the number of
    /// days: the bars divide a fixed width, they do not stack.
    static let stripHeight: CGFloat = plotHeight + plotLabelGap + labelHeight

    static func slot(width: CGFloat, days: Int) -> CGFloat {
        days > 0 ? width / CGFloat(days) : 0
    }

    /// Only ever asked about a day that has a reading, which is why a fraction
    /// of zero still draws: a day that genuinely cost nothing is a fact about
    /// the week, and drawing it as empty space would make it indistinguishable
    /// from a day nobody measured.
    static func barHeight(fraction: Double) -> CGFloat {
        max(minBarHeight, CGFloat(max(fraction, 0)) * plotHeight)
    }
}

/// What a provider's last few days cost, one bar each.
///
/// It answers one question the rest of the page cannot: whether today is a big
/// day. The page prints what today cost and what the limits have left, and a
/// figure on its own has no scale — $514 means nothing until it sits beside
/// the four days before it. The weekday under each bar is the scale: "is this
/// a lot" is answered against last Tuesday, not against a date.
///
/// It is a reading rather than a decoration, which is the line `AGENTS.md`
/// draws on the cost axis. Nothing here judges the spend, ranks it or reacts
/// to it; the strip shows the days and stops.
struct PanelDayBars: View {
    let strip: UsagePanelSnapshot.DayStrip
    let tint: Color

    /// The day under the pointer, by day key.
    @State private var hovered: String?

    private var pointed: UsagePanelSnapshot.DayRow? {
        hovered.flatMap { key in strip.rows.first { $0.id == key } }
    }

    /// The header reads the strip until the pointer names a day, and that day
    /// after.
    ///
    /// It is the same row either way rather than a second line that appears on
    /// hover: the panel sizes to its content, so a block that grew under the
    /// pointer would push everything below it down as the pointer crossed it.
    /// The strip carries no axis, so this row is where a value is read.
    var body: some View {
        VStack(alignment: .leading, spacing: DayBarGeometry.headerGap) {
            HStack(spacing: 6) {
                SectionLabel(text: pointed?.title ?? strip.label)
                Spacer(minLength: 0)
                Text(pointed?.figures ?? strip.total)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .animation(nil, value: hovered)

            GeometryReader { geo in
                let slot = DayBarGeometry.slot(width: geo.size.width, days: strip.rows.count)
                HStack(spacing: 0) {
                    ForEach(strip.rows) { row in
                        day(row, slot: slot)
                    }
                }
            }
            .frame(height: DayBarGeometry.stripHeight)
        }
        .onHover { inside in
            if !inside { hovered = nil }
        }
    }

    /// One day's slot, which is also its hover target: the bar is 62% of the
    /// slot, and a pointer between two bars is still pointing at one of them.
    private func day(_ row: UsagePanelSnapshot.DayRow, slot: CGFloat) -> some View {
        let isPointed = hovered == row.id
        return VStack(spacing: DayBarGeometry.plotLabelGap) {
            ZStack(alignment: .bottom) {
                Color.clear
                mark(row, width: slot * DayBarGeometry.barWidthRatio, isPointed: isPointed)
            }
            .frame(height: DayBarGeometry.plotHeight)

            Text(row.label)
                .font(.system(size: 10))
                .foregroundStyle(labelColour(row, isPointed: isPointed))
                .frame(height: DayBarGeometry.labelHeight)
        }
        .frame(width: slot)
        .contentShape(.rect)
        .onHover { inside in
            if inside {
                hovered = row.id
            } else if hovered == row.id {
                hovered = nil
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(row.title) · \(row.figures)")
    }

    /// The pointed day's own label comes forward, which is what pairs the bar
    /// with the figures the header has just swapped in.
    private func labelColour(
        _ row: UsagePanelSnapshot.DayRow, isPointed: Bool
    ) -> Color {
        if isPointed { return .primary }
        return row.isToday ? .secondary : Color(nsColor: .tertiaryLabelColor)
    }

    /// A bar for a day with a reading, a dot on the baseline for one without.
    ///
    /// The dot is deliberately not a short bar: a day Sissy was not running
    /// for has no reading, and the shortest bar in the strip is a day that
    /// genuinely cost almost nothing. Drawing them the same way would put
    /// Sissy's own downtime into someone's week as a quiet day.
    @ViewBuilder
    private func mark(
        _ row: UsagePanelSnapshot.DayRow, width: CGFloat, isPointed: Bool
    ) -> some View {
        if row.cost == nil {
            Circle()
                .fill(Color(nsColor: isPointed ? .secondaryLabelColor : .tertiaryLabelColor))
                .frame(width: DayBarGeometry.absentDotSize, height: DayBarGeometry.absentDotSize)
        } else {
            RoundedRectangle(cornerRadius: DayBarGeometry.cornerRadius, style: .continuous)
                .fill(
                    row.isToday && !isPointed
                        ? tint.opacity(DayBarGeometry.todayOpacity) : tint
                )
                .frame(width: width, height: DayBarGeometry.barHeight(fraction: row.fraction))
        }
    }
}
