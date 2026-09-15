import AppKit
import SwiftUI

/// What one provider's row says. A pure function of the readiness so the
/// wording is testable without a running engine — the same shape
/// `SissyModel.HeaderSnapshot` uses for the panel header.
struct ProviderRowSnapshot: Equatable {
    let name: String
    let state: String
    let detail: String

    static func make(_ readiness: ProviderReadiness, sharesVendor: Bool = false) -> Self {
        Self(
            name: sharesVendor
                ? UsageFormat.providerName(readiness.id, named: readiness.label)
                : UsageFormat.providerName(readiness.id),
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
        case .off: return "Switched off in server.json"
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

/// What the Claude Code limits switch says about itself.
///
/// Split because the two halves are not equally urgent. `caption` carries the
/// only two facts that change what someone does — what the switch shows, and
/// that macOS will ask — and stays on screen, because a permission prompt this
/// app did not warn about is the thing Sissy's first-run promise exists to
/// avoid. `detail` is the reassurance and the after-an-update expectation:
/// worth keeping, not worth four permanent lines.
enum ClaudeLimitsCopy {
    static let title = "Show Claude Code limits"

    static let caption =
        "Shows Claude Code's 5-hour and weekly windows next to Codex's. "
        + "macOS will ask for your permission."

    static let detail =
        "Sissy reads the token Claude Code already keeps in your keychain — only ever "
        + "reads it, never writes or refreshes it. That permission is tied to Sissy's own "
        + "binary, so it lapses after an update. Sissy never asks again on its own: the "
        + "limits go quiet instead, and switching this off and back on is what asks for "
        + "them."

    /// What the button reads as to a screen reader, where the glyph says
    /// nothing — the one reader who cannot see an `info.circle` and guess.
    static let detailButtonLabel = "What Sissy reads"
}

/// The claude.ai session, and what importing it changes.
///
/// It says what the thing is before the button is pressed, because it is a
/// whole browser session rather than a read-only usage token, and a user who
/// only finds that out afterwards was not asked.
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
        + "the limits of the account the row is about. Nothing is read from the keychain "
        + "and no claude.ai session is needed."

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

/// What the accounts section says.
enum AccountsCopy {
    static let header = "Accounts"
    static let addClaude = "Add a Claude account…"
    static let addCodex = "Add a Codex account…"
    static let removeTitle = "Stop metering"
    static let removeLabel = "This account"
    static let choosePrompt = "Use as account"

    static let caption =
        "An account is the directory its CLI keeps everything in — the session logs, "
        + "the plan, the credential the limits are read with. Point Sissy at a second "
        + "one and it meters that account on its own row, with its own limits. "
        + "The CLI has to be told to use it too: run Claude Code with "
        + "CLAUDE_CONFIG_DIR set to that directory, or Codex with CODEX_HOME."

    static func chooseMessage(vendor: String) -> String {
        vendor == ProviderID.codex
            ? "Choose the CODEX_HOME directory of the account to meter."
            : "Choose the CLAUDE_CONFIG_DIR directory of the account to meter."
    }
}

/// Where each provider's numbers come from, and what it is doing about them.
struct ProvidersSettingsView: View {
    let model: SissyModel

    @State private var showingLimitsDetail = false
    @State private var showingWebSessionDetail = false

    private static let markSize: CGFloat = 18
    /// Wide enough that the detail reads as a paragraph rather than a column.
    private static let detailPopoverWidth: CGFloat = 280

    var body: some View {
        Form {
            ForEach(model.engine.providers, id: \.id) { readiness in
                Section {
                    row(readiness)
                    // Under the vendor's first account only: the switch is the
                    // CLI's, not an account's, and the imported session belongs
                    // to whichever account Claude.app holds. Repeating them
                    // under a second account would offer two controls for one
                    // setting and imply the session could be that account's.
                    if isFirstOfVendor(readiness), vendor(of: readiness) == ProviderID.claudeCode {
                        claudeLimits
                        // The imported session is only offered when something
                        // would read it. With the CLI's own credential in
                        // place nothing does, and a control over a source that
                        // is not running is a setting that lies.
                        if model.engine.claudeLimits {
                            if model.engine.claudeUsesOwnCredential {
                                ownCredentialRow
                            } else {
                                claudeWebSession
                            }
                        }
                    }
                    if let account = ProviderKey(id: readiness.id).account {
                        removeButton(account: account, vendor: vendor(of: readiness))
                    }
                }
            }
            accountsSection
        }
        .formStyle(.grouped)
        // The readiness poll stops once the scan is warm, so a window opened
        // afterwards would render whatever the last tick left behind.
        .task { model.engine.refreshProviders() }
    }

    private func vendor(of readiness: ProviderReadiness) -> String {
        ProviderKey.vendor(of: readiness.id)
    }

    /// Whether this is the first row of its vendor, which is where the
    /// vendor-wide controls belong.
    private func isFirstOfVendor(_ readiness: ProviderReadiness) -> Bool {
        model.engine.providers.first { vendor(of: $0) == vendor(of: readiness) }?.id == readiness.id
    }

    /// Adding an account, and the one thing a user has to do outside Sissy for
    /// it to mean anything.
    ///
    /// Both CLIs keep an account's whole state — its logs, its credential, its
    /// profile — under one directory, and that directory is what Sissy is
    /// being pointed at. A home nothing has ever run against is an empty row,
    /// so the caption says which variable puts a session there rather than
    /// leaving someone to find out from an account that never fills in.
    /// What is read when the CLI keeps its own credential: no keychain, no
    /// cookie, no grant to go stale, and an answer that belongs to this
    /// account rather than to whoever else is signed in on this Mac.
    @ViewBuilder
    private var ownCredentialRow: some View {
        LabeledContent {
            Text(ClaudeWebSessionCopy.ownCredentialState).foregroundStyle(.secondary)
        } label: {
            Text(ClaudeWebSessionCopy.ownCredentialLabel)
        }
        Text(ClaudeWebSessionCopy.ownCredentialCaption)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var accountsSection: some View {
        Section {
            Button(AccountsCopy.addClaude) { addAccount(vendor: ProviderID.claudeCode) }
            Button(AccountsCopy.addCodex) { addAccount(vendor: ProviderID.codex) }
            Text(AccountsCopy.caption)
                .font(.callout)
                .foregroundStyle(.secondary)
        } header: {
            Text(AccountsCopy.header)
        }
    }

    @ViewBuilder
    private func removeButton(account: String, vendor: String) -> some View {
        LabeledContent {
            Button(AccountsCopy.removeTitle, role: .destructive) {
                model.engine.removeAccount(id: account, vendor: vendor)
            }
        } label: {
            Text(AccountsCopy.removeLabel)
        }
    }

    /// Picks the account's config home and starts metering it.
    ///
    /// A directory chooser rather than a text field because the value is a
    /// path that has to exist, and because the panel is also how a user
    /// discovers that an account *is* a directory.
    private func addAccount(vendor: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = AccountsCopy.choosePrompt
        panel.message = AccountsCopy.chooseMessage(vendor: vendor)
        guard panel.runModal() == .OK, let home = panel.url else { return }
        model.engine.addAccount(vendor: vendor, home: home, label: home.lastPathComponent)
    }

    @ViewBuilder
    private func row(_ readiness: ProviderReadiness) -> some View {
        let snapshot = ProviderRowSnapshot.make(
            readiness,
            sharesVendor: model.engine.providers.filter { vendor(of: $0) == vendor(of: readiness) }
                .count > 1
        )
        LabeledContent {
            Text(snapshot.state).foregroundStyle(.secondary)
        } label: {
            Label {
                Text(snapshot.name)
            } icon: {
                ProviderMark(id: readiness.id, size: Self.markSize, textSize: NSFont.systemFontSize)
            }
        }
        Text(snapshot.detail)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private var claudeLimits: some View {
        LabeledContent {
            Toggle(ClaudeLimitsCopy.title, isOn: claudeLimitsBinding)
                .labelsHidden()
                .toggleStyle(.switch)
        } label: {
            HStack(spacing: 4) {
                Text(ClaudeLimitsCopy.title)
                detailButton
            }
        }
        Text(ClaudeLimitsCopy.caption)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    /// A button rather than a `help` tooltip: a tooltip is reachable only by
    /// hovering a pointer over it, and this is the one control on the page
    /// whose consequences someone may want to read before flipping it.
    private var detailButton: some View {
        Button {
            showingLimitsDetail = true
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(ClaudeLimitsCopy.detailButtonLabel)
        .popover(isPresented: $showingLimitsDetail, arrowEdge: .bottom) {
            Text(ClaudeLimitsCopy.detail)
                .font(.callout)
                .frame(width: Self.detailPopoverWidth)
                .padding()
        }
    }

    private var claudeLimitsBinding: Binding<Bool> {
        Binding(
            get: { model.engine.claudeLimits },
            set: { model.setClaudeLimits($0) }
        )
    }

    /// Shown only under a switch that is already on: importing a session for
    /// limits nobody asked to see would be a permission with nothing behind
    /// it.
    @ViewBuilder
    private var claudeWebSession: some View {
        LabeledContent {
            HStack(spacing: 8) {
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
            }
        } label: {
            HStack(spacing: 4) {
                Text(
                    model.engine.claudeWebSession
                        ? ClaudeWebSessionCopy.importedLabel
                        : ClaudeWebSessionCopy.importTitle)
                webSessionDetailButton
            }
        }
        if let why = model.engine.claudeWebImportFailure {
            Text(ClaudeWebSessionCopy.failure(why))
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if !model.engine.claudeWebSession {
            Text(ClaudeWebSessionCopy.caption)
                .font(.callout)
                .foregroundStyle(.secondary)
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
