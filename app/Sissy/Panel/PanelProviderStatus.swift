import SwiftUI

/// What the vendor says about itself, on the page about that vendor.
///
/// **The tree opens in a card of its own, not underneath the line.** It used to
/// expand in place, which made this the one block on the page whose height a
/// click changed — the reason it was moved to the foot, where there is nothing
/// left below it to push. A card takes even that away: the page is the same
/// height open or shut, and the tree is bounded by its own window instead of by
/// what the page can spare. The gesture is the one the project rows use, and
/// what makes it safe is the same measurement: on macOS 27 a nested `.popover`
/// does not dismiss the transient panel, its wheel scrolls, and a click outside
/// closes both together.
///
/// It stays at the foot all the same. The reason is no longer the height, it is
/// the question: what the vendor says about itself is the least-asked reading
/// on this page, and a degraded vendor has already coloured its own name on the
/// Overview and put the sentence in that row's tooltip, so "is it me or them"
/// is answered before this page is open. On every other day it is one quiet
/// line.
///
/// The age is on its own clock rather than in the snapshot. The monitor
/// publishes nothing while a vendor keeps answering the same thing — that is
/// what keeps a steady state free — so a frame-derived age would sit at
/// "checked 2m ago" for half an hour under an open panel.
///
/// The tree underneath is a copy of the vendor's page, not a second opinion on
/// it: the rows, their order, their nesting and their wording are all the
/// vendor's own. What it deliberately does not carry is incident history,
/// which is the one thing the link at the bottom is for.
struct PanelProviderStatus: View {
    let provider: String
    let row: UsagePanelSnapshot.StatusRow

    /// Which groups are open. Local to the view, and emptied when the card
    /// shuts rather than when the panel does: a card is opened to ask a
    /// question and dismissed once it is answered, so one reopened three
    /// levels deep is answering the question before last. The panel dropping
    /// its host clears it too, one level up, but that is the backstop and no
    /// longer the rule.
    @State private var expanded: Set<String> = []
    @State private var showingComponents = false

    /// Matches the panel header's, for the same reason it is a second rather
    /// than a minute: the tick is what decides how late a change lands, and
    /// the first minute of an age is worded in seconds.
    private static let clockTick: TimeInterval = 1
    private static let dotSize: CGFloat = 7
    private static let childIndent: CGFloat = 15

    private var hasTree: Bool { !row.components.isEmpty }

    var body: some View {
        header
            .padding(.horizontal, PanelMetrics.gutter)
            .padding(.vertical, 10)
            .popover(isPresented: $showingComponents, arrowEdge: .trailing) {
                if hasTree { card }
            }
            .onChange(of: showingComponents) { _, isOpen in
                if !isOpen { expanded.removeAll() }
            }
    }

    /// The vendor's services, in a window of their own.
    ///
    /// As wide as the page it came off rather than wider: measured against
    /// OpenAI's own names, the longest of them fits the page's measure today,
    /// so width is not what this buys — the page holding still is.
    private var card: some View {
        VStack(alignment: .leading, spacing: StatusTreeGeometry.rowSpacing) {
            tree
            pageLink
        }
        .padding(StatusTreeGeometry.cardPadding)
        .frame(width: StatusTreeGeometry.cardWidth, alignment: .leading)
    }

    // MARK: The line

    /// The whole row is the control when there is a tree behind it, and plain
    /// text when there is not: a chevron that opens nothing is worse than no
    /// chevron, and a feed whose component list could not be read has nothing
    /// to open.
    @ViewBuilder
    private var header: some View {
        if hasTree {
            Button {
                showingComponents.toggle()
            } label: {
                line
            }
            .buttonStyle(.plain)
            .help(showingComponents ? "Hide the services" : "Show the services")
        } else {
            line
        }
    }

    private var line: some View {
        TimelineView(.periodic(from: .now, by: Self.clockTick)) { context in
            HStack(spacing: 8) {
                Circle()
                    .fill(ProviderPalette.statusTint(row.indicator))
                    .frame(width: Self.dotSize, height: Self.dotSize)

                Text(row.label)
                    .font(.system(size: PanelMetrics.rowText))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let checkedAt = row.checkedAt {
                    Text("·")
                        .font(.system(size: PanelMetrics.headlineMeta))
                        .foregroundStyle(.secondary)
                    Text(UsageFormat.statusAge(checkedAt: checkedAt, now: context.date))
                        .font(.system(size: PanelMetrics.headlineMeta))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                        .fixedSize()
                }

                Spacer(minLength: 0)

                if hasTree {
                    Chevron(isOpen: showingComponents)
                }
            }
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                UsageFormat.statusSummary(
                    provider: provider, label: row.label, checkedAt: row.checkedAt,
                    now: context.date))
        }
    }

    // MARK: The tree

    /// Bounded, and scrolling only once it has to be.
    ///
    /// Measured 2026-09-15: OpenAI publishes 34 services in 5 groups, so one
    /// group left open is already taller than the rest of the page. Every row
    /// is drawn at one fixed height, which is what lets the bound be arithmetic
    /// over a count rather than a measurement of a laid-out view.
    ///
    /// It carries no scroll indicator, which leaves the clipped row as the one
    /// thing that says there is more below: the bound falls 8 pt into a ninth
    /// row rather than on a row boundary, and `ProviderStatusTests` is what
    /// holds it there. An overlay scroller would otherwise draw over the
    /// status words on the right for as long as it is up. `.never` rather
    /// than `.hidden` — measured on macOS 27, `.hidden` leaves the scroller
    /// installed on the backing `NSScrollView` where `.never` removes it.
    private var tree: some View {
        let rows = StatusTreeGeometry.visibleRows(row.components, expanded: expanded)
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: StatusTreeGeometry.rowSpacing) {
                ForEach(row.components) { component in
                    if component.isGroup {
                        group(component)
                    } else {
                        leaf(component)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: StatusTreeGeometry.height(rows: rows))
        .scrollDisabled(!StatusTreeGeometry.scrolls(rows: rows))
        .scrollIndicators(.never)
    }

    private func group(_ component: UsagePanelSnapshot.ComponentRow) -> some View {
        let isOpen = expanded.contains(component.id)
        return VStack(alignment: .leading, spacing: StatusTreeGeometry.rowSpacing) {
            Button {
                if isOpen {
                    expanded.remove(component.id)
                } else {
                    expanded.insert(component.id)
                }
            } label: {
                componentLine(component, chevron: Chevron(isOpen: isOpen))
            }
            .buttonStyle(.plain)

            if isOpen {
                ForEach(component.children) { child in
                    leaf(child, indented: true)
                }
            }
        }
    }

    private func leaf(_ component: UsagePanelSnapshot.ComponentRow, indented: Bool = false)
        -> some View
    {
        componentLine(component, chevron: nil)
            .padding(.leading, indented ? Self.childIndent : 0)
    }

    private func componentLine(_ component: UsagePanelSnapshot.ComponentRow, chevron: Chevron?)
        -> some View
    {
        HStack(spacing: 6) {
            Circle()
                .fill(ProviderPalette.statusTint(component.indicator))
                .frame(width: Self.dotSize, height: Self.dotSize)
            Text(component.name)
                .font(.system(size: PanelMetrics.headlineMeta))
                .lineLimit(1)
                .truncationMode(.tail)
            if let chevron {
                chevron
            }
            Spacer(minLength: 8)
            Text(component.status)
                .font(.system(size: PanelMetrics.headlineMeta))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(height: StatusTreeGeometry.rowHeight)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(component.name) · \(component.status)")
    }

    /// The way to the page itself, for what a copy of it cannot answer: what
    /// happened, when it started, and what the vendor has said since.
    @ViewBuilder
    private var pageLink: some View {
        if let page = row.page, let host = page.host() {
            Link(destination: page) {
                HStack(spacing: 4) {
                    Text(host)
                    Image(systemName: "arrow.up.forward")
                }
                .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open \(host) for the incident history")
        }
    }
}

/// The one chevron this surface uses, so a group and the row above it cannot
/// point different ways at the same state.
private struct Chevron: View {
    let isOpen: Bool

    var body: some View {
        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}

/// How tall the tree is allowed to get, and how tall it actually is.
///
/// Arithmetic over a row count rather than a measurement, which is what every
/// row being drawn at `rowHeight` buys: the bound can be asserted without
/// rendering anything, the way the bar's geometry already is.
enum StatusTreeGeometry {
    static let rowHeight: CGFloat = 18
    static let cardPadding: CGFloat = 12
    /// Sized so the rows inside the card keep exactly the measure they had on
    /// the page: the page's own gutters come off, the card's padding goes back
    /// on. `StatusTreeCardTests` is what holds the two in step, because the
    /// point of the card is that nothing about the tree reads differently in
    /// it.
    static let cardWidth: CGFloat =
        PanelMetrics.width - 2 * PanelMetrics.gutter + 2 * cardPadding
    static let rowSpacing: CGFloat = 6
    /// Past this the tree scrolls inside itself rather than growing the page.
    ///
    /// The panel gained a scroll view of its own, so this is no longer what
    /// keeps the popover on the screen, and the block sits last on the page so
    /// there is nothing below it left to push. What survives is the page
    /// itself: OpenAI publishes 34 services, so a tree allowed to run to its
    /// full length is one click away from several times the height of
    /// everything above it put together.
    static let maxHeight: CGFloat = 200

    static func height(rows: Int) -> CGFloat {
        guard rows > 0 else { return 0 }
        let full = CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowSpacing
        return min(full, maxHeight)
    }

    static func scrolls(rows: Int) -> Bool {
        height(rows: rows) >= maxHeight
    }

    /// How many rows are on screen: every top-level row, plus the children of
    /// the groups that are open.
    static func visibleRows(
        _ components: [UsagePanelSnapshot.ComponentRow], expanded: Set<String>
    ) -> Int {
        components.reduce(0) { total, component in
            total + 1 + (expanded.contains(component.id) ? component.children.count : 0)
        }
    }
}
