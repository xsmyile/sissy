import SwiftUI

/// What one provider's row says. A pure function of the readiness so the
/// wording is testable without a running engine — the same shape
/// `SissyModel.HeaderSnapshot` uses for the panel header.
struct ProviderRowSnapshot: Equatable {
    let name: String
    let state: String
    let detail: String

    static func make(_ readiness: ProviderReadiness) -> Self {
        Self(
            name: UsageFormat.providerName(readiness.id),
            state: state(for: readiness.activation),
            detail: detail(for: readiness)
        )
    }

    private static func state(for activation: ProviderActivation) -> String {
        switch activation {
        case .on: return "On"
        case .autoDetected: return "On, detected"
        case .off: return "Off"
        case .autoNotFound: return "Not found"
        }
    }

    /// The line that answers "why is this provider not in my panel". The two
    /// ways to find nothing are kept apart on purpose: a data dir that is not
    /// there is a different problem from one that is there and empty, and
    /// naming the path is what makes either actionable.
    ///
    /// Exhaustive over the activation on purpose — a state added later has no
    /// sensible line to fall back to, so it has to fail the build here rather
    /// than quietly claim the user switched something off.
    private static func detail(for readiness: ProviderReadiness) -> String {
        let path = (readiness.dataDir.path as NSString).abbreviatingWithTildeInPath
        switch readiness.activation {
        case .off: return "\(path) is not being read"
        case .autoNotFound: return "\(path) does not exist"
        case .on, .autoDetected: return scanned(readiness.scan, at: path)
        }
    }

    private static func scanned(_ scan: ProviderReadiness.ScanProgress?, at path: String) -> String {
        guard let scan, scan.isWarm else { return "Reading your session logs" }
        switch scan.filesWatched {
        case 0: return "No session logs in \(path)"
        case 1: return "1 session file in \(path)"
        default: return "\(scan.filesWatched) session files in \(path)"
        }
    }
}

/// What one linked account's row carries, whichever vendor it is with: the
/// only things the two vendors' rows differ in.
private struct LinkedRowContent {
    let provider: String
    /// The key the account is filed under, which is what a rename is kept by.
    let id: String
    let title: String
    let subtitle: String?
    /// What the monogram's initials are taken from.
    let monogram: String
    let plan: (label: String, tier: String?)?
    /// What the row's menu copies and names the unlink by.
    let address: String
    let unlinkHelp: String
}

/// How one linked account is named in the list.
///
/// A pure function of the account, for the reason `ProviderRowSnapshot` is one:
/// the fallbacks are the whole substance of this row and they are worth holding
/// without a window.
///
/// The title is the name the panel gives the account, through the same
/// `AccountNaming`, so the list is the preview of the format picked under it
/// and a rename shows here the moment it is made. The caption is what that
/// name leaves out, so nothing on the row repeats itself. An account nothing
/// names is titled by the key it is filed under: a poor label and the only
/// honest one, and a row under it is what makes that credential removable.
struct LinkedAccountRowSnapshot: Equatable {
    let title: String
    let subtitle: String?

    static func make(
        id: String, account: ProviderAccount?, plan: String?, naming: AccountNaming
    ) -> Self {
        let title = naming.name(id: id, account: account, plan: plan) ?? id
        return Self(
            title: title, subtitle: naming.detail(name: title, account: account, plan: plan))
    }
}

/// Where each provider's numbers come from, and what it is doing about them.
struct ProvidersSettingsView: View {
    let model: SissyModel

    /// The account a confirmation is open for. A session is a secret the user
    /// cannot read back and did not have to type, so the one click that
    /// deletes it is asked about first — this one was pressed by accident on
    /// the account its owner was signed into.
    @State private var unlinking: ClaudeWebAccount?
    /// The Codex account a trash was pressed for, for the same reason: a
    /// credential the user cannot read back and never typed is not a click to
    /// get wrong.
    @State private var unlinkingCodex: CodexLinkedAccount?
    /// The account a rename is open for, and the name being typed for it.
    @State private var renaming: LinkedRowContent?
    @State private var renameDraft = ""

    private static let markSize: CGFloat = 18

    var body: some View {
        Form {
            ForEach(model.engine.providers, id: \.id) { readiness in
                Section {
                    row(readiness)
                    // Only under a Claude Code that is being metered: where it
                    // is not there is no limits probe and no slice for the
                    // windows to ride on, so a session linked here would read
                    // for a provider the user has told Sissy to leave alone.
                    if readiness.id == ProviderID.claudeCode, readiness.activation.isMetering {
                        linkedAccounts
                    }
                    // Only under a Codex that is being metered, for the reason
                    // the Claude list is: a credential linked under a provider
                    // Sissy was told to leave alone would poll for a row that
                    // does not exist.
                    if readiness.id == ProviderID.codex, readiness.activation.isMetering {
                        codexAccounts
                    }
                }
            }
            Section {
                accountNames
                statusChecks
            }
        }
        .formStyle(.grouped)
        .alert(
            AccountNamingCopy.renameTitle,
            isPresented: Binding(
                get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
            presenting: renaming
        ) { content in
            TextField(content.title, text: $renameDraft)
            Button(DialogCopy.cancel, role: .cancel) {}
            Button(AccountNamingCopy.renameConfirm) {
                model.renameAccount(content.id, to: renameDraft)
            }
        } message: { _ in
            Text(AccountNamingCopy.renameMessage)
        }
        .confirmRemoval(
            of: $unlinking,
            title: { ClaudeAccountLinkCopy.unlinkTitle(Self.label(of: $0)) },
            message: ClaudeAccountLinkCopy.unlinkMessage,
            confirm: ClaudeAccountLinkCopy.unlinkConfirm,
            action: { model.engine.forgetClaudeWebSession(account: $0.id) }
        )
        .confirmRemoval(
            of: $unlinkingCodex,
            title: { CodexAccountLinkCopy.unlinkTitle(Self.label(of: $0)) },
            message: CodexAccountLinkCopy.unlinkMessage,
            confirm: CodexAccountLinkCopy.unlinkConfirm,
            action: { model.engine.forgetCodexAccount(id: $0.id) }
        )
        // The readiness poll stops once the scan is warm, so a window opened
        // afterwards would render whatever the last tick left behind.
        .task {
            model.engine.refreshProviders()
            model.engine.refreshUnsupportedClaudeHomes()
        }
    }

    /// Which words every account is called by, on the panel and in the lists
    /// above, which are its preview: they redraw under the format as it is
    /// picked.
    private var accountNames: some View {
        SettingsPickerRow(
            title: AccountNamingCopy.label, caption: AccountNamingCopy.caption,
            selection: accountNameFormatBinding,
            options: AccountNameFormat.allCases, optionTitle: AccountNamingCopy.title)
    }

    private var accountNameFormatBinding: Binding<AccountNameFormat> {
        Binding(
            get: { model.preferences.accountNaming.format },
            set: { model.setAccountNameFormat($0) }
        )
    }

    /// Whether Sissy reads each vendor's own status page.
    ///
    /// It names the pages rather than describing them, for the reason the
    /// Files row names files: this is a request that leaves the Mac, and what
    /// it reaches is the part worth knowing before it is left on. What it
    /// carries is nothing — no account, no credential, no identity — which is
    /// why it can be on without being asked for.
    private var statusChecks: some View {
        SettingsSwitchRow(
            ProviderStatusCopy.label, caption: ProviderStatusCopy.caption,
            isOn: statusChecksBinding
        ) {
            HStack(spacing: 4) {
                Text(ProviderStatusCopy.label)
                SettingsInfoButton(
                    title: ProviderStatusCopy.infoTitle, detail: ProviderStatusCopy.detail)
            }
        }
    }

    private var statusChecksBinding: Binding<Bool> {
        Binding(
            get: { model.engine.statusChecks },
            set: { model.engine.setStatusChecks($0) }
        )
    }

    /// The vendor's line, the switch that decides whether Sissy reads it, and
    /// under both where it is reading and what it has found there.
    ///
    /// It heads its own section rather than sitting level with the rows under
    /// it: a provider and one of its accounts were the same shape and the same
    /// weight, so a list of three rows read as three settings rather than as
    /// one provider with two accounts.
    ///
    /// The switch carries the resolved state as its accessibility value rather
    /// than printing it beside itself: "On" next to a control already showing
    /// on is a label for the control, and the one thing the word adds over the
    /// switch — that Sissy detected this provider rather than being told about
    /// it — is worth a screen reader hearing and not worth a second column.
    private func row(_ readiness: ProviderReadiness) -> some View {
        let snapshot = ProviderRowSnapshot.make(readiness)
        return LabeledContent {
            Toggle(snapshot.name, isOn: binding(readiness))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityValue(snapshot.state)
                .disabled(model.engine.switchingProvider)
        } label: {
            HStack(spacing: 4) {
                Label {
                    Text(snapshot.name).font(.headline)
                } icon: {
                    ProviderMark(
                        id: readiness.id, size: Self.markSize, textSize: NSFont.systemFontSize)
                }
                info(for: readiness.id)
            }
            Text(snapshot.detail)
        }
    }

    /// What each provider's ⓘ has to say, which is everything the rows under
    /// it no longer print. A provider Sissy ships no account list for has
    /// nothing to explain and gets no button.
    @ViewBuilder
    private func info(for provider: String) -> some View {
        switch provider {
        case ProviderID.claudeCode:
            SettingsInfoButton(title: ClaudeAccountLinkCopy.infoTitle, detail: claudeDetail)
        case ProviderID.codex:
            SettingsInfoButton(
                title: CodexAccountLinkCopy.infoTitle, detail: CodexAccountLinkCopy.detail)
        default:
            EmptyView()
        }
    }

    /// The Claude ⓘ, which carries the free account's own paragraph only where
    /// there is one: a Mac whose CLI keeps no credential Sissy can read has no
    /// such account, and the sentence would be describing a row that is not
    /// there.
    private var claudeDetail: String {
        guard model.engine.claudeUsesOwnCredential else { return ClaudeAccountLinkCopy.detail }
        return ClaudeAccountLinkCopy.ownCredentialDetail + "\n\n" + ClaudeAccountLinkCopy.detail
    }

    /// This account's own reading off the last frame.
    ///
    /// The frame is where a per-account reading is: `ProviderSignals.accounts`
    /// carries one entry per credential the engine is polling, and the panel
    /// draws its own rows from the same list. Settings held none of it, which
    /// is why a row could not say whether the session beside its trash was
    /// still working.
    ///
    /// Nil is an account the engine has not answered for yet, which is the
    /// ordinary state in the moment after a link and never a fault.
    private func signals(of account: String, provider: String) -> AccountSignals? {
        model.accountSignals[provider]?.first { $0.id == account }
    }

    /// What the row has to report, in the reader's own words.
    ///
    /// `UsageFormat.limitsNotice` is the panel's wording for the same states,
    /// taken rather than paraphrased: a state either vendor learns to answer
    /// with is then worded in one place, and the row cannot drift from the
    /// notice the panel prints for the same account. The message and the
    /// control beside it are both read off this one notice, so the row cannot
    /// offer one state's button under another state's sentence.
    private func notice(
        of signals: AccountSignals?, provider: String
    ) -> UsagePanelSnapshot.LimitsNotice? {
        signals.flatMap { UsageFormat.limitsNotice($0.limitsState, provider: provider) }
    }

    private func health(of signals: AccountSignals?, provider: String) -> CredentialHealth {
        notice(of: signals, provider: provider).map { .attention($0.message) } ?? .ok
    }

    /// The control the panel offers beside the same notice, offered here too:
    /// this tab is where a linked account lives, so it is where somebody comes
    /// looking for the way to make it read again.
    private func fix(of signals: AccountSignals?, provider: String) -> CredentialFix? {
        guard let notice = notice(of: signals, provider: provider),
            let action = notice.action
        else { return nil }
        return CredentialFix(title: action) {
            switch notice.kind {
            case .refresh:
                model.engine.refreshProvider(provider)
            case .link:
                model.engine.addAccount(for: provider)
            }
        }
    }

    /// Reads the resolution rather than the stored toggle, so a provider Sissy
    /// auto-detected shows on — and writes an explicit value, which is what
    /// stops the next launch from re-deciding what the user has just decided.
    private func binding(_ readiness: ProviderReadiness) -> Binding<Bool> {
        Binding(
            get: { readiness.activation.isMetering },
            set: { model.engine.setProvider(readiness.id, enabled: $0) }
        )
    }

    /// Links another Claude account, which is the only way to read one the
    /// CLI is not signed into.
    ///
    /// The button is never disabled while a login is up: the window it opens
    /// floats, but a press here is also how someone gets back to one they have
    /// lost, and `present` brings the existing window forward rather than
    /// opening a second. The whole flow happens in that window, so this row
    /// carries only the way in and whatever the last attempt failed with.
    @ViewBuilder
    private var linkedAccounts: some View {
        Group {
            if !model.engine.unsupportedClaudeHomes.isEmpty {
                unsupportedHomes
            }
            if let why = model.engine.claudeWebLinkFailure {
                failure(ClaudeAccountLinkCopy.failure(why))
            }
            if let report = model.engine.claudeWebUnlinkFailure {
                failure(ClaudeAccountLinkCopy.unlinkFailure(report.failure))
            }
            ForEach(sortedAccounts) { account in
                linkedAccount(account)
            }
            CredentialAddRow(VendorLinkCopy.addTitle) { model.engine.addClaudeAccount() }
        }
    }

    /// The notice that a `claude` is signed in under a home Sissy does not
    /// read, drawn as a callout so it reads as a warning rather than as one
    /// more caption: the orange triangle is the panel's own mark for a
    /// provider that needs attention. Orange rather than red, because nothing
    /// Sissy did went wrong; the row is there so a missing account has an
    /// explanation.
    private var unsupportedHomes: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(Glyph.alert02)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(ClaudeUnsupportedHomesCopy.title)
                    .fontWeight(.semibold)
                Text(ClaudeUnsupportedHomesCopy.message(reading: model.engine.claudeConfigHome))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    /// What the last attempt to link failed with, on a row of its own now that
    /// the caption it used to replace lives in the ⓘ.
    private func failure(_ message: String) -> some View {
        Label(message, glyph: .alert02)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Ordered by the name they are drawn under rather than by the uuid they
    /// are keyed by, which is the order the engine deliberately does not have:
    /// the words are this layer's.
    ///
    /// The caption breaks a tie, because one person holding two seats is the
    /// case this list exists for and their rows can lead on the same word.
    private var sortedAccounts: [ClaudeWebAccount] {
        Self.sorted(model.engine.linkedClaudeAccounts) {
            let row = snapshot(of: $0)
            return (row.title, row.subtitle ?? "")
        }
    }

    /// A Claude account as its row names it: off its own reading where the
    /// engine has one, off the identity it was linked with where it has not.
    private func snapshot(of account: ClaudeWebAccount) -> LinkedAccountRowSnapshot {
        let signals = self.signals(of: account.id, provider: ProviderID.claudeCode)
        return LinkedAccountRowSnapshot.make(
            id: account.id,
            account: signals?.account ?? account.identity?.providerAccount,
            plan: signals?.plan ?? account.identity?.plan,
            naming: model.preferences.accountNaming)
    }

    /// A Codex account as its row names it, by the rule the Claude rows take.
    private func snapshot(of account: CodexLinkedAccount) -> LinkedAccountRowSnapshot {
        let signals = self.signals(of: account.id, provider: ProviderID.codex)
        return LinkedAccountRowSnapshot.make(
            id: account.id,
            account: signals?.account
                ?? ProviderAccount(
                    email: account.link?.identity.email,
                    organization: account.link?.workspace?.name),
            plan: signals?.plan ?? account.link?.identity.plan,
            naming: model.preferences.accountNaming)
    }

    /// What the confirmation and the screen reader call an account, which is
    /// deliberately the address rather than the title the row leads on.
    ///
    /// One person holding two seats reads as one name twice, and a dialog that
    /// asks whether to forget one name when both rows carry it is a
    /// destructive question nobody can answer. The address is unique by
    /// construction, which is the property this one call site needs.
    ///
    /// An account with no identity is one whose session was filed before
    /// anything could name it. Its uuid is a poor label and the only honest
    /// one — and a row under it is what makes that session removable.
    private static func label(of account: ClaudeWebAccount) -> String {
        account.identity.map(UsageFormat.accountLabel) ?? account.id
    }

    /// One linked account: who it is, what it is on, and whatever its reader
    /// has to report about it.
    ///
    /// The address and the organisation share the caption line rather than
    /// taking one each — they are one answer to "which seat is this" — and the
    /// plan rides at the end of the title line, where the panel already puts
    /// it.
    ///
    /// What unlinks it is a menu item rather than a bare trash. The trash was
    /// the only control the row carried, so the one thing a reader could see
    /// to do with an account was delete it, and what it deletes is a session
    /// the user cannot read back.
    private func linkedAccount(_ account: ClaudeWebAccount) -> some View {
        let row = snapshot(of: account)
        let signals = self.signals(of: account.id, provider: ProviderID.claudeCode)
        let content = LinkedRowContent(
            provider: ProviderID.claudeCode,
            id: account.id,
            title: row.title,
            subtitle: row.subtitle,
            monogram: row.title,
            plan: UsageFormat.plan(
                signals?.plan, tier: signals?.planTier, seat: signals?.account?.seat,
                name: signals?.planName),
            address: Self.label(of: account),
            unlinkHelp: ClaudeAccountLinkCopy.unlinkHelp)
        return linkedRow(content, signals: signals) { unlinking = account }
    }

    /// Links another Codex account, which is the only way to read one the CLI
    /// is not signed into. Never disabled while the login window is up, for
    /// the reason the Claude one is not: a press is how someone gets back to a
    /// window that went behind.
    @ViewBuilder
    private var codexAccounts: some View {
        Group {
            if let report = model.engine.codexUnlinkFailure {
                failure(CodexAccountLinkCopy.unlinkFailure(report.failure))
            }
            ForEach(sortedCodexAccounts) { account in
                codexAccount(account)
            }
            CredentialAddRow(VendorLinkCopy.addTitle) { model.engine.addCodexAccount() }
        }
    }

    /// Ordered by what the row is drawn under rather than by the id it is
    /// keyed by, which is the order the engine deliberately does not have.
    private var sortedCodexAccounts: [CodexLinkedAccount] {
        Self.sorted(model.engine.linkedCodexAccounts) { (snapshot(of: $0).title, $0.id) }
    }

    /// Accounts in the order of what their rows lead on, each row worded once
    /// rather than once per comparison.
    private static func sorted<Account>(
        _ accounts: [Account], by key: (Account) -> (String, String)
    ) -> [Account] {
        accounts.map { (account: $0, key: key($0)) }
            .sorted { $0.key < $1.key }
            .map(\.account)
    }

    /// What the confirmation and the screen reader call a Codex account: the
    /// address, which is unique where a workspace name is not. An account with
    /// no link is one whose naming failed — its id is a poor label and the only
    /// honest one, and a row under it is what makes it removable.
    private static func label(of account: CodexLinkedAccount) -> String {
        account.link?.identity.email ?? account.id
    }

    /// One linked Codex account, in the shape the Claude rows take: a linked
    /// credential is the same kind of thing whichever vendor issued it, and
    /// two row shapes for it would be two places for the same reading to be
    /// drawn differently.
    private func codexAccount(_ account: CodexLinkedAccount) -> some View {
        let row = snapshot(of: account)
        let signals = self.signals(of: account.id, provider: ProviderID.codex)
        let content = LinkedRowContent(
            provider: ProviderID.codex,
            id: account.id,
            title: row.title,
            subtitle: row.subtitle,
            monogram: row.title,
            plan: UsageFormat.plan(signals?.plan, tier: signals?.planTier),
            address: Self.label(of: account),
            unlinkHelp: CodexAccountLinkCopy.unlinkHelp)
        return linkedRow(content, signals: signals) { unlinkingCodex = account }
    }

    /// One linked account's row, whichever vendor it is with: the name, the
    /// plan, the line under it, the vendor-tinted monogram, and a menu that
    /// copies the address and unlinks. The two vendors differ only in what
    /// they pass, so a row cannot grow a control on one and not the other.
    private func linkedRow(
        _ content: LinkedRowContent, signals: AccountSignals?, unlink: @escaping () -> Void
    ) -> some View {
        let provider = content.provider
        let health = health(of: signals, provider: provider)
        return CredentialRow(
            title: content.title,
            badge: content.plan?.label,
            badgeTier: content.plan?.tier,
            subtitle: content.subtitle,
            health: health,
            fix: fix(of: signals, provider: provider)
        ) {
            CredentialMonogram(
                name: content.monogram, tint: ProviderPalette.tint(for: provider), health: health)
        } actions: {
            CredentialRowMenu(
                label: VendorLinkCopy.unlink(content.address), help: content.unlinkHelp
            ) {
                Button(AccountNamingCopy.renameItem) {
                    renameDraft = model.preferences.accountNaming.custom[content.id] ?? ""
                    renaming = content
                }
                CredentialCopyButton(CredentialRowCopy.copyAddress, of: content.address)
                Divider()
                Button(VendorLinkCopy.unlinkItem, role: .destructive, action: unlink)
            }
        }
    }
}
