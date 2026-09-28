import SwiftUI

/// The Git tab: what was pushed to each connected forge, and whether every
/// repository commits under the name its forge expects.
///
/// **One tab for both, because both are about repositories and neither is
/// about this Mac's spend.** The contribution counts sat at the foot of the
/// Overview as its least urgent reading, and the identity line above them;
/// together they are a page, and a page of their own keeps the projects the
/// only list the Usage tab has to fold.
///
/// The counts follow the period the Usage tab's headline is on, and their
/// label says which: the control is the money's, and a second one here would
/// be two answers to the same question.
struct PanelGit: View {
    let snapshot: UsagePanelSnapshot
    /// Which forge connections are being re-read, so their rows can say so
    /// where they otherwise print an age about to change.
    let refreshingForge: Set<String>
    let refreshForge: (String) -> Void
    /// Opens the identities page, on the repository named or on the whole
    /// list where none is.
    let openIdentities: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.platterGap) {
            forge
            PanelIdentityLine(line: snapshot.identityLine, open: openIdentities)
        }
        .padding(PanelMetrics.platterInset)
    }

    /// How much was pushed, per forge account, over the window the headline
    /// is on.
    ///
    /// **The rows are never summed.** Each vendor counts its own thing —
    /// GitHub its contribution total, GitLab the events it recorded — so a
    /// total across them would be a third number belonging to neither, which
    /// is the rule the credits rows are already under.
    private var forge: some View {
        PanelGroup {
            SectionLabel(text: UsageFormat.forgeSectionLabel(snapshot.period))
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(snapshot.forge) { row in
                    ForgeRowView(
                        row: row,
                        refreshing: refreshingForge.contains(row.id),
                        refresh: { refreshForge(row.id) })
                }
            }
        }
    }
}

/// The door to the identities page, on whichever tab repositories live on.
///
/// **Always there, and quiet unless something is wrong.** It was drawn only
/// while a repository disagreed with its forge, which left the page behind a
/// right-click on a project row on every other day — so the check went
/// unnoticed until it had something to say, and a user who had never seen
/// the line had no reason to trust its absence. It keeps the agents door's
/// rule: a door that comes and goes is not one. What stays true of the old
/// design is the weight. With no finding the line is secondary, a tick and a
/// count; a finding turns it primary with the warning mark and names the
/// repository whenever there is only one, because naming it is the whole of
/// the remaining work.
///
/// **On the Git tab once a forge is connected, under the projects before.**
/// It answers for every repository Sissy knows whether or not a forge is
/// connected, so it does not wait for one; and it is not a badge per project
/// row, which would be the decorative signal on the cost axis the panel
/// refuses, since that list is ordered by spend.
struct PanelIdentityLine: View {
    let line: UsagePanelSnapshot.IdentityLine
    let open: (String?) -> Void

    var body: some View {
        PanelGroup {
            Button {
                open(line.repository)
            } label: {
                HStack(spacing: 6) {
                    mark
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
        }
    }

    /// The page's own marks, so the line and the rows it leads to read alike.
    /// Nothing read carries no mark: a tick there would be a verdict.
    @ViewBuilder
    private var mark: some View {
        switch line.state {
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
}
