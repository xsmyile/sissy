import SwiftUI

/// At what effort one provider's week was worked, a bar per model.
///
/// One level in from the provider page's `By effort` row, which is the only
/// door to it. A page rather than the block it was because the reading answers
/// how a period was worked, which is asked at the end of one, and the provider
/// page is about what the account is doing now.
///
/// **Drawn rather than printed.** The block was a run of words in secondary
/// text between a bar strip and a list with washes behind it; here each model
/// gets a bar split by effort, dearest first, in the provider's tint, with the
/// run as its legend. Every bar is the full width, because each is 100% of its
/// own model — the rule `makeEffort` holds for the shares — and bars of
/// different lengths would invite a comparison of money the page does not
/// make. What each model spent is written beside its name instead.
struct PanelEffortPage: View {
    let provider: String
    /// Today's `(model, effort)` pairs off the frame, which the window adds to
    /// the archived days for the strip's reason.
    let today: [EffortSplit]
    /// This provider's archived days, read once when the page opens, for the
    /// reason `PanelProviderPage.loadHistory` gives.
    let loadHistory: (String) async -> [UsageHistoryDaySummary]

    @State private var series: [UsageHistoryDaySummary] = []

    private static let barHeight: CGFloat = 10
    private static let barRadius: CGFloat = 3
    private static let segmentGap: CGFloat = 1
    private static let swatchSize: CGFloat = 8
    /// The tint's strength per rank, dearest first. Rank rather than the
    /// effort's own name, because the two vendors' ladders do not map onto one
    /// another and a fixed colour per word would claim they do.
    private static let rankOpacity: [Double] = [1, 0.7, 0.45, 0.28]
    private static let unattributedOpacity = 0.18

    private var tint: Color { ProviderPalette.tint(for: provider) }

    var body: some View {
        let window = UsagePanelSnapshot.effortWindow(series: series, today: today)
        let rows = UsagePanelSnapshot.makeEffort(window.splits, provider: provider)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                SectionLabel(text: "By effort")
                Spacer(minLength: 8)
                Text(
                    UsageFormat.effortWindow(
                        covered: window.covered, of: UsagePanelSnapshot.dayStripDays)
                )
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, PanelMetrics.gutter)
            .padding(.top, 12)
            .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(rows) { row in
                    model(row)
                }
            }
            .padding(.horizontal, PanelMetrics.gutter)
            .padding(.vertical, 8)
            .padding(.bottom, 4)
        }
        .task(id: provider) {
            series = await loadHistory(provider)
        }
    }

    private func model(_ row: UsagePanelSnapshot.EffortRow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(row.total)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            bar(row.segments)
            legend(row.segments)
        }
        .contentShape(.rect)
        .help(row.detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name) · \(row.detail)")
    }

    private func bar(_ segments: [UsagePanelSnapshot.EffortSegment]) -> some View {
        GeometryReader { geometry in
            let gaps = Self.segmentGap * CGFloat(max(segments.count - 1, 0))
            let width = max(geometry.size.width - gaps, 0)
            HStack(spacing: Self.segmentGap) {
                ForEach(Array(segments.enumerated()), id: \.element.id) { rank, segment in
                    Rectangle()
                        .fill(color(segment, rank: rank))
                        .frame(width: width * segment.share)
                }
            }
        }
        .frame(height: Self.barHeight)
        .clipShape(.rect(cornerRadius: Self.barRadius))
    }

    /// On one line while it fits and on two when it does not: four Codex
    /// efforts with a swatch each come to about the 312 pt a page has, and a
    /// clause clipped off the end would drop the effort the bar still draws.
    private func legend(_ segments: [UsagePanelSnapshot.EffortSegment]) -> some View {
        let ranked = Array(segments.enumerated())
        let half = (ranked.count + 1) / 2
        return ViewThatFits(in: .horizontal) {
            legendLine(ranked)
            VStack(alignment: .leading, spacing: 3) {
                legendLine(Array(ranked.prefix(half)))
                legendLine(Array(ranked.dropFirst(half)))
            }
        }
    }

    private func legendLine(
        _ ranked: [(offset: Int, element: UsagePanelSnapshot.EffortSegment)]
    ) -> some View {
        HStack(spacing: 10) {
            ForEach(ranked, id: \.element.id) { rank, segment in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(segment, rank: rank))
                        .frame(width: Self.swatchSize, height: Self.swatchSize)
                    Text(segment.label)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
    }

    private func color(_ segment: UsagePanelSnapshot.EffortSegment, rank: Int) -> Color {
        guard segment.effort != nil else { return Color.secondary.opacity(Self.unattributedOpacity) }
        let opacity = Self.rankOpacity[min(rank, Self.rankOpacity.count - 1)]
        return tint.opacity(opacity)
    }
}
