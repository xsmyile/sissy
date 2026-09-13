import SwiftUI

/// What one account is doing: its limits, its day, and where its day went.
///
/// A page rather than a section because the refresh is not one action — on
/// Claude Code it re-reads the keychain and may put a system dialog on screen,
/// on Codex it re-reads a JSON file and cannot make a limit arrive — and
/// because it is the container per-provider agent activity goes into when it
/// arrives. Only the selected page is ever built, so a page nobody is looking
/// at costs nothing.
struct PanelProviderPage: View {
    let row: UsagePanelSnapshot.ProviderRow
    /// Whether the module behind this provider's limits is switched on. Only
    /// one provider has such a switch; it decides which sentence an empty
    /// limits block gets.
    let limitsEnabled: Bool
    let refresh: () -> Void

    private var tint: Color { ProviderPalette.tint(for: row.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            identity

            Divider()
            limits

            Divider()
            today

            if !row.projects.isEmpty {
                Divider()
                projects
            }
        }
    }

    // MARK: Identity

    /// Who this is, under the name the header already prints: the address the
    /// CLI is signed in as, and the organisation and renewal where the vendor
    /// says. Every field comes off a file the adapter was already reading, so
    /// the line costs no new source and no permission.
    @ViewBuilder
    private var identity: some View {
        if let account = row.account {
            VStack(alignment: .leading, spacing: 2) {
                if let email = account.email {
                    Text(email)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let details = account.details {
                    Text(details)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PanelMetrics.gutter)
            .padding(.vertical, 10)
        }
    }

    // MARK: Limits

    /// Every window this provider reports, shortest first, with the reason
    /// they are missing when they are.
    ///
    /// A provider that publishes none says so in a sentence rather than
    /// leaving the block empty: an API-key user has no subscription window,
    /// and a Codex that has not taken a turn since launch has not sent one
    /// yet — neither is a fault, and both look identical to a blank space.
    private var limits: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Limits")

            if let notice = row.notice {
                LimitsNoticeView(notice: notice, act: refresh)
            }

            if row.windows.isEmpty {
                if row.notice == nil {
                    Text(UsageFormat.noWindowsCaption(row.id, limitsEnabled: limitsEnabled))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(Array(row.windows.enumerated()), id: \.element.id) { index, window in
                    WindowRowView(window: window, tint: tint)
                        .opacity(index == 0 ? 1 : PanelMetrics.secondaryWindowOpacity)
                }
            }
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 12)
    }

    // MARK: Today

    private var today: some View {
        HStack(spacing: 6) {
            SectionLabel(text: "Today")
            Spacer(minLength: 0)
            Text("\(row.tokens) · \(row.cost)")
                .font(.system(size: 12))
                .monospacedDigit()
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 10)
    }

    // MARK: Projects

    /// This provider's own day by project, which the slice already carries —
    /// the Overview's list is the two summed, and a page that repeated it
    /// would answer a question nobody asked here.
    private var projects: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "By project")
            ForEach(row.projects) { project in
                ProjectRowView(row: project)
            }
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 12)
    }
}
