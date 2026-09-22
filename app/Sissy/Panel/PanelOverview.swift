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
    let openProvider: (String, String?) -> Void
    let openProjects: () -> Void

    /// Opens the identities page, on the repository named or on the whole
    /// list where none is.
    let openIdentities: (String?) -> Void
    let selectPeriod: (UsagePeriod) -> Void
    /// Which forge connections are being re-read, so their rows can say so
    /// where they otherwise print an age about to change.
    let refreshingForge: Set<String>
    let refreshForge: (String) -> Void
    /// Opens the stats page. The providers label it hangs off is the only way
    /// there, so that label is drawn on every frame, rows or none.
    let openStats: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headline

            Divider()
            providers

            if !snapshot.projects.isEmpty {
                Divider()
                projects
            }

            Divider()
            identityLine(snapshot.identityLine)

            if !snapshot.forge.isEmpty {
                Divider()
                forge
            }
        }
    }

    // MARK: Identities

    /// The door to the identities page, drawn on every frame.
    ///
    /// **Always there, and quiet unless something is wrong.** It was drawn
    /// only while a repository disagreed with its forge, which left the page
    /// behind a right-click on a project row on every other day — so the
    /// check went unnoticed until it had something to say, and a user who had
    /// never seen the line had no reason to trust its absence. It now keeps
    /// the agents door's rule: a door that comes and goes is not one. What
    /// stays true of the old design is the weight. With no finding
    /// the line is secondary, a tick and a count; a finding turns it primary
    /// with the warning mark and names the repository whenever there is only
    /// one, because naming it is the whole of the remaining work.
    ///
    /// **Under the projects, above the forge.** It is about repositories, so it
    /// sits after the list of them rather than inside it — a badge per project
    /// row is the decorative signal on the cost axis this panel refuses, since
    /// that list is ordered by spend — and it answers for every repository
    /// Sissy knows whether or not a forge is connected, which is why it is not
    /// part of the forge section.
    private func identityLine(_ line: UsagePanelSnapshot.IdentityLine) -> some View {
        Button {
            openIdentities(line.repository)
        } label: {
            HStack(spacing: 6) {
                identityMark(line.state)
                Text(line.summary)
                    .font(.system(size: PanelMetrics.rowText))
                    .foregroundStyle(line.state == .findings ? .primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Show every repository's commit identity")
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 10)
    }

    /// The page's own marks, so the line and the rows it leads to read alike.
    /// Nothing read carries no mark: a tick there would be a verdict.
    @ViewBuilder
    private func identityMark(_ state: UsagePanelSnapshot.IdentityLineState) -> some View {
        switch state {
        case .findings:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        case .clean:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        case .unread:
            EmptyView()
        }
    }

    // MARK: Headline

    /// Cost first, because it is the number the panel is judged by and the one
    /// a user can compare against a bill, with the window it is over beside it
    /// and how it was reached under it.
    ///
    /// Tokens and burn sat inline beside the cost for as long as the number was
    /// always today's. Two things changed with the period. Inline, the cost and
    /// its meta take about two thirds of the 340 pt and leave the control a
    /// cramped remainder — and the meta *grows* with the window, since a period
    /// the archive falls short of has to say so, which is exactly when the
    /// control matters most. They also never sat well: `firstTextBaseline`
    /// between an 18 pt bold rounded number and an 11 pt caption puts the
    /// caption high against the number it qualifies. Stacked, the meta is as
    /// subordinate as it ever was, which was the point of the old arrangement
    /// rather than the line it happened to be on.
    private var headline: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
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
            }
            Spacer(minLength: 8)
            periodPicker
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .animation(.default, value: snapshot.cost)
    }

    /// Tokens always, the pace only on today, and how far back the archive
    /// reaches only when it falls short of the window named beside it.
    private var subline: String {
        var parts = ["\(snapshot.tokens) tokens"]
        if let burn = snapshot.burn { parts.append("\(burn)/h") }
        if let coverage = snapshot.coverage { parts.append(coverage) }
        return parts.joined(separator: " · ")
    }

    /// A popup rather than a segmented control: four boxes at full width,
    /// permanently on screen, is a lot of the panel's scarcest room for a choice
    /// most people make once. The cost is that a closed menu does not advertise
    /// the windows behind it — a period with a disclosure chevron says there is
    /// a choice without saying which, and that is the accepted trade.
    ///
    /// Absent entirely while there is no archive behind the other windows, which
    /// is both a fresh install and the archive switched off. A control whose
    /// every option answers the number already on screen is a control about a
    /// feature.
    @ViewBuilder
    private var periodPicker: some View {
        if snapshot.periods.count > 1 {
            Picker("Period", selection: periodBinding) {
                ForEach(snapshot.periods, id: \.self) { period in
                    Text(UsageFormat.periodLabel(period)).tag(period)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .help("What the numbers above are over")
        }
    }

    private var periodBinding: Binding<UsagePeriod> {
        Binding(get: { snapshot.period }, set: { selectPeriod($0) })
    }

    // MARK: Providers

    /// One row per provider, each carrying the window it is closest to running
    /// out of. A row opens that provider's page, which is where its other
    /// windows, its plan, its account, its day and its own projects live.
    ///
    /// Drawn with no rows at all before the first reading lands and with every
    /// provider switched off, because its label carries the agents door.
    private var providers: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                SectionLabel(text: providersLabel)
                Spacer(minLength: 8)
                agentsDoor
            }
            ForEach(snapshot.gaugeRows) { row in
                Button {
                    openProvider(row.provider, row.account)
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

    /// What the CLIs on this Mac are holding, and the way to the page behind
    /// it, at the end of the providers label.
    ///
    /// **On the label rather than a row of its own**, which is where it sat
    /// until the row was all it cost: a row's height of the Overview for one
    /// reading and a chevron. It keeps the adjacency the row was placed for —
    /// it answers the question the gauges under it do, whether there is room
    /// to keep working, on the other axis that stops work now — and it takes
    /// the shape `ProjectsSectionLabel` already taught the panel: a reading at
    /// the end of a label, and a chevron. The reading names *agents* in its
    /// own words, never a bare count, because a number at the end of this
    /// label would read as a count of providers. Measured 2026-09-22, the
    /// longest label and the widest reading need about 298 pt of the 312.
    ///
    /// Drawn before the first sweep lands and on a Mac with nothing running,
    /// because it is the only door to the page and a door that comes and goes
    /// with the day is not one.
    private var agentsDoor: some View {
        Button(action: openStats) {
            HStack(spacing: 6) {
                Text(snapshot.agents.summary)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(
                        snapshot.agents.live?.running ?? 0 > 0 ? .primary : Color.secondary
                    )
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .layoutPriority(1)
        .help("How many sessions and agents have run, and what they are holding now")
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
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
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

    /// Where the day's money went. The reason the app exists, so it sits below
    /// nothing but the day's own numbers.
    ///
    /// Today's, under a headline that may be over a month — so the label says
    /// `today` rather than leaving the reader to pair it with the window above.
    /// The block that names its own day is the one that does not follow the
    /// control; the provider rows above it say the same word for the same
    /// reason.
    ///
    /// The archive carries the project on its rows, but only from the day the
    /// dimension landed: the days before it name no repository at all, and a
    /// window reaching back across them would put an unattributed row above
    /// real ones.
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
        VStack(alignment: .leading, spacing: 8) {
            Button(action: openProjects) {
                ProjectsSectionLabel(text: "By project · today", count: snapshot.projectCount)
            }
            .buttonStyle(.plain)
            .help("Show every project")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(snapshot.projects) { row in
                    ProjectRowView(
                        row: row, bar: .behind,
                        checkIdentity: row.repository == nil ? nil : { openIdentities(row.id) })
                }
            }
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 12)
    }

    // MARK: Forge

    /// How much was pushed, per forge account, over the window the headline is
    /// on.
    ///
    /// It sits at the foot, below the projects, and the reason is the question
    /// rather than the height: the projects are what the app is for and nothing
    /// may push them under the fold — which is what the provider gauges were
    /// collapsed to one row each to stop — and a contribution count is the
    /// least urgent reading on the page. It is also the only block here that is
    /// not about this Mac at all, which is the second reason it is last.
    ///
    /// **The two rows are never summed.** Each vendor counts its own thing —
    /// GitHub its contribution total, GitLab the events it recorded — so a
    /// total across them would be a third number belonging to neither, which is
    /// the rule the credits rows are already under.
    private var forge: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: UsageFormat.forgeSectionLabel(snapshot.period))
            ForEach(snapshot.forge) { row in
                ForgeRowView(
                    row: row,
                    refreshing: refreshingForge.contains(row.id),
                    refresh: { refreshForge(row.id) })
            }
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 12)
    }
}
