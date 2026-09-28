import SwiftUI

/// The Forge tab: what was pushed to each connected forge, and whether every
/// repository commits under the name its forge expects.
///
/// **One tab for both, because both are about repositories and neither is
/// about this Mac's spend.** The contribution counts sat at the foot of the
/// Overview as its least urgent reading, and the identity line above them;
/// together they are a page, and a page of their own keeps the projects the
/// only list the Usage tab has to fold.
///
/// The counts follow the panel's period, chosen in the header, and their
/// label says which: one control above every tab, never a second one here
/// answering the same question.
struct PanelForge: View {
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
            ForEach(snapshot.forge) { row in
                section(row)
            }
            PanelIdentityLine(line: snapshot.identityLine, open: openIdentities)
        }
        .padding(PanelMetrics.platterInset)
    }

    /// How much one forge account did over the panel's window, and the last
    /// thing it did.
    ///
    /// **A section each, and never summed.** Each vendor counts its own
    /// thing — GitHub its contribution total, GitLab the events it recorded —
    /// so a total across them would be a third number belonging to neither,
    /// which is the rule the credits rows are already under, and two platters
    /// say so where one block of rows invited the sum.
    private func section(_ row: UsagePanelSnapshot.ForgeRow) -> some View {
        let refreshing = refreshingForge.contains(row.id)
        return PanelGroup {
            ForgeSectionLabel(row: row, refreshing: refreshing)
        } content: {
            ForgeRowView(row: row, refreshing: refreshing, refresh: { refreshForge(row.id) })
        }
    }
}

/// A forge section's heading: the vendor and the window on the left, and on
/// the right what the row is doing, what went wrong, or how old it is.
///
/// The right-hand end is where `ProjectsSectionLabel` puts its count, and the
/// age earned the place for the reason `UsageFormat.forgeSectionLabel` gives:
/// in a caption under the row it cut the latest event short. The title keeps
/// its width before the notice does, because it is what tells two sections
/// apart, and the notice shortens at its tail, which a failure's reason
/// survives.
///
/// `TimelineView` rather than a string the snapshot already built: this
/// block's frame arrives every five to thirty minutes, so an age taken from it
/// would sit at "read 2m ago" for half an hour under an open panel. It is what
/// `PanelProviderStatus` does with `checkedAt`, and the two are the same
/// reading for the same reason.
struct ForgeSectionLabel: View {
    let row: UsagePanelSnapshot.ForgeRow
    let refreshing: Bool

    /// Matches the panel header's, for the reason that one is a second rather
    /// than a minute: the first minute of an age is worded in seconds.
    private static let clockTick: TimeInterval = 1

    var body: some View {
        HStack(spacing: 6) {
            SectionLabel(text: row.title)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            TimelineView(.periodic(from: .now, by: Self.clockTick)) { context in
                if let notice = UsageFormat.forgeNotice(
                    row.kind, failure: row.failure, readAt: row.readAt, opensAt: row.opensAt,
                    refreshing: refreshing, now: context.date)
                {
                    Text(notice)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
/// the line had no reason to trust its absence. It keeps the rule every door
/// on the panel keeps: a door that comes and goes is not one. What stays true of the old
/// design is the weight. With no finding the line is secondary, a tick and a
/// count; a finding turns it primary with the warning mark and names the
/// repository whenever there is only one, because naming it is the whole of
/// the remaining work.
///
/// **On the Forge tab once a forge is connected, under the projects before.**
/// It answers for every repository Sissy knows whether or not a forge is
/// connected, so it does not wait for one; and it is not a badge per project
/// row, which would be the decorative signal on the cost axis the panel
/// refuses, since that list is ordered by spend.
///
/// **Headed like every other block, as of 2026-09-28.** It was the one platter
/// on the page with no label above it, so the line spent its own width saying
/// what it was, `Commit identity · no findings in 14 repositories`. The name
/// and the count are the heading's now, the count at the end where the
/// projects' sits, and the line is left saying the verdict.
struct PanelIdentityLine: View {
    let line: UsagePanelSnapshot.IdentityLine
    let open: (String?) -> Void

    var body: some View {
        PanelGroup {
            HStack(spacing: 6) {
                SectionLabel(text: UsageFormat.identitySectionLabel)
                Spacer(minLength: 8)
                if let count = line.count {
                    Text(count)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } content: {
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
