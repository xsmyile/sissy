import SwiftUI

/// What the forge controls say, in one place.
///
/// Separate from the view for the reason the account-link copy is: these are
/// the sentences that have to be right before a credential moves, and a test
/// can hold them without a window.
enum ForgeConnectCopy {
    static let label = "Contributions"
    static let caption = "Read your own activity counts from GitHub and GitLab"
    static let connect = "Connect…"
    static let sheetTitle = "Connect a forge"
    static let detected = "Tokens already on this Mac"
    static let orPaste = "Or paste one"
    static let hostPrompt = "Host"
    static let tokenPrompt = "Token"
    static let cancel = "Cancel"
    static let confirm = "Connect"
    static let connecting = "Connecting…"
    /// Named for what failed rather than for the status behind it: both halves
    /// of a connect are local writes, so there is nothing about a forge to
    /// report and nothing the user can do but try again.
    static let connectFailed =
        "The keychain would not accept the token, so nothing was connected. The token is still in the field — try again."

    /// What a detected candidate offers, naming the CLI it came from.
    ///
    /// The CLI is named because the token is that CLI's: someone who signs out
    /// of `gh` tomorrow should know that what Sissy holds is a copy taken now
    /// rather than a live reference to it.
    static func candidate(_ candidate: ForgeTokenCandidate) -> String {
        let tool = candidate.kind == .gitHub ? "gh" : "glab"
        return "\(UsageFormat.forgeName(candidate.kind)) · \(candidate.host)   (from \(tool))"
    }

    /// The scope warning, which is not optional copy.
    ///
    /// Measured 2026-09-17, the token `gh` holds on this Mac carries
    /// `admin:public_key, gist, read:org, repo` — write access to every
    /// repository — for a feature that reads two counters. A user who would
    /// rather mint a read-only token has to be told that before they press the
    /// convenient button, not after.
    static let scopeWarning = """
        Sissy copies the token into its own keychain item and only ever reads \
        activity counts with it. It never writes to a repository and never \
        changes what gh or glab hold. A token from those tools carries whatever \
        scopes you gave them — often write access to every repository — so a \
        read-only token you mint yourself is the narrower choice.
        """

    static func unlinkTitle(_ connection: ForgeConnection) -> String {
        "Disconnect \(UsageFormat.forgeName(connection.kind)) · \(connection.host)?"
    }

    static let unlinkMessage =
        "Sissy deletes the token it holds and stops reading the counts. Nothing about gh, glab or the forge itself changes."
    static let unlinkConfirm = "Disconnect"
    static let unlinkHelp = "Delete the token Sissy holds and stop reading this forge"

    static func unlink(_ connection: ForgeConnection) -> String {
        "Disconnect \(UsageFormat.forgeName(connection.kind)) on \(connection.host)"
    }
}

/// The forges the user has connected, and the control that adds one.
///
/// **A tab rather than a section under the metering providers**, which is
/// where it lived until 0.1.10. The rule that kept it a section — a tab is
/// earned by a module, not by a long section — is what moves it now: forge is
/// a module rather than one row, with `ForgeActivityMonitor` polling two
/// counters per connection and `GitIdentityMonitor` reading a commit identity
/// per repository beside it. Under the providers it also read as a third way
/// to meter, which it is not: a connection here buys an activity count, never
/// a token and never a cost, and the two are never summed.
///
/// **There is no on/off switch, and that is the design.** A connection is the
/// switch: with none, nothing here makes a request, which is the rule a module
/// that is off must not exist as far as the system is concerned. Asking the
/// user to both connect a forge and then arm it would be the same decision
/// twice.
///
/// What is deliberately **not** here is what `GitIdentityMonitor` reads. That
/// is a reading with no lever on it, where every row in this window is a
/// control, so it stays a page of the panel — a tab does not earn a second
/// surface for it, and inventing a switch to fill this one would be the
/// reasoning backwards.
///
/// One button rather than a menu of detected tokens, so that reading what
/// `gh` and `glab` hold happens on a press and demonstrably nowhere else: a
/// keychain call and a file read must not happen because a window was shown,
/// and `Menu` gives no promise about when it builds its contents. The sheet
/// behind the button carries both roads.
struct ForgeSettingsView: View {
    let model: SissyModel

    /// The forge a trash was pressed for. What it deletes is a token the user
    /// cannot read back and never typed, so the click is asked about first.
    @State private var disconnecting: ForgeConnection?
    /// Whether the connect sheet is up.
    @State private var adding = false

    var body: some View {
        Form {
            Section {
                connect
                ForEach(model.engine.forgeConnections) { connection in
                    row(connection)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $adding) {
            ForgeConnectSheet(model: model, isPresented: $adding)
        }
        .confirmationDialog(
            disconnecting.map(ForgeConnectCopy.unlinkTitle) ?? "",
            isPresented: Binding(
                get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
            presenting: disconnecting
        ) { connection in
            Button(ForgeConnectCopy.unlinkConfirm, role: .destructive) {
                model.engine.disconnectForge(id: connection.id)
            }
            Button(ForgeConnectCopy.cancel, role: .cancel) {}
        } message: { _ in
            Text(ForgeConnectCopy.unlinkMessage)
        }
    }

    private var connect: some View {
        LabeledContent {
            Button(ForgeConnectCopy.connect) { adding = true }
                .disabled(model.engine.connectingForge != nil)
        } label: {
            Text(ForgeConnectCopy.label)
            Text(ForgeConnectCopy.caption)
        }
    }

    private func row(_ connection: ForgeConnection) -> some View {
        LabeledContent {
            Button(role: .destructive) {
                disconnecting = connection
            } label: {
                Image(systemName: "trash").foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help(ForgeConnectCopy.unlinkHelp)
            .accessibilityLabel(ForgeConnectCopy.unlink(connection))
        } label: {
            Text(UsageFormat.forgeName(connection.kind))
            Text(
                model.engine.connectingForge == connection.id
                    ? ForgeConnectCopy.connecting : connection.host)
        }
    }
}

/// Connecting a forge: the tokens this Mac already holds, or one pasted by
/// hand.
///
/// **Both roads are on one surface, and the surface only exists after a
/// press.** The detected tokens are read in `task` — off the main actor, since
/// `gh`'s is a subprocess away — so that keychain item and `glab`'s
/// configuration file are touched when the user asks to connect something and
/// at no other time — not when the tab is shown, and not because
/// a menu decided to build its contents. That timing is the rule every
/// credential in this app is acquired under, and putting the read where a sheet
/// appears is what makes it true by construction rather than by a claim about
/// when SwiftUI evaluates a `Menu`.
///
/// The hand-typed road exists so the convenient one is never the only one. A
/// self-hosted GitLab cannot be reached by an OAuth app Sissy ships — there is
/// no application to register on someone else's instance — and a user who wants
/// a read-only fine-grained token has nowhere else to put one.
struct ForgeConnectSheet: View {
    let model: SissyModel
    @Binding var isPresented: Bool

    @State private var candidates: [ForgeTokenCandidate] = []
    @State private var kind: ForgeKind = .gitHub
    @State private var host: String = GitHubActivityFeed.dotComHost
    @State private var token: String = ""

    private static let fieldWidth: CGFloat = 260
    private static let sheetWidth: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ForgeConnectCopy.sheetTitle).font(.headline)
            if !candidates.isEmpty {
                Text(ForgeConnectCopy.detected)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(candidates) { candidate in
                    Button(ForgeConnectCopy.candidate(candidate)) {
                        model.engine.connectForge(candidate.connection, token: candidate.token)
                    }
                    .disabled(busy)
                }
                Divider()
                Text(ForgeConnectCopy.orPaste)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Picker("Forge", selection: $kind) {
                ForEach(ForgeKind.allCases, id: \.self) { kind in
                    Text(UsageFormat.forgeName(kind)).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: kind) { _, new in
                guard new == .gitHub else { return }
                host = GitHubActivityFeed.dotComHost
            }
            TextField(ForgeConnectCopy.hostPrompt, text: $host)
                .frame(width: Self.fieldWidth)
            SecureField(ForgeConnectCopy.tokenPrompt, text: $token)
                .frame(width: Self.fieldWidth)
            Text(ForgeConnectCopy.scopeWarning)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failure = model.engine.forgeConnectFailure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(ForgeConnectCopy.cancel) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(busy ? ForgeConnectCopy.connecting : ForgeConnectCopy.confirm) {
                    model.engine.connectForge(
                        ForgeConnection(kind: kind, host: trimmedHost), token: token)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || trimmedHost.isEmpty || typedToken.isEmpty)
            }
        }
        .padding(20)
        .frame(width: Self.sheetWidth)
        .task { candidates = await model.engine.forgeTokenCandidates() }
        // Dismiss on the attempt *finishing well*, never on the press: the
        // token is only in this window, so a failed write has to leave the
        // window standing with the field still in it.
        .onChange(of: model.engine.connectingForge) { previous, current in
            guard previous != nil, current == nil,
                model.engine.forgeConnectFailure == nil
            else { return }
            isPresented = false
        }
    }

    private var busy: Bool { model.engine.connectingForge != nil }

    private var typedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var trimmedHost: String { ForgeConnection.host(from: host) }
}
