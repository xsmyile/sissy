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
    /// Switches the vendor to another of its accounts. Never called for a
    /// vendor with one account, whose row carries no choices.
    let onSelectAccount: (String) -> Void
    let refresh: () -> Void

    private var tint: Color { ProviderPalette.tint(for: row.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            identity

            Divider()
            limits

            if let credits = row.credits {
                Divider()
                self.credits(credits)
            }

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
    /// CLI is signed in as, the organisation and renewal where the vendor
    /// says, and the plan that account is on. Every field comes off a file the
    /// adapter was already reading, so the block costs no new source and no
    /// permission.
    ///
    /// The plan sits here rather than against the provider's name in the
    /// header, because it qualifies the account and not the CLI: "Team
    /// Premium" is something this address is on, and beside a title it read as
    /// a label on the app.
    @ViewBuilder
    private var identity: some View {
        if row.account != nil || row.plan != nil || !row.accounts.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    if let email = row.account?.email {
                        Text(email)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    organisation
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                accountPicker
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PanelMetrics.gutter)
            .padding(.vertical, 10)
        }
    }

    /// Picks which of this vendor's accounts the page is about.
    ///
    /// It sits on the identity line because that line *is* the account — the
    /// address, the organisation and the plan all belong to it. It changes
    /// nothing outside the panel: every account is metered all the time, so
    /// this only decides which reading is drawn.
    ///
    /// A `Menu` inside the popover is safe — a transient `NSPopover` is not
    /// dismissed by one, verified on macOS 27.
    @ViewBuilder
    private var accountPicker: some View {
        if !row.accounts.isEmpty {
            Menu {
                ForEach(row.accounts) { choice in
                    Button {
                        onSelectAccount(choice.id)
                    } label: {
                        if choice.isSelected {
                            Label(choice.label, systemImage: "checkmark")
                        } else {
                            Text(choice.label)
                        }
                    }
                }
            } label: {
                Image(systemName: "person.2")
                    .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help(Self.accountPickerHelp)
        }
    }

    /// Said once here rather than at the call site: the picker is the only
    /// place the word "account" means a choice, and the tooltip is what stops
    /// it reading as a login.
    static let accountPickerHelp =
        "Show another account's usage. Both keep being counted either way."

    /// The organisation and the plan on one line, either of which can be the
    /// only one there: a personal account names no organisation, and an
    /// API-key user is on no plan.
    @ViewBuilder
    private var organisation: some View {
        if row.account?.details != nil || row.plan != nil {
            HStack(spacing: 6) {
                if let details = row.account?.details {
                    Text(details)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let plan = row.plan {
                    PlanBadge(plan: plan, tier: row.planTier)
                }
            }
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
    ///
    /// The gauges carry their own age under them. Neither provider's windows
    /// are fetched when this page opens — Codex's ride the CLI's own turns and
    /// Claude's a five-minute poll — so the only other date on screen is the
    /// frame's, and that one moves when the *other* provider spends anything.
    /// The window this provider is closest to running out of, which is the one
    /// the block leads on.
    ///
    /// Emphasis followed position before — the list is sorted shortest first,
    /// and the shortest was taken to be the one that binds. A session bucket
    /// nobody has started breaks that: it sorts first at 0% with no reset and
    /// takes the emphasis off a weekly window sitting at 100%.
    private var binding: UsagePanelSnapshot.WindowRow? {
        UsagePanelSnapshot.binding(row.windows)
    }

    private var limits: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Limits")

            if let notice = row.notice {
                LimitsNoticeView(notice: notice, act: refresh)
            }

            if row.windows.isEmpty {
                if row.notice == nil {
                    Text(UsageFormat.noWindowsCaption(row.id))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(row.windows) { window in
                    WindowRowView(window: window, tint: tint)
                        .opacity(
                            window.id == binding?.id ? 1 : PanelMetrics.secondaryWindowOpacity)
                }

                if let caption = row.windowsCaption {
                    Text(caption)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 12)
    }

    // MARK: Credits

    /// What the vendor has charged against the cap the user set, which is the
    /// figure people open the browser for.
    ///
    /// It sits under the limits because that is where it belongs: credits are
    /// what covers the work once a plan's window runs out, so the row above
    /// reading 100% is the reason this one is moving at all.
    ///
    /// The colour is reserved for a reached cap. That is the same axis the
    /// limits are on — headroom running out — and not a judgement on how much
    /// was spent, which is a line Sissy does not draw.
    private func credits(_ credits: UsagePanelSnapshot.CreditsRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SectionLabel(text: "Credits")
                Spacer(minLength: 0)
                Text(credits.amount)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(credits.capReached ? Color.red : .primary)
            }

            HStack(spacing: 8) {
                ShareBar(share: credits.fraction, tint: credits.capReached ? .red : tint)

                if let percent = credits.percent {
                    Text("\(percent)%")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .frame(width: 32, alignment: .trailing)
                }
            }

            Text(credits.caption)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
