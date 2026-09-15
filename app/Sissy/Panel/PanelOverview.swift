import SwiftUI

/// The panel's home: what today costs, whether there is room to keep working,
/// and where the money went.
///
/// It answers one question per block and hands the second question — what a
/// single account is doing — to a page of its own.
///
/// The provider block answers whether there is room to keep working, and that
/// is the only thing it answers. It used to carry the day's spend split as
/// well — a stacked bar and a figure per row — and the two axes did not belong
/// on one line: a percentage of a rate-limit window sat in a legend for a bar
/// about money, naming neither the window it measured nor what it had to do
/// with the segment beside it. Pressure is the one reading on this panel that
/// is only actionable *now*; what the day cost is a question asked at the end
/// of it, and the headline, the archive and the export all answer that one.
/// So the row keeps the gauge and hands the money back to them.
///
/// One gauge per provider, never the stack: every window a provider reports,
/// laid out here, was eight lines for two numbers and pushed the projects —
/// which are what the app is for — below the fold. The row shows the window
/// that binds and the page shows the rest.
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

    /// One row per provider, each carrying the window it is closest to running
    /// out of. A row opens that provider's page, which is where its other
    /// windows, its plan, its account, its day and its own projects live.
    private var providers: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: providersLabel)
            ForEach(snapshot.providers) { row in
                Button {
                    openProvider(row.id)
                } label: {
                    providerRow(row)
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

    /// Where a window stops being background and starts being the reason to
    /// stop working. Not a threshold the vendor publishes — a reading, and the
    /// one point on this row worth a colour.
    ///
    /// The colour stays on the reading and not on the projection. Colouring a
    /// row whose rate empties it before the reset was tried and is wrong:
    /// rendered against a real day it lit *both* providers, one of them at
    /// 36% with four hours in hand, because spending above pace at all
    /// projects a run-out eventually and that is the ordinary state of
    /// working. What the pace has to say is already on the row — the bar's own
    /// mark goes red the moment the fill passes it — and it says it without
    /// spending the row's one colour.
    private static let bindingWarningPercent = 90

    /// The row's tooltip for its gauge: the window named, how full it is, and
    /// the pace sentence the page prints under the same bar.
    ///
    /// The row already names the window beside the bar, so this is not what
    /// makes the number legible — it is what saves the click when the answer
    /// is "how long has this got", which is the page's caption verbatim rather
    /// than a second wording of it.
    private static func bindingHelp(_ window: UsagePanelSnapshot.WindowRow) -> String {
        let head = "\(window.label) · \(window.percent)% used"
        guard let caption = UsageFormat.windowCaption(window) else { return head }
        return head + "\n" + caption
    }

    /// A vendor that is not operational says so in its own name, which is the
    /// only thing on this row that can carry it for free.
    ///
    /// Colour rather than a mark, a dot or a glyph: the name is already on the
    /// row and is already its subject, so nothing has to be made room for and
    /// nothing else has to yield for it. The wording is a hover and a click
    /// away, which is where this row already keeps the limits notice's.
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

    /// Room enough for a gauge to be read as one once the label beside it has
    /// taken what it needs.
    private static let gaugeMinWidth: CGFloat = 56
    private static let percentWidth: CGFloat = 32

    /// Floors for the two columns in front of the gauge, so every track starts
    /// at the same x and the bars underneath each other are the same length.
    ///
    /// Without them a name one glyph wider shortens its own track, and two
    /// rows drawn one under the other stop being comparable — 36% of a short
    /// bar is not the width of 36% of a long one, which is the whole reason
    /// they are stacked.
    ///
    /// Floors rather than fixed widths: a provider whose name outgrows the
    /// column pushes its own row out instead of truncating, which is a ragged
    /// edge on one row rather than a name nobody can read.
    private static let nameColumnWidth: CGFloat = 62
    private static let windowColumnWidth: CGFloat = 50

    /// The row carries the *fact* that something needs attention even though
    /// the sentence and the button for it live on the page behind it.
    ///
    /// Without this the split would undo what putting the notice on screen was
    /// for: the grant lapses every time Claude Code refreshes its token, and a
    /// user who never opens that page would be back to gauges that silently
    /// went blank. The mark is the affordance; the row is already a click away
    /// from the wording and the fix.
    ///
    /// The plan badge is not here. It is identity rather than a reading — it
    /// says what the account pays for, not what it has left, and it is the
    /// same word tomorrow. The page leads with it.
    private func providerRow(_ row: UsagePanelSnapshot.ProviderRow) -> some View {
        HStack(spacing: 6) {
            ProviderMark(id: row.id)
            Text(row.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .foregroundStyle(Self.nameTint(row.status))
                .accessibilityLabel(Self.legendHelp(row))
                .frame(minWidth: Self.nameColumnWidth, alignment: .leading)
            if let notice = row.notice {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help(notice.message)
            }
            gauge(row)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
    }

    /// The window that binds, or the reason there is not one yet.
    ///
    /// Named by its period alone, never by the window's full label. A scope is
    /// a vendor display string of no bounded length — "Weekly · Claude Sonnet
    /// 4.5" — and this column has about fifty points: rendered, the label ran
    /// under its own bar, and truncated it read "Weekly · Clau…", which names
    /// no model and still pushed the track out of line with the row above. A
    /// period is a whole word at any width and the same width every time.
    /// Which window of that period it is lives in the tooltip and on the page,
    /// where there is room to say it.
    ///
    /// A provider with no reading gets a dash rather than a bar at zero: an
    /// empty gauge is a measurement, and "Codex has not taken a turn since
    /// launch" is the absence of one. The sentence for it is the same one the
    /// page prints, on the hover.
    @ViewBuilder
    private func gauge(_ row: UsagePanelSnapshot.ProviderRow) -> some View {
        if let binding = UsagePanelSnapshot.binding(row.windows) {
            Text(UsageFormat.windowLabel(minutes: binding.minutes))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: Self.windowColumnWidth, alignment: .leading)
            ShareBar(
                share: binding.fraction,
                tint: ProviderPalette.tint(for: row.id),
                pace: binding.pace
            )
            .frame(minWidth: Self.gaugeMinWidth)
            Text("\(binding.percent)%")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(
                    binding.percent >= Self.bindingWarningPercent ? .orange : .secondary
                )
                .frame(width: Self.percentWidth, alignment: .trailing)
                .help(Self.bindingHelp(binding))
        } else {
            Spacer(minLength: 8)
            Text("—")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(width: Self.percentWidth, alignment: .trailing)
                .help(UsageFormat.noWindowsCaption(row.id))
        }
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
