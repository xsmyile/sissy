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
        }
    }
}

enum ClaudeWebSessionCopy {
    static let importTitle = "Import from Claude.app"
    static let forgetTitle = "Forget session"
    static let importedLabel = "Reading claude.ai"

    static let caption =
        "Claude Code's own reading only updates when you type /usage. Importing the "
        + "session Claude.app is signed in with keeps the windows and the credits live."

    static let detail =
        "Sissy copies the claude.ai session cookie out of Claude.app into a keychain item "
        + "of its own, and reads it back from there. macOS asks once, when you press "
        + "Import — Claude.app's key has not changed since 2024, so the permission is not "
        + "asked for again. The cookie is a whole claude.ai session, not a read-only "
        + "usage token: it never leaves this Mac except as a request to claude.ai, and it "
        + "is not in the logs, the diagnostics or the export. Forget deletes it."

    static let detailButtonLabel = "What importing does"

    static let ownCredentialLabel = "Limits source"
    static let ownCredentialState = "This account's own sign-in"
    static let ownCredentialCaption =
        "Claude Code keeps its OAuth token in each account's own directory, so Sissy reads "
        + "that account's own limits."

    /// One sentence per way the import can come up empty, each naming what to
    /// do rather than what failed.
    static func failure(_ why: ClaudeWebCookieImport.Failure) -> String {
        switch why {
        case .noStore:
            return "Claude.app is not installed on this Mac."
        case .noSession:
            return "Claude.app is installed but not signed in."
        case .noKey:
            return "macOS did not let Sissy read Claude.app's key. Try Import again."
        case .unreadableStore:
            return "Claude.app's cookie store could not be read."
        case .undecryptable:
            return "Claude.app's cookies are in a format this version does not read."
        }
    }
}

/// Where each provider's numbers come from, and what it is doing about them.
struct ProvidersSettingsView: View {
    let model: SissyModel

    @State private var showingWebSessionDetail = false

    private static let markSize: CGFloat = 18
    /// Wide enough that the detail reads as a paragraph rather than a column.
    private static let detailPopoverWidth: CGFloat = 280

    var body: some View {
        Form {
            ForEach(model.engine.providers, id: \.id) { readiness in
                Section {
                    row(readiness)
                    // Only under a Claude Code that is being metered. Where
                    // it is not there is no limits probe to hand a session to
                    // and no slice for the windows to ride on, so the import
                    // would raise Claude.app's dialog to change nothing —
                    // which is the one thing a permission prompt may never do.
                    if readiness.id == ProviderID.claudeCode, readiness.activation.isMetering {
                        if model.engine.claudeUsesOwnCredential {
                            ownCredentialRow
                        } else {
                            claudeWebSession
                        }
                        linkedAccounts
                    }
                }
            }
            Section {
                statusChecks
            }
        }
        .formStyle(.grouped)
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
            Text(ClaudeWebSessionCopy.ownCredentialState).foregroundStyle(.secondary)
        } label: {
            Text(ClaudeWebSessionCopy.ownCredentialLabel)
            Text(ClaudeWebSessionCopy.ownCredentialCaption)
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

    /// Shown only when the CLI keeps no credential Sissy can read, which is a
    /// CLI nobody has signed into. Otherwise there is nothing to import: the
    /// limits already come from the account that is signed in.
    private var claudeWebSession: some View {
        LabeledContent {
            if model.engine.claudeWebSession {
                Button(ClaudeWebSessionCopy.forgetTitle) {
                    model.engine.forgetClaudeWebSession()
                }
            } else {
                Button(ClaudeWebSessionCopy.importTitle) {
                    model.engine.importClaudeWebSession()
                }
                .disabled(model.engine.importingClaudeWebSession)
            }
        } label: {
            HStack(spacing: 4) {
                Text(
                    model.engine.claudeWebSession
                        ? ClaudeWebSessionCopy.importedLabel
                        : ClaudeWebSessionCopy.importTitle)
                webSessionDetailButton
            }
            if let why = model.engine.claudeWebImportFailure {
                Text(ClaudeWebSessionCopy.failure(why))
            } else if !model.engine.claudeWebSession {
                Text(ClaudeWebSessionCopy.caption)
            }
        }
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
    }

    private var webSessionDetailButton: some View {
        Button {
            showingWebSessionDetail = true
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(ClaudeWebSessionCopy.detailButtonLabel)
        .popover(isPresented: $showingWebSessionDetail, arrowEdge: .bottom) {
            Text(ClaudeWebSessionCopy.detail)
                .font(.callout)
                .frame(width: Self.detailPopoverWidth)
                .padding()
        }
    }
}
