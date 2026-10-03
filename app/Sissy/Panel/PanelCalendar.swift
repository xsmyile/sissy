import SwiftUI

/// One month of the archive as a calendar grid, apart from its drawing so the
/// cells can be asserted without rendering anything, the shape
/// `DayBarGeometry` takes.
struct CalendarMonth: Equatable {
    struct Cell: Equatable, Identifiable {
        /// The day's archive key, `yyyy-MM-dd`.
        let id: String
        let day: Date
        let number: String
        /// What the day cost, nil for a day the archive holds no file for and
        /// for a day that has not happened: an absent reading is not a zero.
        let cost: Decimal?
        /// Of the month's dearest day, so the bars read without an axis.
        let fraction: Double
        let isToday: Bool
        let isFuture: Bool
        /// The day named and its figures, for the caption on hover.
        let title: String
        let figures: String
    }

    /// The first of the month, at local midnight.
    let month: Date
    /// Empty cells before the first, so it lands under its weekday.
    let leading: Int
    let cells: [Cell]
    /// What the caption reads while the pointer names no day: the month, and
    /// how many of its days the archive holds once the month has been read.
    let caption: String
    let total: String

    /// The grid for `month`, filled from `reading` when it is that month's.
    /// A reading of another month is ignored rather than drawn under this
    /// one's days, which is what a reply landing after a page turn would be.
    static func make(
        month: Date, reading: UsageSpanReading?, now: Date = Date(),
        calendar: Calendar = .current
    ) -> Self? {
        guard let interval = calendar.dateInterval(of: .month, for: month),
            let count = calendar.range(of: .day, in: .month, for: interval.start)?.count
        else { return nil }
        let first = interval.start
        let today = calendar.startOfDay(for: now)
        let span = UsageDaySpan.month(containing: first, now: now, calendar: calendar)
        let matching = span.flatMap { reading?.rollup.period == .days($0) ? reading : nil }
        let byDay = Dictionary(
            (matching?.days ?? []).map { (calendar.startOfDay(for: $0.day), $0) },
            uniquingKeysWith: { _, last in last })
        let peak = byDay.values.map(\.cost).max() ?? 0
        let cells: [Cell] = (0..<count).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: first) else {
                return nil
            }
            let total = byDay[day]
            return Cell(
                id: UsageReaderShared.dayFormatter.string(from: day),
                day: day,
                number: "\(offset + 1)",
                cost: total?.cost,
                fraction: fraction(total?.cost, of: peak),
                isToday: day == today,
                isFuture: day > today,
                title: UsageFormat.dayTitle(day),
                figures: UsageFormat.dayFigures(tokens: total?.tokens, cost: total?.cost))
        }
        let weekday = calendar.component(.weekday, from: first)
        return Self(
            month: first,
            leading: (weekday - calendar.firstWeekday + 7) % 7,
            cells: cells,
            caption: UsageFormat.calendarMonth(
                first, covered: matching.map { _ in byDay.count },
                days: span?.dayCount(calendar: calendar) ?? 0, now: now, calendar: calendar),
            total: matching.map {
                UsageFormat.dayFigures(tokens: $0.rollup.tokens, cost: $0.rollup.cost)
            } ?? "—")
    }

    /// What the days from `from` through `to` came to, for the caption while
    /// a run of them is being dragged across.
    func total(from: Date, to: Date) -> String {
        let run = cells.filter { $0.day >= from && $0.day <= to }
        guard run.contains(where: { $0.cost != nil }) else { return UsageFormat.notRunning }
        let spent = run.reduce(Decimal(0)) { $0 + ($1.cost ?? 0) }
        return UsageFormat.cost(spent)
    }

    private static func fraction(_ value: Decimal?, of peak: Decimal) -> Double {
        guard let value, peak > 0, value > 0 else { return 0 }
        return min(
            NSDecimalNumber(decimal: value).doubleValue
                / NSDecimalNumber(decimal: peak).doubleValue, 1)
    }
}

/// The calendar page: the presets, and a month of the archive to pick a day
/// or a run of days from.
///
/// **A page, never a nested popover**, for the reason `PanelProviderStatusPage`
/// is one: a popover inside the panel leaves the panel's window drawing from
/// the wrong edge when it closes, and #185 took the last of them out.
///
/// **Each day is a bar, as on a provider's strip**: its height is its cost
/// against the month's dearest day and nothing else, no colour threshold, a
/// day the archive holds no file for is a dot on the baseline, and a day that
/// has not happened is drawn and cannot be picked. A pick returns to the page
/// the calendar was opened from, which now reads over it.
///
/// The month is read only while this page is on screen, once per page turn,
/// and never on the frame path.
struct PanelCalendar: View {
    let period: UsageRange
    /// The presets the archive can answer, in the control's order.
    let periods: [UsagePeriod]
    /// The window being read, its tokens and its cost, as one line.
    let reading: String
    /// The days the panel is reading over, drawn as a light band.
    let window: UsageDaySpan?
    /// The first day the archive holds, which is as far back as the months go.
    let earliest: Date?
    let load: (UsageDaySpan) async -> UsageSpanReading?
    let select: (UsageRange) -> Void

    @State private var month: Date?
    @State private var monthReading: UsageSpanReading?
    @State private var pointed: Date?
    @State private var run: Run?

    /// The day a drag started on and the day it is over now, in either order.
    private struct Run: Equatable {
        let anchor: Date
        var current: Date

        var from: Date { min(anchor, current) }
        var to: Date { max(anchor, current) }
    }

    private static let rowHeight: CGFloat = 34
    private static let weekdayHeight: CGFloat = 14
    private static let numberSize: CGFloat = 11
    private static let ringSize: CGFloat = 20
    private static let barMaxHeight: CGFloat = 8
    private static let barWidthRatio: CGFloat = 0.42
    private static let cellRadius: CGFloat = 5
    private static let bandOpacity: Double = 0.12
    private static let runOpacity: Double = 0.3
    private static let presetHeight: CGFloat = 24
    private static let presetInset: CGFloat = 2
    private static let presetFill = PanelMetrics.adaptiveWhite(dark: 0.16, light: 0.9)

    var body: some View {
        let now = Date()
        let shown = month ?? Self.startOfMonth(window?.to ?? now)
        let grid = CalendarMonth.make(month: shown, reading: monthReading, now: now)
        return VStack(alignment: .leading, spacing: PanelMetrics.platterGap) {
            PanelGroup {
                VStack(alignment: .leading, spacing: 8) {
                    presets
                    Text(reading)
                        .font(.system(size: PanelMetrics.headlineMeta))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let grid {
                PanelGroup {
                    VStack(alignment: .leading, spacing: DayBarGeometry.headerGap) {
                        caption(grid, now: now)
                        weekdays
                        cells(grid)
                    }
                }
            }
        }
        .padding(PanelMetrics.platterInset)
        .task(id: shown) {
            guard let span = UsageDaySpan.month(containing: shown, now: now) else { return }
            let reading = await load(span)
            guard !Task.isCancelled else { return }
            monthReading = reading
        }
    }

    // MARK: Presets

    private var presets: some View {
        HStack(spacing: 0) {
            ForEach(periods, id: \.self) { preset in
                let isSelected = period == .preset(preset)
                Button {
                    select(.preset(preset))
                } label: {
                    Text(UsageFormat.periodLabel(preset))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            if isSelected { Capsule().fill(Self.presetFill) }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(Self.presetInset)
        .frame(height: Self.presetHeight)
        .background(Capsule().fill(.quaternary))
    }

    // MARK: Month

    /// The month and what it came to, swapped for the pointed day's figures
    /// or the dragged run's total; the same row either way, so the grid
    /// under it does not move as the pointer crosses it.
    private func caption(_ grid: CalendarMonth, now: Date) -> some View {
        let title: String
        let figures: String
        if let run, run.anchor != run.current,
            let span = UsageDaySpan(from: run.from, to: run.to, now: now)
        {
            title = UsageFormat.spanHeading(span, now: now)
            figures = grid.total(from: run.from, to: run.to)
        } else if let pointed, let cell = grid.cells.first(where: { $0.day == pointed }) {
            title = cell.title
            figures = cell.isFuture ? "" : cell.figures
        } else {
            title = grid.caption
            figures = grid.total
        }
        return HStack(spacing: 6) {
            pageButton("chevron.left", to: previous(grid.month), help: "Previous month")
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(figures)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            pageButton("chevron.right", to: next(grid.month, now: now), help: "Next month")
        }
        .lineLimit(1)
        .animation(nil, value: pointed)
    }

    private func pageButton(_ symbol: String, to target: Date?, help: String) -> some View {
        Button {
            if let target {
                month = target
                pointed = nil
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 16, height: 16)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(target == nil)
        .help(help)
    }

    /// The month before, while the archive reaches back into it.
    private func previous(_ shown: Date) -> Date? {
        let calendar = Calendar.current
        guard let earliest, Self.startOfMonth(earliest) < shown else { return nil }
        return calendar.date(byAdding: .month, value: -1, to: shown)
    }

    /// The month after, up to the one holding today.
    private func next(_ shown: Date, now: Date) -> Date? {
        guard shown < Self.startOfMonth(now) else { return nil }
        return Calendar.current.date(byAdding: .month, value: 1, to: shown)
    }

    private static func startOfMonth(_ day: Date) -> Date {
        Calendar.current.dateInterval(of: .month, for: day)?.start ?? Calendar.current.startOfDay(for: day)
    }

    /// The weekdays in the order the user's calendar starts its week on.
    private var weekdays: some View {
        let calendar = Calendar.current
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        let ordered = Array(symbols[first...] + symbols[..<first])
        return HStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: Self.weekdayHeight)
    }

    /// The days, and one gesture across all of them: a click picks a day and
    /// a drag picks the run it crosses, both read off where the pointer is
    /// rather than off a target per cell, so a drag can cross cells.
    private func cells(_ grid: CalendarMonth) -> some View {
        let rows = (grid.leading + grid.cells.count + 6) / 7
        return GeometryReader { geo in
            let column = geo.size.width / 7
            ZStack(alignment: .topLeading) {
                ForEach(Array(grid.cells.enumerated()), id: \.element.id) { index, cell in
                    let slot = grid.leading + index
                    self.cell(cell, width: column)
                        .frame(width: column, height: Self.rowHeight)
                        .offset(
                            x: CGFloat(slot % 7) * column,
                            y: CGFloat(slot / 7) * Self.rowHeight)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard let day = day(at: drag.location, in: grid, column: column) else {
                            return
                        }
                        if var current = run {
                            current.current = day
                            run = current
                        } else if let start = self.day(at: drag.startLocation, in: grid, column: column) {
                            run = Run(anchor: start, current: day)
                        }
                    }
                    .onEnded { _ in
                        defer { run = nil }
                        guard let run, let span = UsageDaySpan(from: run.from, to: run.to) else {
                            return
                        }
                        select(.days(span))
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    pointed = day(at: location, in: grid, column: column, allowsFuture: true)
                case .ended:
                    pointed = nil
                }
            }
        }
        .frame(height: CGFloat(rows) * Self.rowHeight)
    }

    private func day(
        at point: CGPoint, in grid: CalendarMonth, column: CGFloat, allowsFuture: Bool = false
    ) -> Date? {
        guard column > 0, point.x >= 0, point.y >= 0 else { return nil }
        let index = Int(point.y / Self.rowHeight) * 7 + Int(point.x / column) - grid.leading
        guard grid.cells.indices.contains(index), Int(point.x / column) < 7 else { return nil }
        let cell = grid.cells[index]
        return allowsFuture || !cell.isFuture ? cell.day : nil
    }

    private func cell(_ cell: CalendarMonth.Cell, width: CGFloat) -> some View {
        let inRun = run.map { cell.day >= $0.from && cell.day <= $0.to } ?? false
        let inWindow = window?.contains(cell.day) ?? false
        return VStack(spacing: 3) {
            Text(cell.number)
                .font(.system(size: Self.numberSize, weight: cell.isToday ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(cell.isFuture ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .frame(width: Self.ringSize, height: Self.ringSize)
                .overlay {
                    if cell.isToday {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 1)
                    }
                }
            mark(cell, width: width * Self.barWidthRatio)
                .frame(height: Self.barMaxHeight, alignment: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if inRun || inWindow {
                RoundedRectangle(cornerRadius: Self.cellRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(inRun ? Self.runOpacity : Self.bandOpacity))
                    .padding(1)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(cell.isFuture ? cell.title : "\(cell.title) · \(cell.figures)")
        .accessibilityAddTraits(cell.isFuture ? [] : .isButton)
        .accessibilityAction {
            guard !cell.isFuture, let span = UsageDaySpan(from: cell.day, to: cell.day) else {
                return
            }
            select(.days(span))
        }
    }

    /// A bar for a day with a file, a dot for a day without, and nothing for
    /// a day that has not happened, which has no reading to be absent.
    @ViewBuilder
    private func mark(_ cell: CalendarMonth.Cell, width: CGFloat) -> some View {
        if cell.isFuture {
            Color.clear.frame(width: width, height: 0)
        } else if cell.cost == nil {
            Circle()
                .fill(Color(nsColor: .tertiaryLabelColor))
                .frame(width: DayBarGeometry.absentDotSize, height: DayBarGeometry.absentDotSize)
        } else {
            RoundedRectangle(cornerRadius: DayBarGeometry.cornerRadius, style: .continuous)
                .fill(cell.isToday ? Color.accentColor.opacity(DayBarGeometry.todayOpacity) : .accentColor)
                .frame(
                    width: width,
                    height: max(DayBarGeometry.minBarHeight, CGFloat(cell.fraction) * Self.barMaxHeight))
        }
    }
}
