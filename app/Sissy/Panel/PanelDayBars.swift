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
    /// The most bars a strip draws a day each, past which a bar stands for a
    /// week, a month or a year (`UsagePanelSnapshot.windowStrip`).
    ///
    /// Worked out 2026-10-03 from `PanelMetrics`: the strip spans the 312 pt
    /// inside the gutters and a bar is 62% of its slot, so up to 96 bars each
    /// one is at least as wide as the 2 pt dot that marks a day with no
    /// reading (3.25 pt slot, 2.0 pt bar). One more and a day with a reading
    /// draws narrower than a day without one. Ninety days, the archive's
    /// default retention, still draws a bar a day at 3.47 pt a slot.
    static let maxBars = Int(
        (PanelMetrics.width - 2 * PanelMetrics.gutter) * barWidthRatio / absentDotSize)
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
    ///
    /// Owned by the page rather than by this view, because two blocks read it:
    /// this one swaps its caption for the pointed day's figures, and the pills
    /// under the bars swap for that day's split. A second copy of the state
    /// would let the caption name one day while the pills answered for
    /// another.
    @Binding var hovered: String?
    /// Reads the clicked bar's days, where the strip is a way into them: the
    /// Overview's strip sets the panel's period to that day, week, month or
    /// year, and a provider's page, whose strip is a picture of its week,
    /// passes none.
    var select: ((UsageDaySpan) -> Void)?

    private var pointed: UsagePanelSnapshot.DayRow? {
        hovered.flatMap { key in strip.rows.first { $0.id == key } }
    }

    /// The caption reads the strip until the pointer names a day, and that day
    /// after.
    ///
    /// It is the same row either way rather than a second line that appears on
    /// hover: the panel sizes to its content, so a block that grew under the
    /// pointer would push everything below it down as the pointer crossed it.
    /// The strip carries no axis, so this row is where a value is read.
    ///
    /// It is drawn as a caption rather than as a heading because the block it
    /// belongs to already has one — today's own figures, which the page keeps
    /// above this line and the pointer never moves.
    var body: some View {
        VStack(alignment: .leading, spacing: DayBarGeometry.headerGap) {
            HStack(spacing: 6) {
                Text(pointed?.title ?? strip.label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(pointed?.figures ?? strip.total)
                    .font(.system(size: 10))
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
        return selectable(row, column(row, slot: slot, isPointed: isPointed))
    }

    private func column(
        _ row: UsagePanelSnapshot.DayRow, slot: CGFloat, isPointed: Bool
    ) -> some View {
        VStack(spacing: DayBarGeometry.plotLabelGap) {
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

    /// The click, only on a strip that is a way in and a bar that names its
    /// days, and announced as a button exactly there.
    @ViewBuilder
    private func selectable(_ row: UsagePanelSnapshot.DayRow, _ content: some View) -> some View {
        if let select, let span = row.span {
            content
                .onTapGesture { select(span) }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { select(span) }
        } else {
            content
        }
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
