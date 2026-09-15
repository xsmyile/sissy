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

/// Where each provider's numbers come from, and what it is doing about them.
struct ProvidersSettingsView: View {
    let model: SissyModel

    @State private var showingWebSessionDetail = false

    private static let markSize: CGFloat = 18
    /// Wide enough for a four-figure plan price and no wider — the field sits
    /// at the trailing edge of a Form row, where a full-width one reads as a
    /// text box for prose.
    private static let planPriceFieldWidth: CGFloat = 72
    /// Wide enough that the detail reads as a paragraph rather than a column.
    private static let detailPopoverWidth: CGFloat = 280

    var body: some View {
        Form {
            ForEach(model.engine.providers, id: \.id) { readiness in
                Section {
                    row(readiness)
                    planPrice(readiness)
                    if readiness.id == ProviderID.claudeCode {
                        if model.engine.claudeUsesOwnCredential {
                            ownCredentialRow
                        } else {
                            claudeWebSession
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        // The readiness poll stops once the scan is warm, so a window opened
        // afterwards would render whatever the last tick left behind.
        .task { model.engine.refreshProviders() }
    }

    /// What this provider's subscription costs a month, typed by the user.
    ///
    /// Typed, and never shipped. Plan prices differ by country, by seat and
    /// by promotion, so a table in the binary would be the same regression as
    /// a rate table and a slower one to notice, because nobody cross-checks a
    /// figure Sissy invented. Empty is the ordinary state and costs nothing:
    /// the month still prints what the usage came to, it just does not say
    /// what it was measured against.
    @ViewBuilder
    private func planPrice(_ readiness: ProviderReadiness) -> some View {
        LabeledContent("Plan price") {
            HStack(spacing: 4) {
                Text(verbatim: "$")
                    .foregroundStyle(.secondary)
                TextField(
                    "Plan price",
                    text: planPriceBinding(readiness.id),
                    prompt: Text(verbatim: "0.00")
                )
                .labelsHidden()
                .frame(width: Self.planPriceFieldWidth)
                .multilineTextAlignment(.trailing)
            }
        }
        Text(planPriceCaption(readiness.id))
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    /// The caption says what was understood rather than only what to type.
    ///
    /// A value the parser refuses would otherwise fail in silence: the field
    /// keeps the text, `server.json` keeps the text, and the panel simply
    /// never grows the comparison — leaving somebody to conclude the feature
    /// is broken. Reading the amount back is also the only way to be sure
    /// which separator was taken as the decimal one.
    private func planPriceCaption(_ id: String) -> String {
        let base =
            "US dollars a month, which is the currency Sissy prices tokens in — a plan billed "
            + "in another one has to be converted, because a rate Sissy invented would be wrong "
            + "by the time you read it."
        let typed = model.engine.planPrices[id] ?? ""
        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else {
            return base + " Leave it empty and the panel shows the month's usage with nothing "
                + "to compare it to."
        }
        guard let parsed = ServerConfig.parsePlanPrice(typed) else {
            return "Not a price Sissy can read, so the panel shows the month's usage on its own. "
                + "Digits and at most one decimal separator — 200, 200.50 or 200,50. "
                + "A thousands separator is refused because 1,234 means two different amounts "
                + "to two readers."
        }
        return base + " Read as \(UsageFormat.cost(parsed)) a month."
    }

    private func planPriceBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { model.engine.planPrices[id] ?? "" },
            set: { model.setPlanPrice($0, forProvider: id) }
        )
    }

    /// What is read when the CLI keeps its own credential: no keychain
    /// dialog, no cookie, and no grant that a re-signed build invalidates.
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

    /// The vendor's line, and under it where Sissy is reading and what it has
    /// found there.
    @ViewBuilder
    private func row(_ readiness: ProviderReadiness) -> some View {
        let snapshot = ProviderRowSnapshot.make(readiness)
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
    }

    /// Shown only when the CLI keeps no credential Sissy can read, which is a
    /// CLI nobody has signed into. Otherwise there is nothing to import: the
    /// limits already come from the account that is signed in.
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
