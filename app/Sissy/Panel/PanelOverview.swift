import SwiftUI

/// The panel's home: what today costs, whether there is room to keep working,
/// and where the money went.
///
/// It answers one question per block and hands the second question — what a
/// single account is doing — to a page of its own. The per-provider gauges
/// that used to stack here were eight lines for a split that is two numbers,
/// and they pushed the projects, which are what the app is for, below the fold.
struct PanelOverview: View {
    let snapshot: UsagePanelSnapshot
    let openProvider: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headline

            if let headroom = snapshot.headroom {
                Divider()
                self.headroom(headroom)
            }

            if !snapshot.providers.isEmpty {
                Divider()
                providers
            }

            if !snapshot.projects.isEmpty {
                Divider()
                projects
            }

            if let history = snapshot.history {
                Divider()
                historyRow(history)
            }
        }
    }

    // MARK: Headline

    /// Cost first, because it is the number the day is judged by and the one
    /// a user can compare against a bill. Tokens and burn keep their place on
    /// the same line one step quieter: they say how the cost was reached,
    /// which is a follow-up question rather than the headline.
    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(snapshot.cost)
                    .font(
                        .system(size: PanelMetrics.headlineNumber, weight: .bold, design: .rounded)
                    )
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(subline)
                    .font(.system(size: PanelMetrics.headlineMeta))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 0)
                if let delta = snapshot.delta {
                    DeltaChip(delta: delta)
                }
            }
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .animation(.default, value: snapshot.cost)
    }

    private var subline: String {
        let tokens = "\(snapshot.tokens) tokens"
        return snapshot.burn == FrameBuilder.placeholder
            ? tokens : "\(tokens) · \(snapshot.burn)/h"
    }

    // MARK: Headroom

    /// The one gauge the panel leads on, and the only large number left on it.
    ///
    /// A cost is a fact about the past that a subscription user never sees a
    /// bill for; headroom is the thing that decides whether to keep working in
    /// the next hour, and it reads the same for everyone. It names its
    /// provider because it can be either of them.
    private func headroom(_ row: UsagePanelSnapshot.HeadroomRow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Self.headroomPercent(row.window))%")
                    .font(
                        .system(size: PanelMetrics.headlineNumber, weight: .bold, design: .rounded)
                    )
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("headroom")
                    .font(.system(size: PanelMetrics.headlineMeta))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(
                    "\(row.providerName) · \(row.window.label) · "
                        + UsageFormat.resetLabel(row.window.resetsAt)
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            ShareBar(
                share: row.window.fraction,
                tint: ProviderPalette.tint(for: row.providerID),
                pace: row.window.pace
            )

            if let pace = row.window.pace {
                Text(
                    UsageFormat.paceCaption(
                        deltaPercent: pace.deltaPercent, runsOutAt: pace.runsOutAt)
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 9)
        .animation(.default, value: row.window.percent)
    }

    /// What is left of the window, as a whole percentage.
    ///
    /// The block deliberately does not reuse `WindowRowView`, which prints the
    /// share *spent*: "33% headroom" set directly above a bar labelled "67%"
    /// is the same window reported twice in opposite directions, and the two
    /// numbers read as a contradiction at a glance. One reading per block.
    /// A window a vendor reports past full has no headroom rather than a
    /// negative amount of it.
    static func headroomPercent(_ window: UsagePanelSnapshot.WindowRow) -> Int {
        max(0, 100 - window.percent)
    }

    // MARK: Providers

    /// The day's split, as one bar and a legend. A row opens that provider's
    /// page, which is where its gauges, its account and its own projects live.
    private var providers: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "By provider")
            StackedShareBar(rows: snapshot.providers)
            ForEach(snapshot.providers) { row in
                Button {
                    openProvider(row.id)
                } label: {
                    legendRow(row)
                }
                .buttonStyle(.plain)
                .help("Open \(row.name)")
            }
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 12)
    }

    /// A legend row carries the *fact* that something needs attention even
    /// though the sentence and the button for it live on the page behind it.
    ///
    /// Without this the split would undo what putting the notice on screen
    /// was for: the grant lapses every time Claude Code refreshes its token,
    /// and a user who never opens that page would be back to gauges that
    /// silently went blank. The mark is the affordance; the row is already a
    /// click away from the wording and the fix.
    private func legendRow(_ row: UsagePanelSnapshot.ProviderRow) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ProviderPalette.tint(for: row.id))
                .frame(width: 7, height: 7)
            Text(row.name)
                .font(.system(size: 12, weight: .medium))
            if let plan = row.plan {
                PlanBadge(plan: plan, tier: row.planTier)
            }
            if let notice = row.notice {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help(notice.message)
            }
            Spacer(minLength: 0)
            Text("\(row.tokens) · \(row.cost)")
                .font(.system(size: 12))
                .monospacedDigit()
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
    }

    // MARK: Projects

    /// Where the day's money went. The reason the app exists, so it sits
    /// above the archive line and below nothing but the day's own numbers.
    private var projects: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "By project")
            ForEach(snapshot.projects) { row in
                ProjectRowView(row: row)
            }
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 12)
    }

    // MARK: History

    /// One line, under the day's own numbers, for what came before it. It is
    /// deliberately the quietest thing in the panel: the archive answers a
    /// question asked at the end of a month, not one asked while working.
    private func historyRow(_ row: UsagePanelSnapshot.HistoryRow) -> some View {
        HStack(spacing: 6) {
            Text(row.label)
                .font(.system(size: 12))
            Spacer(minLength: 0)
            Text("\(row.tokens) · \(row.cost)")
                .font(.system(size: 12))
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 10)
    }
}

/// The day split across providers in one bar, which is the whole of what the
/// per-provider share bars used to say between them — and says it in one line
/// instead of one each, where the widths are actually comparable.
struct StackedShareBar: View {
    let rows: [UsagePanelSnapshot.ProviderRow]

    private static let gap: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            let gaps = CGFloat(max(rows.count - 1, 0)) * Self.gap
            let usable = max(geometry.size.width - gaps, 0)
            HStack(spacing: Self.gap) {
                ForEach(rows) { row in
                    Capsule()
                        .fill(ProviderPalette.tint(for: row.id).gradient)
                        .frame(width: max(usable * row.share, row.share > 0 ? 3 : 0))
                }
                Spacer(minLength: 0)
            }
            .background(Capsule().fill(.quaternary))
        }
        .frame(height: PanelMetrics.barHeight)
        .animation(.default, value: rows.map(\.share))
    }
}

/// Today against yesterday. Yesterday is a full day and today is a day so far,
/// which is the only granularity the engine keeps — the chip says "vs
/// yesterday" rather than claiming a like-for-like.
struct DeltaChip: View {
    let delta: UsagePanelSnapshot.TokenDelta

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
            Text("\(delta.percent)%")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
            Text("vs yesterday")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(tint)
    }

    private var symbol: String {
        switch delta.direction {
        case .up: return "arrow.up.right"
        case .down: return "arrow.down.right"
        case .flat: return "equal"
        }
    }

    private var tint: Color {
        switch delta.direction {
        case .up: return .green
        case .down: return .red
        case .flat: return .secondary
        }
    }
}
