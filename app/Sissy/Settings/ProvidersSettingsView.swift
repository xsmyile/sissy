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
    static let label = "Linked accounts"
    static let addTitle = "Add account…"

    static let caption =
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
        }
    }
}

enum ClaudeAccountLinkCopy {
    static let label = "Linked accounts"
    static let addTitle = "Add account…"

    static let caption =
        "Sissy reads the account Claude Code is signed into for free. Linking another "
        + "signs in to claude.ai once, in a window that closes itself, and reads its "
        + "limits and credits beside it."

    static let chooseLabel = "Which organisation?"

    static func chooseCaption(_ email: String?) -> String {
        let account = email ?? "That account"
        return "\(account) has more than one. Sissy reads the one you pick, and keeps reading it."
    }

    static let unlinkHelp =
        "Forget this account's claude.ai session. The Claude Code sign-in Sissy archived "
        + "for it stays, so you can still switch to it."

    static func unlink(_ account: String) -> String { "Unlink \(account)" }

    static func unlinkTitle(_ account: String) -> String {
        "Forget the claude.ai session for \(account)?"
    }

    static let unlinkMessage =
        "Sissy stops reading this account's limits and credits from claude.ai. The Claude "
        + "Code sign-in it archived stays, so the account is still one you can switch to — "
        + "and you can link the session again from this window."

    static let unlinkConfirm = "Forget session"

    static let cancel = "Cancel"
    static let link = "Link"
    static let retry = "Try again"
    static let failureTitle = "Sissy could not link that account"
    static let working = "Linking…"

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

enum ClaudeLimitsSourceCopy {
    static let ownCredentialLabel = "Limits source"
    static let ownCredentialState = "This account's own sign-in"
    static let ownCredentialCaption =
        "Claude Code keeps its OAuth token in its own config directory, and it belongs to "
        + "whichever account is signed in there, so that is the account Sissy reads limits "
        + "for."
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
                        if model.engine.claudeUsesOwnCredential {
                            ownCredentialRow
                        }
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
            Toggle("Provider status", isOn: statusChecksBinding)
                .labelsHidden()
                .toggleStyle(.switch)
        } label: {
            Text("Provider status")
            Text(
                "Reads status.claude.com and status.openai.com so the panel can say "
                    + "whether it is you or them. No account, no sign-in."
            )
        }
    }

    private var statusChecksBinding: Binding<Bool> {
        Binding(
            get: { model.engine.statusChecks },
            set: { model.engine.setStatusChecks($0) }
        )
    }

    /// What is read when the CLI keeps its own credential: no keychain
    /// dialog, no cookie, and no grant that a re-signed build invalidates.
    private var ownCredentialRow: some View {
        LabeledContent {
            Text(ClaudeLimitsSourceCopy.ownCredentialState).foregroundStyle(.secondary)
        } label: {
            Text(ClaudeLimitsSourceCopy.ownCredentialLabel)
            Text(ClaudeLimitsSourceCopy.ownCredentialCaption)
        }
    }

    /// The vendor's line, the switch that decides whether Sissy reads it, and
    /// under both where it is reading and what it has found there.
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
            Label {
                Text(snapshot.name)
            } icon: {
                ProviderMark(id: readiness.id, size: Self.markSize, textSize: NSFont.systemFontSize)
            }
            Text(snapshot.detail)
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
        LabeledContent {
            Button(ClaudeAccountLinkCopy.addTitle) { model.engine.addClaudeAccount() }
        } label: {
            Text(ClaudeAccountLinkCopy.label)
            if let why = model.engine.claudeWebLinkFailure {
                Text(ClaudeAccountLinkCopy.failure(why))
            } else {
                Text(ClaudeAccountLinkCopy.caption)
            }
        }
        ForEach(sortedAccounts) { account in
            linkedAccount(account)
        }
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
    /// asks whether to forget "Davide Tacchini" when both rows say so is a
    /// destructive question nobody can answer. The address is unique by
    /// construction, which is the property this one call site needs.
    ///
    /// An account with no identity is one whose session was filed before
    /// anything could name it. Its uuid is a poor label and the only honest
    /// one — and a row under it is what makes that session removable.
    private static func label(of account: ClaudeWebAccount) -> String {
        account.identity.map(UsageFormat.accountLabel) ?? account.id
    }

    /// One linked account, with the control that unlinks it.
    ///
    /// A trash rather than a labelled button because the row already names
    /// what it acts on, and the whole list is one gesture repeated. What it
    /// deletes is the session and nothing else — the archived Claude Code
    /// sign-in beside it is not something the user linked, and Sissy cannot
    /// make another — which the help text says before the click rather than
    /// after it.
    private func linkedAccount(_ account: ClaudeWebAccount) -> some View {
        let row = LinkedAccountRowSnapshot.make(account)
        return LabeledContent {
            Button(role: .destructive) {
                unlinking = account
            } label: {
                Image(systemName: "trash").foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help(ClaudeAccountLinkCopy.unlinkHelp)
            .accessibilityLabel(ClaudeAccountLinkCopy.unlink(Self.label(of: account)))
        } label: {
            Self.title(row)
            if let organization = row.organization {
                Text(organization)
            }
        }
    }

    /// The title with the address trailing it, as one `Text` rather than a
    /// stack: `LabeledContent` styles the first view of its label as the title
    /// and everything after it as a caption, so a second view here would put
    /// the address on a line of its own under a name it belongs beside.
    ///
    /// Interpolated rather than concatenated — `Text.+` is deprecated as of
    /// macOS 26 — which is also what keeps the address in secondary text
    /// inside a title the form styles as a whole.
    private static func title(_ row: LinkedAccountRowSnapshot) -> Text {
        guard let address = row.address else { return Text(row.title) }
        let trailing = Text(address).foregroundStyle(.secondary)
        return Text("\(row.title)   \(trailing)")
    }

    /// Links another Codex account, which is the only way to read one the CLI
    /// is not signed into. Never disabled while the login window is up, for
    /// the reason the Claude one is not: a press is how someone gets back to a
    /// window that went behind.
    @ViewBuilder
    private var codexAccounts: some View {
        LabeledContent {
            Button(CodexAccountLinkCopy.addTitle) { model.engine.addCodexAccount() }
        } label: {
            Text(CodexAccountLinkCopy.label)
            Text(CodexAccountLinkCopy.caption)
        }
        ForEach(sortedCodexAccounts) { account in
            codexAccount(account)
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

    private func codexAccount(_ account: CodexLinkedAccount) -> some View {
        LabeledContent {
            Button(role: .destructive) {
                unlinkingCodex = account
            } label: {
                Image(systemName: "trash").foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help(CodexAccountLinkCopy.unlinkHelp)
            .accessibilityLabel(CodexAccountLinkCopy.unlink(Self.label(of: account)))
        } label: {
            Text(Self.label(of: account))
            if let workspace = account.link?.workspace {
                Text(UsageFormat.workspaceLabel(workspace))
            }
        }
    }
}
