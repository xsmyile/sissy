import SwiftUI

/// What the vendor says about itself, on the page about that vendor: one line,
/// and the way to the services behind it.
///
/// **The services open as a page of the panel, not as a surface of their own.**
/// They used to expand in place, which made this the one block on the page
/// whose height a click changed — the reason it sits at the foot, where there
/// is nothing left below it to push. The answer to that was a nested
/// `.popover` for one release, and it was the wrong one twice over. Apple's own
/// guidance forbids it outright — *"Never show a cascade or hierarchy of
/// popovers, in which one emerges from another"* (Human Interface Guidelines,
/// Popovers) — and the reason is measurable: dismissing a popover presented
/// from inside the panel leaves the panel's own window with its new size
/// committed to the window server and its **new origin not**, for ~555 ms.
/// Cocoa origins sit bottom-left, so for that half second the panel kept its
/// bottom edge and moved its top, drawing itself displaced by exactly the
/// height difference between the two pages — measured 2026-09-17 on macOS 27,
/// on a harness reproducing `UsagePanelController`, and `NSWindow.frame` was
/// correct throughout, so nothing in this app's layout could see it or fix it.
/// Every remedy measured failed — the animation, the backing store, held
/// screen updates, a forced redraw, a nudged origin, a reset positioning rect,
/// and a resize deferred by up to half a second — because the freeze ends when
/// it ends. A page needs none of them: it is a resize of the panel, and the
/// panel resizes cleanly when nothing was dismissed to reach it.
///
/// A page also answers the original complaint better than the card did: the
/// height of what is underneath cannot change, because there is nothing
/// underneath — the services *are* the page.
///
/// It stays at the foot all the same. The reason is the question rather than
/// the height: what the vendor says about itself is the least-asked reading on
/// this page, and a degraded vendor has already coloured its own name on the
/// Overview and put the sentence in that row's tooltip, so "is it me or them"
/// is answered before this page is open. On every other day it is one quiet
/// line.
///
/// The age is on its own clock rather than in the snapshot. The monitor
/// publishes nothing while a vendor keeps answering the same thing — that is
/// what keeps a steady state free — so a frame-derived age would sit at
/// "checked 2m ago" for half an hour under an open panel.
struct PanelProviderStatus: View {
    let provider: String
    let row: UsagePanelSnapshot.StatusRow
    let openServices: () -> Void

    private var hasTree: Bool { !row.components.isEmpty }

    var body: some View {
        Group {
            if hasTree {
                Button(action: openServices) {
                    StatusLine(provider: provider, row: row, navigates: true)
                }
                .buttonStyle(.plain)
                .help("Show the services")
            } else {
                StatusLine(provider: provider, row: row, navigates: false)
            }
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 10)
    }
}

/// The vendor's services, on a page of their own.
///
/// The tree is a copy of the vendor's page, not a second opinion on it: the
/// rows, their order, their nesting and their wording are all the vendor's
/// own. What it deliberately does not carry is incident history, which is the
/// one thing the link at the bottom is for.
///
/// It leads with the same line that was clicked to get here, because that line
/// is the summary the tree details — and because a page whose header names the
/// vendor still has to say which reading it is about.
///
/// **The tree keeps no ceiling of its own.** It had one while it was a card:
/// OpenAI publishes 34 services, and a block that long expanded in place was
/// one click away from several times the height of everything above it. On a
/// page there is nothing above it and nothing below, so the bound that applies
/// is the panel's own — `PanelMetrics.maxHeight` against the screen it opened
/// on, which is what replaced every per-section ceiling in the first place.
struct PanelProviderStatusPage: View {
    let provider: String
    let row: UsagePanelSnapshot.StatusRow

    /// Which groups are open. Local to the page, so leaving it and coming back
    /// asks the question again rather than answering the one before last.
    @State private var expanded: Set<String> = []

    /// What every other section on the panel puts between its label and its
    /// rows, so this one cannot read tighter than the block above it.
    private static let labelSpacing: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusLine(provider: provider, row: row, navigates: false)
                .padding(.horizontal, PanelMetrics.gutter)
                .padding(.vertical, 10)

            Divider()

            VStack(alignment: .leading, spacing: Self.labelSpacing) {
                SectionLabel(text: "Services")
                VStack(alignment: .leading, spacing: StatusTreeGeometry.rowSpacing) {
                    tree
                    pageLink
                }
            }
            .padding(.horizontal, PanelMetrics.gutter)
            .padding(.vertical, 12)
        }
    }

    // MARK: The tree

    private var tree: some View {
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
            .padding(.leading, indented ? StatusTreeGeometry.childIndent : 0)
    }

    private func componentLine(_ component: UsagePanelSnapshot.ComponentRow, chevron: Chevron?)
        -> some View
    {
        HStack(spacing: 6) {
            Circle()
                .fill(ProviderPalette.statusTint(component.indicator))
                .frame(width: StatusTreeGeometry.dotSize, height: StatusTreeGeometry.dotSize)
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

/// The vendor's sentence and how old it is, in the one wording both the line
/// on the provider page and the head of the services page use.
///
/// `navigates` is the chevron alone: the line is the same reading either way,
/// and only the one that is a control says so.
private struct StatusLine: View {
    let provider: String
    let row: UsagePanelSnapshot.StatusRow
    let navigates: Bool

    /// Matches the panel header's, for the same reason it is a second rather
    /// than a minute: the tick is what decides how late a change lands, and
    /// the first minute of an age is worded in seconds.
    private static let clockTick: TimeInterval = 1

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.clockTick)) { context in
            HStack(spacing: 8) {
                Circle()
                    .fill(ProviderPalette.statusTint(row.indicator))
                    .frame(
                        width: StatusTreeGeometry.dotSize, height: StatusTreeGeometry.dotSize)

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

                if navigates {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
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

/// The measures the status rows are drawn at.
///
/// Every row is one fixed height, which is what let the tree's old bound be
/// arithmetic over a count rather than a measurement of a laid-out view. The
/// bound is gone with the card that needed it — the panel's own ceiling is
/// what holds a long tree now — and what is left is the geometry itself.
enum StatusTreeGeometry {
    static let rowHeight: CGFloat = 18
    static let rowSpacing: CGFloat = 6
    static let dotSize: CGFloat = 7
    static let childIndent: CGFloat = 15
}
