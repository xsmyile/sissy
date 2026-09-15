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
    /// How many CLIs Sissy has a reader for, which is the denominator of the
    /// providers block's recap. It is not on the snapshot because the frame
    /// does not carry it: a provider that spent nothing today has no slice,
    /// and that is exactly the provider the recap is about.
    let meteringProviders: Int
    let openProvider: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headline

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
            }
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .animation(.default, value: snapshot.cost)
    }

    private var subline: String {
        let tokens = "\(snapshot.tokens) tokens"
        guard let burn = snapshot.burn else { return tokens }
        return "\(tokens) · \(burn)/h"
    }

    // MARK: Providers

    /// The day's split, as one bar and a legend. A row opens that provider's
    /// page, which is where its gauges, its account and its own projects live.
    private var providers: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: providersLabel)
            StackedShareBar(rows: snapshot.providers)
            ForEach(snapshot.providers) { row in
                Button {
                    openProvider(row.id)
                } label: {
                    legendRow(row)
                }
                .buttonStyle(.plain)
                .help(Self.legendHelp(row))
            }
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 12)
    }

    /// The block's label, with the day's recap folded into it rather than
    /// given a row: "did I use both of them today" is a question about the
    /// list underneath, not a line that stands on its own.
    private var providersLabel: String {
        guard
            let recap = UsageFormat.providersRecap(
                used: snapshot.usedToday, metering: meteringProviders)
        else { return "By provider" }
        return "By provider · " + recap
    }

    /// A legend row carries the *fact* that something needs attention even
    /// though the sentence and the button for it live on the page behind it.
    ///
    /// Without this the split would undo what putting the notice on screen
    /// was for: the grant lapses every time Claude Code refreshes its token,
    /// and a user who never opens that page would be back to gauges that
    /// silently went blank. The mark is the affordance; the row is already a
    /// click away from the wording and the fix.
    /// Where a window stops being background and starts being the reason to
    /// stop working. Not a threshold the vendor publishes — a reading, and the
    /// one point on this row worth a colour.
    private static let bindingWarningPercent = 90

    /// Whether the window this provider leads on is a reason to stop working.
    ///
    /// The percentage alone stopped answering that when `binding` moved onto
    /// the pace: the window that binds is now the one the current rate empties
    /// before its own reset, and that can be a bar at 10% nine minutes into a
    /// session — imminent, and nowhere near the threshold. A projected run-out
    /// *is* the warning, so it carries the colour; the threshold stays for the
    /// windows that project nothing, where a nearly full bar is all there is
    /// to go on.
    private static func isUnderPressure(_ window: UsagePanelSnapshot.WindowRow) -> Bool {
        window.pace?.runsOutAt != nil || window.percent >= bindingWarningPercent
    }

    /// The legend prints one number for a whole provider and never names the
    /// window it came from. That was legible while the number was the highest
    /// of them; now that the pace picks the window, a low percentage in orange
    /// is unreadable without the sentence behind it, so the tooltip carries
    /// the page's own caption and the two surfaces answer alike.
    private static func bindingHelp(_ window: UsagePanelSnapshot.WindowRow) -> String {
        let head = "\(window.label) · \(window.percent)% used"
        guard let caption = UsageFormat.windowCaption(window) else { return head }
        return head + "\n" + caption
    }

    /// A vendor that is not operational says so in its own name, which is the
    /// only thing on this row that can carry it for free.
    ///
    /// Measured at the real fonts: the row is 312 pt wide and "Claude · Team
    /// Premium · 100% · $1,234.56" already fills 306.4 of them, so a mark, a
    /// dot or a glyph added here would push the plan badge — which yields
    /// first by design — off a row that has nothing left to give. Colour costs
    /// nothing, and the wording is a hover and a click away, which is where
    /// this row already keeps the limits notice's.
    ///
    /// Only a degraded vendor colours. `unknown` does not: that is Sissy
    /// having no reading, which is not news about the vendor, and the page
    /// says so in words.
    private static func nameTint(_ status: UsagePanelSnapshot.StatusRow?) -> Color {
        guard let status, status.indicator.isDegraded else { return .primary }
        return ProviderPalette.statusTint(status.indicator)
    }

    /// What the row hovers: the vendor's own sentence when there is one worth
    /// reading, and what the click does otherwise.
    ///
    /// Deliberately without the age the page carries. The Overview keeps no
    /// clock of its own, so an age worded here would be as old as the last
    /// frame rather than as old as the reading.
    private static func legendHelp(_ row: UsagePanelSnapshot.ProviderRow) -> String {
        guard let status = row.status, status.indicator.isDegraded else {
            return "Open \(row.name)"
        }
        return UsageFormat.statusSummary(
            provider: row.id, label: status.label, checkedAt: nil)
    }

    private func legendRow(_ row: UsagePanelSnapshot.ProviderRow) -> some View {
        HStack(spacing: 6) {
            ProviderMark(id: row.id)
            Text(row.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(Self.nameTint(row.status))
                .accessibilityLabel(Self.legendHelp(row))
            if let plan = row.plan {
                PlanBadge(plan: plan, tier: row.planTier)
                    .layoutPriority(-1)
            }
            if let notice = row.notice {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help(notice.message)
            }
            Spacer(minLength: 0)
            if let binding = UsagePanelSnapshot.binding(row.windows) {
                Text("\(binding.percent)%")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Self.isUnderPressure(binding) ? .orange : .secondary)
                    .fixedSize()
                    .help(Self.bindingHelp(binding))
            }
            Text("\(row.tokens) · \(row.cost)")
                .font(.system(size: 12))
                .monospacedDigit()
                .fixedSize()
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
