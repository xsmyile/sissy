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

/// The claude.ai session, and what importing it changes.
///
/// It says what the thing is before the button is pressed, because it is a
/// whole browser session rather than a read-only usage token, and a user who
/// only finds that out afterwards was not asked.
/// What linking another Claude account says.
/// What the Codex account link says.
///
/// Its own vocabulary rather than the Claude one's: what is linked is a
/// sign-in to OpenAI rather than a session on a website, what it is read for is
/// a workspace rather than an organisation, and what unlinking costs is
/// different — there is no archived credential left behind, because Sissy
/// never took one.
enum CodexAccountLinkCopy {
    static let addTitle = "Add account…"
    static let infoTitle = "How Sissy reads Codex accounts"

    static let detail =
        "Sissy reads the account Codex is signed into for free. Linking another signs in "
        + "to OpenAI once, in a window, and reads its limits beside it. Your terminal stays "
        + "on the account it is on."

    static let chooseLabel = "Which workspace?"

    static func chooseCaption(_ email: String?) -> String {
        let account = email ?? "That account"
        return "\(account) has more than one. Sissy reads the one you pick, and keeps reading it."
    }

    static let unlinkHelp =
        "Forget this account's OpenAI sign-in. Codex itself is untouched."

    static let unlinkItem = "Unlink…"

    static func unlink(_ account: String) -> String { "Unlink \(account)" }

    static func unlinkTitle(_ account: String) -> String {
        "Forget the OpenAI sign-in for \(account)?"
    }

    static let unlinkMessage =
        "Sissy stops reading this account's limits. Codex keeps whatever account it is "
        + "signed into, and you can link this one again from this window."

    static let unlinkConfirm = "Forget"

    /// Why a sign-in produced no account. Each names something different to
    /// do: a refusal is worth trying again, and a token naming no login is not
    /// something a retry can fix.
    static func failure(_ why: CodexOAuth.Failure) -> String {
        switch why {
        case .refused:
            return "OpenAI would not complete that sign-in. Try again."
        case .unidentified:
            return "That sign-in came back without naming an account, so there is nothing to link."
        case .interrupted:
            return "The sign-in did not finish. Try again."
        case .notFiled:
            return "You signed in, but the keychain would not save it, so nothing was linked. "
                + "Unlock your login keychain and try again."
        }
    }

    static let linkedToDefaultTitle = "Linked to the default workspace"

    /// What the window says when a link was filed on the workspace OpenAI
    /// defaults the login to, because the list of workspaces could not be
    /// read and so nobody was asked.
    static func linkedToDefault(email: String?, workspace: String?) -> String {
        let account = email ?? "this account"
        let which =
            workspace.map { "the one OpenAI signs it into by default, \($0)" }
            ?? "the one OpenAI signs it into by default"
        return "Sissy could not read which workspaces \(account) belongs to, so it linked "
            + "\(which). To read another, unlink it and link it again."
    }

    /// Why the OpenAI page itself ended the sign-in.
    static func pageFailure(_ failure: VendorLoginWindow.PageFailure) -> String {
        switch failure {
        case .declined(let reason):
            return "OpenAI did not complete the sign-in (\(reason)), so nothing was linked. "
                + "Try again, or cancel if you meant to stop."
        case .unreachable:
            return "The OpenAI sign-in page could not be loaded. Check the connection and "
                + "try again."
        case .needsSecondWindow:
            return "That way of signing in needs a second browser window, which this window "
                + "cannot open, so nothing was linked. Try again and sign in with your email "
                + "address."
        }
    }
}

enum ClaudeAccountLinkCopy {
    static let addTitle = "Add account…"
    static let infoTitle = "How Sissy reads Claude accounts"

    static let detail =
        "Sissy reads the account Claude Code is signed into for free. Linking another "
        + "signs in to claude.ai once, in a window that closes itself, and reads its "
        + "limits and credits beside it."

    /// Why the account Sissy reads for free is whichever one the CLI is on,
    /// which is the half of the answer that only applies where Claude Code
    /// keeps a credential this Mac can read.
    ///
    /// It was a row of its own, titled `Limits source`, until 0.2.0: a
    /// statement of mechanism with no control on it, in a window where every
    /// other row is a control, costing 64 pt of a budget the tab was over.
    static let ownCredentialDetail =
        "Claude Code keeps its OAuth token in its own config directory, and it belongs to "
        + "whichever account is signed in there, so that is the account Sissy reads limits "
        + "for."

    static let chooseLabel = "Which organisation?"

    static func chooseCaption(_ email: String?) -> String {
        let account = email ?? "That account"
        return "\(account) has more than one. Sissy reads the one you pick, and keeps reading it."
    }

    static let unlinkHelp =
        "Forget this account's claude.ai session. The Claude Code sign-in Sissy archived "
        + "for it stays, so you can still switch to it."

    static let unlinkItem = "Unlink…"

    static func unlink(_ account: String) -> String { "Unlink \(account)" }

    static func unlinkTitle(_ account: String) -> String {
        "Forget the claude.ai session for \(account)?"
    }

    static let unlinkMessage =
        "Sissy stops reading this account's limits and credits from claude.ai. The Claude "
        + "Code sign-in it archived stays, so the account is still one you can switch to. "
        + "You can link the session again from this window."

    /// One word, because a longer one does not survive the alert's layout:
    /// every button is given the widest one's fitting width, and a row that
    /// passes ~110 pt is stacked vertically at full width instead. Measured
    /// 2026-09-17 on macOS 27, "Forget session" renders 114 pt and drew
    /// Cancel above it, where `CodexAccountLinkCopy` — the same dialog, one
    /// word shorter — drew both inline. The title already names what is
    /// being forgotten.
    static let unlinkConfirm = "Forget"

    static let cancel = "Cancel"
    static let link = "Link"
    static let retry = "Try again"
    static let done = "Done"
    static let failureTitle = "Sissy could not link that account"
    static let working = "Linking…"

    /// Why the claude.ai page itself ended the sign-in. Its login ends in a
    /// cookie rather than a redirect, so a decline is only reachable if the
    /// window is ever handed one.
    static func pageFailure(_ failure: VendorLoginWindow.PageFailure) -> String {
        switch failure {
        case .declined(let reason):
            return "claude.ai did not complete the sign-in (\(reason)), so nothing was linked. "
                + "Try again, or cancel if you meant to stop."
        case .unreachable:
            return "The claude.ai sign-in page could not be loaded. Check the connection and "
                + "try again."
        case .needsSecondWindow:
            return "That way of signing in needs a second browser window, which this window "
                + "cannot open, so nothing was linked. Try again and sign in with your email "
                + "address."
        }
    }

    static func failure(_ why: ClaudeWebAccountLink.Failure) -> String {
        switch why {
        case .unidentified:
            return "claude.ai would not say which account that session is for. Try again."
        case .noSubscription:
            return "That account is on no Claude plan Sissy can read limits for."
        case .interrupted:
            return "The sign-in was interrupted before Sissy could file it. Sign in again."
        }
    }
}

/// How one linked account is named in the list.
///
/// A pure function of the account, for the reason `ProviderRowSnapshot` is one:
/// the fallbacks are the whole substance of this row and they are worth holding
/// without a window.
///
/// The person's name leads where there is one, with the address beside it in
/// secondary text and the organisation underneath. The address leads where
/// there is no name, which is exactly the row every account had before — the
/// fallback is the old shape rather than a second one to maintain.
///
/// Nothing on the row repeats itself. An account named by its address carries
/// no second copy of it, and one the vendor named no address for is titled by
/// its organisation and then keeps no caption — a row that says the same thing
/// twice reads as two different facts.
struct LinkedAccountRowSnapshot: Equatable {
    let title: String
    /// The address, only where it is not already the title.
    let address: String?
    let organization: String?

    static func make(_ account: ClaudeWebAccount) -> Self {
        guard let identity = account.identity else {
            return Self(title: account.id, address: nil, organization: nil)
        }
        let title = identity.name ?? UsageFormat.accountLabel(identity)
        return Self(
            title: title,
            address: identity.name == nil ? nil : identity.email,
            organization: identity.organization == title ? nil : identity.organization)
    }
}

/// What the status switch says, and the part of it that moved into its ⓘ.
enum ProviderStatusCopy {
    static let label = "Provider status"
    static let caption = "Reads status.claude.com and status.openai.com."
    static let infoTitle = "What the status check reads"
    static let detail =
        "Sissy polls each vendor's own status page so the panel can say whether a provider "
        + "that has gone quiet is you or them. It carries no account, no sign-in and "
        + "nothing about your usage."
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
                statusChecks
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            unlinking.map { ClaudeAccountLinkCopy.unlinkTitle(Self.label(of: $0)) } ?? "",
            isPresented: Binding(get: { unlinking != nil }, set: { if !$0 { unlinking = nil } }),
            presenting: unlinking
        ) { account in
            Button(ClaudeAccountLinkCopy.unlinkConfirm, role: .destructive) {
                model.engine.forgetClaudeWebSession(account: account.id)
            }
            Button(ClaudeAccountLinkCopy.cancel, role: .cancel) {}
        } message: { _ in
            Text(ClaudeAccountLinkCopy.unlinkMessage)
        }
        .confirmationDialog(
            unlinkingCodex.map { CodexAccountLinkCopy.unlinkTitle(Self.label(of: $0)) } ?? "",
            isPresented: Binding(
                get: { unlinkingCodex != nil }, set: { if !$0 { unlinkingCodex = nil } }),
            presenting: unlinkingCodex
        ) { account in
            Button(CodexAccountLinkCopy.unlinkConfirm, role: .destructive) {
                model.engine.forgetCodexAccount(id: account.id)
            }
            Button(ClaudeAccountLinkCopy.cancel, role: .cancel) {}
        } message: { _ in
            Text(CodexAccountLinkCopy.unlinkMessage)
        }
        // The readiness poll stops once the scan is warm, so a window opened
        // afterwards would render whatever the last tick left behind.
        .task { model.engine.refreshProviders() }
    }

    /// Whether Sissy reads each vendor's own status page.
    ///
    /// It names the pages rather than describing them, for the reason the
    /// Files row names files: this is a request that leaves the Mac, and what
    /// it reaches is the part worth knowing before it is left on. What it
    /// carries is nothing — no account, no credential, no identity — which is
    /// why it can be on without being asked for.
    private var statusChecks: some View {
        LabeledContent {
            Toggle(ProviderStatusCopy.label, isOn: statusChecksBinding)
                .labelsHidden()
                .toggleStyle(.switch)
        } label: {
            HStack(spacing: 4) {
                Text(ProviderStatusCopy.label)
                SettingsInfoButton(
                    title: ProviderStatusCopy.infoTitle, detail: ProviderStatusCopy.detail)
            }
            Text(ProviderStatusCopy.caption)
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
        model.liveFrame?.frame.providers
            .first { $0.id == provider }?
            .signals.accounts
            .first { $0.id == account }
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
            case .link where provider == ProviderID.codex:
                model.engine.addCodexAccount()
            case .link:
                model.engine.addClaudeAccount()
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
            if let why = model.engine.claudeWebLinkFailure {
                failure(ClaudeAccountLinkCopy.failure(why))
            }
            ForEach(sortedAccounts) { account in
                linkedAccount(account)
            }
            CredentialAddRow(ClaudeAccountLinkCopy.addTitle) { model.engine.addClaudeAccount() }
        }
    }

    /// What the last attempt to link failed with, on a row of its own now that
    /// the caption it used to replace lives in the ⓘ.
    private func failure(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Ordered by the name they are drawn under rather than by the uuid they
    /// are keyed by, which is the order the engine deliberately does not have:
    /// the words are this layer's.
    ///
    /// The address breaks a tie, because one person holding two seats is the
    /// case this list exists for and their rows lead on the same word.
    private var sortedAccounts: [ClaudeWebAccount] {
        model.engine.linkedClaudeAccounts.sorted { lhs, rhs in
            let left = LinkedAccountRowSnapshot.make(lhs)
            let right = LinkedAccountRowSnapshot.make(rhs)
            return (left.title, left.address ?? "") < (right.title, right.address ?? "")
        }
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
        let row = LinkedAccountRowSnapshot.make(account)
        let signals = self.signals(of: account.id, provider: ProviderID.claudeCode)
        let plan = UsageFormat.plan(
            signals?.plan, tier: signals?.planTier, seat: signals?.account?.seat)
        return CredentialRow(
            title: row.title,
            badge: plan?.label,
            badgeTier: plan?.tier,
            subtitle: Self.subtitle(row),
            health: health(of: signals, provider: ProviderID.claudeCode),
            fix: fix(of: signals, provider: ProviderID.claudeCode)
        ) {
            CredentialMonogram(
                name: row.organization ?? row.title,
                tint: ProviderPalette.tint(for: ProviderID.claudeCode),
                health: health(of: signals, provider: ProviderID.claudeCode))
        } actions: {
            CredentialRowMenu(
                label: ClaudeAccountLinkCopy.unlink(Self.label(of: account)),
                help: ClaudeAccountLinkCopy.unlinkHelp
            ) {
                CredentialCopyButton(CredentialRowCopy.copyAddress, of: Self.label(of: account))
                Divider()
                Button(ClaudeAccountLinkCopy.unlinkItem, role: .destructive) {
                    unlinking = account
                }
            }
        }
    }

    /// The address and the organisation on one line, either of which can be
    /// the only one there — and neither, for a session filed before anything
    /// could name it.
    private static func subtitle(_ row: LinkedAccountRowSnapshot) -> String? {
        let parts = [row.address, row.organization].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Links another Codex account, which is the only way to read one the CLI
    /// is not signed into. Never disabled while the login window is up, for
    /// the reason the Claude one is not: a press is how someone gets back to a
    /// window that went behind.
    @ViewBuilder
    private var codexAccounts: some View {
        Group {
            ForEach(sortedCodexAccounts) { account in
                codexAccount(account)
            }
            CredentialAddRow(CodexAccountLinkCopy.addTitle) { model.engine.addCodexAccount() }
        }
    }

    /// Ordered by what the row is drawn under rather than by the id it is
    /// keyed by, which is the order the engine deliberately does not have.
    private var sortedCodexAccounts: [CodexLinkedAccount] {
        model.engine.linkedCodexAccounts.sorted {
            (Self.label(of: $0), $0.id) < (Self.label(of: $1), $1.id)
        }
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
        let title = Self.label(of: account)
        let workspace = account.link?.workspace.map(UsageFormat.workspaceLabel)
        let signals = self.signals(of: account.id, provider: ProviderID.codex)
        let plan = UsageFormat.plan(signals?.plan, tier: signals?.planTier)
        return CredentialRow(
            title: title,
            badge: plan?.label,
            badgeTier: plan?.tier,
            subtitle: workspace,
            health: health(of: signals, provider: ProviderID.codex),
            fix: fix(of: signals, provider: ProviderID.codex)
        ) {
            CredentialMonogram(
                name: workspace ?? title,
                tint: ProviderPalette.tint(for: ProviderID.codex),
                health: health(of: signals, provider: ProviderID.codex))
        } actions: {
            CredentialRowMenu(
                label: CodexAccountLinkCopy.unlink(title),
                help: CodexAccountLinkCopy.unlinkHelp
            ) {
                CredentialCopyButton(CredentialRowCopy.copyAddress, of: title)
                Divider()
                Button(CodexAccountLinkCopy.unlinkItem, role: .destructive) {
                    unlinkingCodex = account
                }
            }
        }
    }
}
