import SwiftUI

/// Every repository the day names, in one scrollable list.
///
/// The panel's lists fold past five rows because a popover has to leave room
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
/// The remainder keeps its row here. The subtitle totals the day, and a list
/// read against a total it cannot reach is a list with a hole in it.
struct PanelProjectsPage: View {
    let page: UsagePanelSnapshot.ProjectsPage
    /// Opens a repository's commit identity from its own row.
    ///
    /// The list folds on the Overview, so most repositories are only ever seen
    /// here — a right-click that offered the check on the folded five and not
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
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 12)
    }
}
