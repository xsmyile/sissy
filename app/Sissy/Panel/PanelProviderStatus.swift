import SwiftUI

/// What the vendor says about itself, on the page about that vendor.
///
/// It sits directly under the identity and above the limits because of the
/// question it answers: when an agent starts failing, the first thing worth
/// knowing is whether it is you or them, and that question is asked before
/// "how much is left". On every other day it is one quiet line.
///
/// The age is on its own clock rather than in the snapshot. The monitor
/// publishes nothing while a vendor keeps answering the same thing — that is
/// what keeps a steady state free — so a frame-derived age would sit at
/// "checked 2m ago" for half an hour under an open panel.
struct PanelProviderStatus: View {
    let provider: String
    let row: UsagePanelSnapshot.StatusRow

    /// Matches the panel header's, for the same reason it is a second rather
    /// than a minute: the tick is what decides how late a change lands, and
    /// the first minute of an age is worded in seconds.
    private static let clockTick: TimeInterval = 1
    private static let dotSize: CGFloat = 7

    var body: some View {
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
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                UsageFormat.statusSummary(
                    provider: provider, label: row.label, checkedAt: row.checkedAt,
                    now: context.date))
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 10)
    }
}
