import SwiftUI

/// Every repository the day names, in one scrollable list.
///
/// The panel's lists fold past three rows because a popover has to leave room
/// for what sits under them — and a fold is a reading with nowhere to go, so
/// this is where the rest of it lives. Nothing is bounded here: the page is
/// the whole list, and what bounds it is the panel's own ceiling against the
/// screen it opened on, which is what replaced every per-section ceiling.
///
/// **It is a page rather than a card or a nested popover**, for the reason
/// `PanelProviderStatusPage` is: a popover dismissed from inside the panel
/// leaves the panel's window drawing from the wrong edge for about half a
/// second, and a list whose length is the day's is exactly the surface that
/// would change the panel's height when it closed.
///
/// **The provider rides on the row rather than on a column or a filter.** A
/// repository worked on through both CLIs is one row — that grouping is the
/// whole point of the project dimension — so which CLI spent is a property of
/// the row's money, not of the row. The marks say who, the bar says how much
/// of each, and neither costs the list a line or a legend.
///
/// **The remainder is a line at the foot rather than a row in the list.** The
/// subtitle totals the day and a list read against a total it cannot reach is
/// a list with a hole in it — so the figure stays, and this is the one surface
/// that carries it. What it is not is a project: it has no rank among them, no
/// bar to be compared by, no path and nothing to open, and as the last row of
/// the list it had all four.
struct PanelProjectsPage: View {
    let page: UsagePanelSnapshot.ProjectsPage
    /// Opens a repository's commit identity from its own row.
    ///
    /// The list folds on the Overview, so most repositories are only ever seen
    /// here — a right-click that offered the check on the rows it keeps and not
    /// on the rest would put the same row under two different rules.
    let openIdentities: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if page.rows.isEmpty {
                Text(UsageFormat.projectsEmpty)
                    .font(.system(size: PanelMetrics.rowText))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(page.rows) { row in
                ProjectRowView(
                    row: row, showsProviders: page.provider == nil,
                    checkIdentity: row.repository == nil ? nil : { openIdentities(row.id) })
            }
            if let residue = page.residue {
                ProjectsResidueLine(residue: residue)
            }
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 12)
    }
}

/// What the day spent outside every repository, under the rows it is not one
/// of.
///
/// Quiet, one line, and no bar: the rows above are ordered by spend and a bar
/// here would enter this figure into that order, which is the comparison it
/// must not invite — it is the rest of the day, not the smallest project.
///
/// **The split says who, and only where there is more than one answer.** One
/// CLI gets a mark, since the figure beside it is the one already on the line;
/// two get a figure each, which is the only reading this line can carry that
/// the panel cannot answer anywhere else — a provider's own page shows its own
/// residue and nothing tells you how the two compare.
private struct ProjectsResidueLine: View {
    let residue: UsagePanelSnapshot.ProjectsResidue

    var body: some View {
        HStack(spacing: 6) {
            Text(UsageFormat.projectsUnattributed(tokens: residue.tokens, cost: residue.cost))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            split
            Spacer(minLength: 0)
        }
        .help(UsageFormat.projectsUnattributedReason)
    }

    @ViewBuilder
    private var split: some View {
        if residue.providers.count == 1, let only = residue.providers.first {
            ProviderMark(id: only.id, textSize: 11)
                .help(UsageFormat.providerName(only.id))
        } else {
            ForEach(residue.providers) { provider in
                HStack(spacing: 3) {
                    ProviderMark(id: provider.id, textSize: 11)
                    Text(provider.cost)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .help(UsageFormat.providerName(provider.id))
            }
        }
    }
}
