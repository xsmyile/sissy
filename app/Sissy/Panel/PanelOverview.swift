import SwiftUI

/// One section of the Usage tab below the headline, in the fixed order they
/// draw. `PanelOverview.body` walks `visible(in:)` rather than listing the
/// sections by hand, so this is the one place order and presence are decided
/// — a case added here without a matching `PanelOverview.section` fails to
/// compile.
///
/// The sessions, the Mac and the forge are not here: each is a `PanelTab` of
/// its own. The identity line is here only while repositories have no tab,
/// which is while no forge is connected, and it then sits under the projects
/// it is about.
enum PanelModule: CaseIterable, Hashable {
    case providers
    case projects
    case identities

    /// The modules this snapshot has anything to draw for, in the enum's own
    /// order. `providers` and `projects` both carry a list that can be empty
    /// (no reading has landed yet, every provider is switched off, nothing was
    /// spent today) and an empty section would be a platter with nothing on
    /// it.
    static func visible(in snapshot: UsagePanelSnapshot) -> [Self] {
        allCases.filter { $0.isVisible(in: snapshot) }
    }

    private func isVisible(in snapshot: UsagePanelSnapshot) -> Bool {
        switch self {
        case .providers:
            return snapshot.includesToday ? !snapshot.gaugeRows.isEmpty : !snapshot.spendRows.isEmpty
        case .projects: return !snapshot.projects.isEmpty
        case .identities: return !PanelTab.forge.isVisible(in: snapshot)
        }
    }
}

/// The Usage tab, which is where the panel opens: what today costs, whether
/// there is room to keep working, and where the money went.
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
    let openProvider: (String, String?) -> Void
    let openProjects: () -> Void

    /// Opens the identities page, on the repository named or on the whole
    /// list where none is.
    let openIdentities: (String?) -> Void
    /// Puts the panel's period back on the `Today` preset.
    let resetPeriod: () -> Void
    /// Puts the panel's period on one day, from a bar of the strip.
    let selectDay: (Date) -> Void

    /// The strip's bar under the pointer, which swaps its caption.
    @State private var pointedDay: String?

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.platterGap) {
            headline
            ForEach(PanelModule.visible(in: snapshot), id: \.self) { module in
                section(module)
            }
        }
        .padding(PanelMetrics.platterInset)
    }

    /// One block below the headline, exhaustive over every `PanelModule` so a
    /// case added without a section to match fails to compile.
    @ViewBuilder
    private func section(_ module: PanelModule) -> some View {
        switch module {
        case .providers:
            providers
        case .projects:
            projects
        case .identities:
            PanelIdentityLine(line: snapshot.identityLine, open: openIdentities)
        }
    }

    // MARK: Headline

    /// Cost first, because it is the number the panel is judged by and the one
    /// a user can compare against a bill, with the window it is over and how it
    /// was reached under it.
    ///
    /// Tokens and burn sat inline beside the cost for as long as the number was
    /// always today's; they also never sat well there, since
    /// `firstTextBaseline` between an 18 pt bold rounded number and an 11 pt
    /// caption puts the caption high against the number it qualifies. Stacked,
    /// the meta is as subordinate as it ever was.
    ///
    /// **On a platter, like every block under the tab bar**, decided
    /// 2026-09-28. It stood flat on the popover as the page's heading, which
    /// left the one figure the panel is judged by the only thing on the tab
    /// without depth. **And with no period control beside it.** The period popup sat
    /// on this row until the period became the whole panel's, one control in
    /// the header that Sessions and Forge follow too; the subline names the
    /// window instead, which is what the popup's closed face used to say.
    ///
    /// **A way back to today beside the figure** whenever the period is not
    /// the `Today` preset: the control that set it is an icon in the header,
    /// and a window picked yesterday afternoon is one click from the reading
    /// the panel is opened for rather than two and a menu.
    ///
    /// **A window of more than one day draws its days under the figure**, the
    /// strip a provider's page carries for its week, so a total over thirty
    /// days says which of them it was spent on. A bar is a way into its day.
    private var headline: some View {
        PanelGroup {
            VStack(alignment: .leading, spacing: DayBarGeometry.headerGap) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.cost)
                            .font(
                                .system(
                                    size: PanelMetrics.headlineNumber, weight: .bold,
                                    design: .rounded)
                            )
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(subline)
                            .font(.system(size: PanelMetrics.headlineMeta))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    if snapshot.period != .preset(.today) {
                        todayButton
                    }
                }
                if let strip = snapshot.strip {
                    PanelDayBars(
                        strip: strip, tint: .accentColor, hovered: $pointedDay, select: selectDay)
                }
            }
        }
        .animation(.default, value: snapshot.cost)
    }

    private var todayButton: some View {
        Button(action: resetPeriod) {
            Text(UsageFormat.periodLabel(.today))
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(.quaternary))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Read today")
    }

    /// The window always, tokens always, the pace only on today, how long a
    /// picked window was worked, and how far back the archive reaches only
    /// when it falls short of the window.
    private var subline: String {
        var parts = [UsageFormat.periodHeading(snapshot.period), "\(snapshot.tokens) tokens"]
        if let burn = snapshot.burn { parts.append("\(burn)/h") }
        if let worked = snapshot.worked { parts.append(worked) }
        if let coverage = snapshot.coverage { parts.append(coverage) }
        return parts.joined(separator: " · ")
    }

    // MARK: Providers

    /// One row per provider, each carrying the window it is closest to running
    /// out of. A row opens that provider's page, which is where its other
    /// windows, its plan, its account, its day and its own projects live.
    ///
    /// **Only while the window reaches today.** A gauge is pressure now, and
    /// beside a window of past days it answers a question the window is not
    /// about; there the rows say what each provider spent over those days and
    /// how it was worked instead.
    private var providers: some View {
        PanelGroup {
            SectionLabel(text: providersTitle)
                .lineLimit(1)
                .truncationMode(.tail)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if snapshot.includesToday {
                    ForEach(snapshot.gaugeRows) { row in
                        Button {
                            openProvider(row.provider, row.account)
                        } label: {
                            providerRow(row)
                        }
                        .buttonStyle(.plain)
                        .help(Self.legendHelp(row))
                    }
                } else {
                    ForEach(snapshot.spendRows) { row in
                        spendRow(row)
                    }
                }
            }
        }
    }

    /// One provider's spend over a window of past days. A door to its page
    /// while it still has one, which is while Sissy meters it.
    @ViewBuilder
    private func spendRow(_ row: UsagePanelSnapshot.SpendRow) -> some View {
        let opens = snapshot.providers.contains { $0.id == row.id }
        let label = VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                ProviderMark(id: row.id)
                Text(row.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(row.spend)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if opens { Chevron(isOpen: false) }
            }
            Text(row.work)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(.rect)
        if opens {
            Button {
                openProvider(row.id, nil)
            } label: {
                label
            }
            .buttonStyle(.plain)
            .help("Open \(row.name)")
        } else {
            label
        }
    }

    /// The block's label, with the day's recap folded into it rather than
    /// given a row: "did I use both of them today" is a question about the
    /// list underneath, not a line that stands on its own. Over past days it
    /// names the window instead, which is what the rows are over.
    private var providersTitle: String {
        guard snapshot.includesToday else {
            return "By provider · " + UsageFormat.periodInline(snapshot.period)
        }
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
        let head = "\(window.label) · \(window.readingSentence)"
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
    private static func legendHelp(_ row: UsagePanelSnapshot.GaugeRow) -> String {
        guard let status = row.status, status.indicator.isDegraded else {
            return "Open \(row.name)"
        }
        return UsageFormat.statusSummary(
            provider: row.provider, label: status.label, checkedAt: nil)
    }

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
    ///
    /// **Two lines, and the bar has one to itself.** Everything used to sit on
    /// one, behind floors that were meant to start every track at the same x —
    /// and at 340 pt fixed they could not. Measured 2026-09-16 on an account
    /// with two organisations: the Claude row's name wants 137.5 pt, its column
    /// yielded 85, so the name truncated mid-word *and* took 23 pt off its own
    /// track, which then started at x=216 against Codex's
    /// x=194 and ran 93 pt against its 115. Both halves of the rule the floors
    /// existed for — same start, same length — broke on the same row, and the
    /// percentage went with them: `100%` is 33.8 pt in a 32 pt column, so the
    /// one reading that matters most wrapped to two lines.
    ///
    /// A bar on its own line answers all three without a constant: it starts
    /// at the gutter and runs the full width on every row by construction, the
    /// name has the panel rather than a column, and the reading sits on the
    /// text line where three digits fit. It costs 8 pt a row.
    private func providerRow(_ row: UsagePanelSnapshot.GaugeRow) -> some View {
        let binding = UsagePanelSnapshot.binding(row.windows)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                ProviderMark(id: row.provider)
                Text(row.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(Self.nameTint(row.status))
                    .accessibilityLabel(Self.legendHelp(row))
                if let notice = row.notice {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help(notice.message)
                }
                Spacer(minLength: 8)
                gauge(row, binding: binding)
                Chevron(isOpen: false)
            }
            if let binding {
                ShareBar(
                    share: binding.fraction,
                    tint: ProviderPalette.tint(for: row.provider),
                    pace: binding.pace
                )
            }
        }
        .contentShape(.rect)
    }

    /// Which window the bar underneath is of, and how full it is.
    ///
    /// Named by its period alone, never by the window's full label. A scope is
    /// a vendor display string of no bounded length — "Weekly · Claude Sonnet
    /// 4.5" — and this sits at the end of a line the name already has first
    /// claim on. A period is a whole word at any width and the same width
    /// every time. Which window of that period it is lives in the tooltip and
    /// on the page, where there is room to say it.
    ///
    /// One `Text` rather than two, so the period and the figure cannot be
    /// separated by a line break or a truncation: they are one reading, and
    /// the run carries its own colour where the figure is the part worth one.
    ///
    /// A provider with no reading gets a dash and no bar at all: an empty
    /// gauge is a measurement, and "Codex has not taken a turn since launch"
    /// is the absence of one. The sentence for it is the same one the page
    /// prints, on the hover.
    @ViewBuilder
    private func gauge(
        _ row: UsagePanelSnapshot.GaugeRow, binding: UsagePanelSnapshot.WindowRow?
    ) -> some View {
        if let binding {
            Self.gaugeReading(binding)
                .font(.system(size: 11))
                .lineLimit(1)
                .layoutPriority(1)
                .help(Self.bindingHelp(binding))
        } else {
            Text("—")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .help(UsageFormat.noWindowsCaption(row.provider))
        }
    }

    /// The period and the figure as one `Text`, built by interpolation rather
    /// than concatenation: `Text.+` is deprecated as of macOS 26 and
    /// interpolating a styled `Text` is what replaced it.
    private static func gaugeReading(_ window: UsagePanelSnapshot.WindowRow) -> Text {
        let period = Text(UsageFormat.windowLabel(minutes: window.minutes) + " · ")
            .foregroundStyle(.secondary)
        let figure = Text(window.reading)
            .monospacedDigit()
            .foregroundStyle(readingTint(window))
        return Text("\(period)\(figure)")
    }

    private static func readingTint(_ window: UsagePanelSnapshot.WindowRow) -> AnyShapeStyle {
        window.percent >= bindingWarningPercent
            ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)
    }

    // MARK: Projects

    /// Where the window's money went. The reason the app exists, so it sits
    /// below nothing but the window's own numbers.
    ///
    /// Over the panel's window, presets included, and the label names it. It
    /// read today under every window until the archive carried a split by
    /// repository, which left a week's headline over one day's rows.
    ///
    /// The archive carries the project on its rows only from the day the
    /// dimension landed: the days before it name no repository, and what they
    /// spent is the residue the projects page carries under its rows rather
    /// than a row above real ones.
    ///
    /// **The section's own label is the way to the whole list**, not the
    /// folded row under it. The fold exists only past three repositories, so a
    /// door on it would be a door that comes and goes with the day — and it
    /// is not the last row either, since the remainder sits below it, which
    /// puts a navigation in the middle of a list of readings. The label is
    /// always there, always in the same place, and costs the block no row.
    /// The fold keeps its figures for the reason it has them: the section is
    /// read against the headline, and it only reaches it if every row counts.
    private var projects: some View {
        PanelGroup {
            Button(action: openProjects) {
                ProjectsSectionLabel(
                    text: UsageFormat.projectsSectionLabel(snapshot.period),
                    count: snapshot.projectCount)
            }
            .buttonStyle(.plain)
            .help("Show every project")
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(snapshot.projects) { row in
                    ProjectRowView(
                        row: row, bar: .behind,
                        checkIdentity: row.repository == nil ? nil : { openIdentities(row.id) })
                }
            }
        }
    }

}
