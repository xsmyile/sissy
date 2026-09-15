import SwiftUI

/// What the vendor says about itself, on the page about that vendor.
///
/// It sits directly under the identity and above the limits because of the
/// question it answers: when an agent starts failing, the first thing worth
/// knowing is whether it is you or them, and that question comes before "how
/// much is left". On every other day it is one quiet line.
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

    /// Which groups are open. Local to the view, and gone when the panel
    /// closes: `UsagePanelController` drops the host on close, and a tree that
    /// reopened three levels deep on a day nothing is wrong would be answering
    /// a question from last week.
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
        VStack(alignment: .leading, spacing: StatusTreeGeometry.rowSpacing) {
            header
            if showingComponents && hasTree {
                tree
                pageLink
            }
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 10)
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
    static let rowSpacing: CGFloat = 6
    /// Past this the tree scrolls inside itself rather than growing the page.
    ///
    /// The panel gained a scroll view of its own, so this is no longer what
    /// keeps the popover on the screen. It survives for the reason that always
    /// sat underneath that one: OpenAI publishes 34 services, and a tree
    /// allowed to run to its full length puts everything below it — the
    /// limits, the day, the projects — past the bottom of a panel the user
    /// then has to scroll through to reach what they opened it for.
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
