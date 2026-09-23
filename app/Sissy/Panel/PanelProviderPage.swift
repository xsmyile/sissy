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
    /// Switches the vendor to another of its accounts, after the user has
    /// confirmed it. Never called for a vendor with one account, whose row
    /// carries no choices, and never straight from the menu: picking proposes
    /// and the confirmation commits.
    /// Which account the page was opened on, which is the Overview row that
    /// was clicked. The picker overrides it and nothing else does.
    let openOnAccount: String?
    let onSelectAccount: (String) -> Void
    /// Opens the login window that links another account.
    let onAddAccount: () -> Void
    /// Why the last switch did not happen, when one did not. Shown under the
    /// identity, because a switch that quietly failed leaves the user typing
    /// `claude` and meeting the account they thought they had left.
    let switchFailure: String?
    /// The account a switch is running for, or nil when none is. Named rather
    /// than a flag so the page can say which account it is moving to.
    let switchingAccount: String?
    let refresh: () -> Void
    /// Opens the vendor's services, which are a page of the panel rather than
    /// a surface of this one's: the panel owns which page is on screen, so the
    /// row at the foot of this page asks for the move instead of making it.
    /// Both carry the account the page is **showing**, not the one it was
    /// opened on. The picker is this view's own state, so it dies when the
    /// page leaves the hierarchy — a page that handed its opening argument
    /// back would return the user to the account they had navigated away
    /// from, having read another one in between.
    let openServices: (String?) -> Void
    let openProjects: (String?) -> Void
    let openEffort: (String?) -> Void
    /// Opens a repository's commit identity from its own row, so the same row
    /// offers the same actions wherever the panel draws it.
    let openIdentities: (String) -> Void
    /// This provider's archived days, read once when the page opens. A closure
    /// rather than a value because the read walks the archive and the page is
    /// rebuilt on every frame the engine emits — a value would have to be
    /// carried down through a view that has no use for it, and a read on the
    /// frame path is the one thing this must not become.
    let loadHistory: (String) async -> [UsageHistoryDaySummary]
    /// Today's raw figures off the frame, for the one bar the archive must not
    /// answer for. The rest of the page reads today already worded; the strip
    /// needs the `Decimal` to scale a bar against the days beside it.
    let todayTokens: Int
    let todayCost: Decimal

    /// The archived days, read once when the page opens. The strip itself is
    /// derived in `body` rather than stored, because today's bar comes from
    /// the frame and a stored strip would freeze it at the moment the page was
    /// opened while the `Today` row below it kept moving.
    @State private var series: [UsageHistoryDaySummary] = []
    /// The account picked but not yet confirmed. Picking is not switching:
    /// the write reaches Claude Code's own credential, and the one thing a
    /// user cannot work out for themselves — that an open session undoes it —
    /// has to be said before it happens rather than discovered afterwards.
    @State private var pendingAccount: UsagePanelSnapshot.AccountEntry?
    /// Which account's reading the page is showing. Nil is the signed-in one,
    /// which is what the row's own fields already carry.
    ///
    /// Picking here changes nothing outside Sissy. Signing the CLI in as an
    /// account is a separate control that appears only while you are looking
    /// at one it is not already on, which is what stops the reading you asked
    /// for from also being a write to another program's credential.
    @State private var viewedAccount: String?

    /// The account the page is reading, or nil while there is one account and
    /// the row's own fields are it.
    ///
    /// Once it names an account, **every** field below comes from that
    /// account and none falls back to the row. The row's are the signed-in
    /// account's, so a `??` behind a nil on the viewed one pairs one
    /// account's identity with another's reading — the shape `ProviderSignals`
    /// exists to prevent, and one this page could produce in the ordinary
    /// case: an account with no session linked has no credits and no reading
    /// time of its own, and would have shown the CLI account's under its own
    /// name and organisation.
    private var viewed: UsagePanelSnapshot.AccountEntry? {
        guard !row.accounts.isEmpty else { return nil }
        let wanted = viewedAccount ?? openOnAccount
        return row.accounts.first { $0.id == wanted }
            ?? row.accounts.first { $0.isSignedIn }
            ?? row.accounts.first
    }

    private var shownCredits: UsagePanelSnapshot.CreditsRow? {
        viewed.map(\.credits) ?? row.credits
    }

    private var shownEmail: String? { viewed.map(\.email) ?? row.account?.email }

    private var shownOrganization: String? {
        viewed.map(\.organization) ?? row.account?.organization
    }

    private var shownPlan: String? { viewed.map(\.plan) ?? row.plan }

    private var shownPlanTier: String? { viewed.map(\.planTier) ?? row.planTier }

    private var shownWindowsCaption: String? {
        viewed.map(\.windowsCaption) ?? row.windowsCaption
    }

    private var shownNotice: UsagePanelSnapshot.LimitsNotice? {
        viewed.map(\.notice) ?? row.notice
    }

    private var tint: Color { ProviderPalette.tint(for: row.id) }

    /// The row the effort reading answers in on this page, when the window
    /// named any effort.
    private var effortSummary: (summary: UsagePanelSnapshot.EffortSummary, window: String)? {
        let window = UsagePanelSnapshot.effortWindow(series: series, today: row.effort)
        guard let summary = UsagePanelSnapshot.effortSummary(window.splits, provider: row.id)
        else { return nil }
        return (
            summary,
            UsageFormat.effortWindow(
                covered: window.covered, of: UsagePanelSnapshot.dayStripDays)
        )
    }

    private var strip: UsagePanelSnapshot.DayStrip? {
        UsagePanelSnapshot.dayStrip(
            series: series, provider: row.id, todayTokens: todayTokens,
            todayCost: todayCost, todayModels: row.models,
            days: UsagePanelSnapshot.dayStripDays)
    }

    var body: some View {
        let effortSummary = self.effortSummary
        return VStack(alignment: .leading, spacing: 0) {
            identity

            Divider()
            limits

            if let credits = shownCredits {
                Divider()
                self.credits(credits)
            }

            Divider()
            day

            if !row.projects.isEmpty {
                Divider()
                projects
            }

            if let effortSummary {
                Divider()
                effort(effortSummary.summary, window: effortSummary.window)
            }

            if let status = row.status {
                Divider()
                PanelProviderStatus(
                    provider: row.id, row: status,
                    openServices: { openServices(viewed?.id) })
            }
        }
        .task(id: row.id) {
            series = await loadHistory(row.id)
        }
    }

    // MARK: Identity

    /// Who this is, under the name the header already prints: the address the
    /// CLI is signed in as, the organisation where the vendor names one, and
    /// the plan that account is on. Every field comes off a file the
    /// adapter was already reading, so the block costs no new source and no
    /// permission.
    ///
    /// The plan sits here rather than against the provider's name in the
    /// header, because it qualifies the account and not the CLI: "Team
    /// Premium" is something this address is on, and beside a title it read as
    /// a label on the app.
    @ViewBuilder
    private var identity: some View {
        if row.account != nil || row.plan != nil || !row.accounts.isEmpty
            || row.accountsNotice != nil
        {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    if let email = shownEmail {
                        Text(email)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    organisation
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                useInCLI
                accountPicker
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PanelMetrics.gutter)
            .padding(.vertical, 10)
            if let pendingAccount, switchingAccount == nil {
                switchConfirmation(pendingAccount)
            }
            if let switchingAccount,
                let choice = row.accounts.first(where: { $0.id == switchingAccount })
            {
                switchProgress(choice)
            }
            if let switchFailure, pendingAccount == nil, switchingAccount == nil {
                identityCaption(switchFailure)
            } else if let viewed, !viewed.isSignedIn, viewed.needsLogin {
                identityCaption(ClaudeAccountSwitchCopy.needsLogin)
            }
            if let notice = row.accountsNotice {
                identityCaption(notice)
            }
        }
    }

    /// A sentence under the identity line, for what the switcher has to say
    /// about an account rather than about its limits.
    private func identityCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, PanelMetrics.gutter)
            .padding(.bottom, 10)
    }

    /// The question, the warning and the two answers, inside the panel.
    ///
    /// Not an `NSAlert`: Sissy has no windows, and a switch offered from a
    /// popover should not summon one to ask about itself.
    ///
    /// Escape cancels and nothing is the default action: the commit writes
    /// another program's credential, so it is reached by aiming at it and
    /// never by a return key pressed at a panel.
    @ViewBuilder
    private func switchConfirmation(_ choice: UsagePanelSnapshot.AccountEntry)
        -> some View
    {
        VStack(alignment: .leading, spacing: 6) {
            Text(ClaudeAccountSwitchCopy.confirmTitle(choice.label))
                .font(.system(size: 12, weight: .medium))
            Text(ClaudeAccountSwitchCopy.confirmBody)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(ClaudeAccountSwitchCopy.confirmReassurance)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(ClaudeAccountSwitchCopy.confirmCancel) { pendingAccount = nil }
                    .keyboardShortcut(.cancelAction)
                Button(ClaudeAccountSwitchCopy.confirmAction) {
                    pendingAccount = nil
                    onSelectAccount(choice.id)
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func switchProgress(_ choice: UsagePanelSnapshot.AccountEntry) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(ClaudeAccountSwitchCopy.switching(choice.label))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.bottom, 10)
    }

    /// Switches which of this vendor's accounts is signed in.
    ///
    /// It sits on the identity line because that line *is* the account — the
    /// address, the organisation and the plan all belong to it, and a control
    /// that changes them belongs where they are rather than in Settings.
    ///
    /// A `Menu` inside the popover is safe — a transient `NSPopover` is not
    /// dismissed by one, verified on macOS 27.
    @ViewBuilder
    private var accountPicker: some View {
        if !row.accounts.isEmpty {
            Menu {
                Picker("Account", selection: accountBinding) {
                    ForEach(row.accounts) { choice in
                        Text(choice.label).tag(choice.id)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                addAccount
            } label: {
                Image(systemName: "person.2")
                    .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help(accountPickerHelp)
        }
    }

    /// The account list as a radio group, which is what an inline `Picker` in
    /// a menu renders to — the same shape the keep-awake modes already take,
    /// and the only one that marks which entry is current.
    ///
    /// Picking is a change of view and nothing else. It used to be the switch
    /// itself, which made a one-click menu item rewrite Claude Code's
    /// credential; that is now `useInCLI`, which asks first.
    ///
    /// A `Button` per account with a `Label(_:systemImage: "checkmark")` on the
    /// active one does not: a macOS menu item built from a SwiftUI `Button`
    /// drops the label's image, so every account rendered as plain text and
    /// the menu said nothing about which one the CLI was signed into.
    ///
    /// An id nothing matches leaves every entry unmarked, which is the honest
    /// rendering of an index that names an active account it no longer holds.
    private var accountBinding: Binding<String> {
        Binding(
            get: { viewed?.id ?? "" },
            set: { picked in viewedAccount = picked }
        )
    }

    /// Links another account, from where someone looking at their accounts
    /// already is.
    ///
    /// A plain `Button`, because the whole link now happens in its own window
    /// and Settings is no longer on the way to anything. It also could not
    /// have stayed a `SettingsLink`: a `simultaneousGesture` is the only way
    /// to aim that at a tab, and inside an AppKit menu it does not fire —
    /// measured on the dev build, the item opened Settings on whatever tab was
    /// last shown.
    private var addAccount: some View {
        Button(ClaudeAccountLinkCopy.addTitle, action: onAddAccount)
    }

    /// What the picker does, which is not the same sentence for both vendors.
    ///
    /// On Claude Code an account in this menu is one Sissy can sign the CLI in
    /// as, so the tooltip says so rather than selling a credential change as a
    /// filter. On Codex there is no such control — a linked account is read
    /// and never signed in with — so the same words would promise something
    /// the page cannot do.
    private var accountPickerHelp: String {
        row.id == ProviderID.codex ? Self.readOnlyPickerHelp : Self.switchablePickerHelp
    }

    static let switchablePickerHelp =
        "Choose which account Claude Code signs in as. Sissy asks before it changes anything."

    static let readOnlyPickerHelp =
        "Choose which account to read. Codex stays on the account it is signed into."

    /// Signs Claude Code in as the account being read.
    ///
    /// Present only while that is not the account it is already on, so it
    /// cannot fire for the one in use and the accident it used to be is gone
    /// by construction rather than by dialog. Absent for an account Sissy
    /// holds no credential for — there is nothing to sign in with, and that
    /// first `/login` is the user's.
    @ViewBuilder
    private var useInCLI: some View {
        if let viewed, !viewed.isSignedIn, viewed.isSwitchable,
            pendingAccount == nil, switchingAccount == nil
        {
            Button(ClaudeAccountSwitchCopy.useInCLI) { pendingAccount = viewed }
                .controlSize(.small)
                .help(Self.useInCLIHelp)
        }
    }

    static let useInCLIHelp =
        "Sign Claude Code in as this account. Sissy keeps the one you are leaving."

    /// The organisation and the plan on one line, either of which can be the
    /// only one there: a personal account names no organisation, and an
    /// API-key user is on no plan.
    @ViewBuilder
    private var organisation: some View {
        if row.account?.organization != nil || row.plan != nil {
            HStack(spacing: 6) {
                if let organization = shownOrganization {
                    Text(organization)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let plan = shownPlan {
                    PlanBadge(plan: plan, tier: shownPlanTier)
                }
                if let viewed, viewed.isSignedIn, row.accounts.count > 1 {
                    Text(ClaudeAccountSwitchCopy.signedInBadge)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Limits

    /// The window this provider is closest to running out of, which is the one
    /// the block leads on. `UsagePanelSnapshot.binding` is where the rule
    /// lives, so the page and the Overview's legend cannot lead on different
    /// windows of the same provider.
    private var binding: UsagePanelSnapshot.WindowRow? {
        UsagePanelSnapshot.binding(shownWindows)
    }

    /// The windows of the account being read, which is the row's own while
    /// there is one account.
    private var shownWindows: [UsagePanelSnapshot.WindowRow] {
        viewed.map(\.windows) ?? row.windows
    }

    /// Every window this provider reports, shortest first, with the reason
    /// they are missing when they are.
    ///
    /// A provider that publishes none says so in a sentence rather than
    /// leaving the block empty: an API-key user has no subscription window,
    /// and a Codex that has not taken a turn since launch has not sent one
    /// yet — neither is a fault, and both look identical to a blank space.
    ///
    /// The age rides the block's own heading, beside the word it qualifies.
    /// Neither provider's windows are fetched when this page opens — Codex's
    /// ride the CLI's own turns and Claude's a five-minute poll — so the only
    /// other date on screen is the frame's, and that one moves when the
    /// *other* provider spends anything. It is the heading's because it is
    /// true of every gauge under it: sitting below the last one it read as
    /// that row's caption, which is where each window's own pace sentence
    /// already is.
    private var limits: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SectionLabel(text: "Limits")
                Spacer(minLength: 0)
                if let caption = shownWindowsCaption {
                    Text(caption)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if let notice = shownNotice {
                LimitsNoticeView(
                    notice: notice, act: notice.kind == .link ? onAddAccount : refresh)
            }

            if shownWindows.isEmpty {
                if shownNotice == nil {
                    Text(
                        viewed.map { $0.isReadable } == false
                            ? UsageFormat.unlinkedAccountCaption
                            : UsageFormat.noWindowsCaption(row.id)
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(shownWindows) { window in
                    WindowRowView(
                        window: window, tint: tint, isBinding: window.id == binding?.id)
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
    ///
    /// Built to the shape of a window row above it, which it was not: measured
    /// 2026-09-16, this block put 11-13 pt between its heading and its bar and
    /// 13-15 pt between the bar and its caption where `WindowRowView` puts 4
    /// and 5, so the one section answering the same question in the same two
    /// figures and a bar stood 82.5 pt tall against a window's 32.5. Two things
    /// did it: a section's spacing used between a row's own parts, and the
    /// percentage parked beside the bar, where an 11 pt line is three times the
    /// height of the 5 pt it sits next to and the bar floats in the middle of
    /// the row it inflated. The percentage belongs with the amount it is a
    /// percentage *of*, on the heading line both already share.
    private func credits(_ credits: UsagePanelSnapshot.CreditsRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                SectionLabel(text: "Credits")
                Spacer(minLength: 0)
                Text(UsageFormat.creditsReading(amount: credits.amount, percent: credits.percent))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(credits.capReached ? Color.red : .primary)
                    .lineLimit(1)
            }

            if let fraction = credits.fraction {
                ShareBar(share: fraction, tint: credits.capReached ? .red : tint)
            }

            Text(credits.caption)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 12)
    }

    // MARK: The day

    /// What this provider has spent today, and the days behind it for scale.
    ///
    /// One block rather than two, because they were always one question. The
    /// strip's last bar is labelled `Today` and hovering it printed the very
    /// figures the row below was already printing — so the row was a heading
    /// with nothing under it, in a panel where a heading and a figure on one
    /// line mean a block follows. It heads this one.
    ///
    /// Today leads and the window under it is the caption, which is also what
    /// decides which of the two the hover moves: the pointed day replaces the
    /// caption, never the headline. A figure a reader came for should not
    /// change out from under the pointer on its way to the bars.
    ///
    /// The strip is absent until the archive reaches past today — a fresh
    /// install, or the archive switched off — and the headline is what stays,
    /// which is why it belongs to the page rather than to the strip.
    ///
    /// **The models sit under the strip, not between it and the headline.**
    /// They were between the two and it was wrong twice over. It put a list
    /// where the strip's own caption had to be read, so `Last 7 days` came
    /// after the split and read as belonging to it; and it drew the pills in
    /// the idiom the `By project` list further down already owns, so the page
    /// said one thing twice and the second time it was the models. Under the
    /// bars they are the caption of the day the bars are about, which is the
    /// reading they will keep when the pointed day drives them — the rule this
    /// block already states, that a hover replaces the caption and never the
    /// headline.
    ///
    /// **All three are the CLI's day, not the viewed account's.** Every other
    /// field on this page comes from `viewed` and none falls back to the row;
    /// these deliberately do not, because Sissy meters a config home and does
    /// not attribute spend to an account — a `cwd` and a `requestId` are on a
    /// log line and an identity is not. Wiring them through the picker would
    /// be a claim the data cannot support.
    private var day: some View {
        PanelDayBlock(
            today: row.tokens, todayCost: row.cost, todayModels: row.models,
            strip: strip, tint: tint)
    }

    // MARK: Effort

    /// At what effort this provider's week was worked, as one row.
    ///
    /// `UsagePanelSnapshot.effortSummary` carries why it is a row rather than
    /// the block it was, and when the row is a door. It sits under the
    /// projects rather than under the day because it answers for the strip's
    /// week and not for the day being pointed at, and a reading of a different
    /// window between the pills and the list read as part of the day.
    @ViewBuilder
    private func effort(_ summary: UsagePanelSnapshot.EffortSummary, window: String)
        -> some View
    {
        if summary.opens {
            Button {
                openEffort(viewed?.id)
            } label: {
                effortLabel(summary, window: window)
            }
            .buttonStyle(.plain)
            .help("Show each model's split by effort")
        } else {
            effortLabel(summary, window: window)
        }
    }

    private func effortLabel(_ summary: UsagePanelSnapshot.EffortSummary, window: String)
        -> some View
    {
        HStack(spacing: 6) {
            SectionLabel(text: "By effort")
            Spacer(minLength: 8)
            Text("\(summary.lead) · \(window)")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if summary.opens {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 12)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    // MARK: Projects

    /// This provider's own day by project, which the slice already carries —
    /// the Overview's list is the two summed, and a page that repeated it
    /// would answer a question nobody asked here.
    ///
    /// Folded past three rows exactly as the Overview's is, and for the same
    /// reason: this page has a plan, an account, its windows, its week and its
    /// vendor's status under it, and a repository per row would push all of
    /// them below whatever the busiest day happened to be. The label is the
    /// way to the unfolded list, so nothing is out of reach — which is what
    /// the fold costs everywhere else on the panel too.
    private var projects: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                openProjects(viewed?.id)
            } label: {
                ProjectsSectionLabel(text: "By project", count: row.projectCount)
            }
            .buttonStyle(.plain)
            .help("Show every project")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(row.projects) { project in
                    ProjectRowView(
                        row: project, bar: .behind,
                        checkIdentity: project.repository == nil
                            ? nil : { openIdentities(project.id) })
                }
            }
        }
        .padding(.horizontal, PanelMetrics.gutter)
        .padding(.vertical, 12)
    }
}
