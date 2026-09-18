import SwiftUI

/// What the forge controls say, in one place.
///
/// Separate from the view for the reason the account-link copy is: these are
/// the sentences that have to be right before a credential moves, and a test
/// can hold them without a window.
enum ForgeConnectCopy {
    static let label = "Contributions"
    static let caption = "Read your own activity counts from GitHub and GitLab"
    static let infoTitle = "What a connected forge is read for"
    static let detail =
        "Sissy reads two counters from each forge you connect — what you contributed and "
        + "what you had merged — with a token it keeps in a keychain item of its own. It "
        + "never writes to a repository and never changes what gh or glab hold."
    static let connect = "Connect…"
    static let disconnectItem = "Disconnect…"

    /// When this connection last answered, which with the login beside it is
    /// what says a connection is alive. Sissy's own fetch time rather than
    /// anything off the payload, the rule `ProviderStatusMonitor` follows.
    static func lastRead(_ readAt: Date, now: Date = Date()) -> String {
        "read " + UsageFormat.age(now.timeIntervalSince(readAt))
    }
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

/// What each of a forge row's counters is called where it has a switch.
///
/// The words are neutral between the two forges, which the panel's own hover
/// text is not: there it says "pull requests" to GitHub and "merge requests"
/// to GitLab, because it is on a row that belongs to one of them. A switch
/// governs every row at once, so it has to name the thing both vendors have.
///
/// There is no entry for the contribution total. It is what the section on the
/// panel is called, so a row with it switched off would be a heading with
/// nothing under it — and the switch would be asking the user to keep a block
/// they had just emptied.
enum ForgeCounterCopy {
    static let section = "Shown on each row"

    static func title(_ counter: ForgeCounter) -> String {
        switch counter {
        case .merged: "Merged requests"
        case .issues: "Opened issues"
        case .comments: "Comments"
        }
    }

    /// What the figure counts, and — where it is not free — that switching it
    /// off is also a decision about what Sissy asks the vendor for.
    static func caption(_ counter: ForgeCounter) -> String {
        switch counter {
        case .merged: "Pull and merge requests you opened and had merged"
        case .issues: "Issues you opened"
        case .comments: "Comments you wrote on issues and requests"
        }
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
                heading
                ForEach(model.engine.forgeConnections) { connection in
                    row(connection)
                }
                CredentialAddRow(ForgeConnectCopy.connect) { adding = true }
                    .disabled(model.engine.connectingForge != nil)
            }
            Section(ForgeCounterCopy.section) {
                ForEach(ForgeCounter.allCases, id: \.self) { counter in
                    counterRow(counter)
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

    /// What this tab is for, over the list rather than beside a button: with no
    /// switch to explain, there is no control for a caption to sit next to.
    /// The paragraph it used to carry is in the ⓘ.
    private var heading: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(ForgeConnectCopy.label).font(.headline)
                SettingsInfoButton(
                    title: ForgeConnectCopy.infoTitle, detail: ForgeConnectCopy.detail)
            }
            Text(ForgeConnectCopy.caption)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One connected forge, in the row shape a linked account takes: both are
    /// a credential the user added, and two shapes for them would be two
    /// places for the same reading to be drawn differently.
    ///
    /// It leads on the host rather than on the vendor's name: two GitLabs are
    /// told apart by their host and never by "GitLab", and the mark in the
    /// disc already says which vendor it is. Under it goes the login the
    /// **API** answered with — not the one `gh` has written down — which is
    /// the only thing on the row that says whose counts these are.
    private func row(_ connection: ForgeConnection) -> some View {
        let reading = model.liveFrame?.frame.forge.first { $0.id == connection.id }
        return CredentialRow(
            title: connection.host,
            subtitle: subtitle(connection, reading: reading),
            health: Self.health(of: reading)
        ) {
            CredentialDisc(tint: .secondary, health: Self.health(of: reading)) {
                ForgeMark(host: connection.host)
            }
        } actions: {
            CredentialRowMenu(
                label: ForgeConnectCopy.unlink(connection),
                help: ForgeConnectCopy.unlinkHelp
            ) {
                CredentialCopyButton(CredentialRowCopy.copyHost, of: connection.host)
                Divider()
                Button(ForgeConnectCopy.disconnectItem, role: .destructive) {
                    disconnecting = connection
                }
            }
        }
    }

    /// Who the token turned out to belong to, and when it last answered — the
    /// two facts that say a connection is alive, where the row used to print
    /// the host it is already titled by.
    private func subtitle(
        _ connection: ForgeConnection, reading: ForgeActivityReading?
    ) -> String? {
        if model.engine.connectingForge == connection.id { return ForgeConnectCopy.connecting }
        guard let reading else { return nil }
        let read = ForgeConnectCopy.lastRead(reading.readAt)
        guard let login = reading.login else { return read }
        return "\(login) · \(read)"
    }

    /// Whether the last poll worked, in `UsageFormat.forgeFailure`'s own words.
    ///
    /// The reason rather than the panel's caption, which now dates every row
    /// it draws: a healthy connection would otherwise reach this as
    /// "read 4m ago" and be filed as something needing attention.
    private static func health(of reading: ForgeActivityReading?) -> CredentialHealth {
        guard let failure = reading?.failure else { return .ok }
        return .attention(UsageFormat.forgeFailure(failure))
    }

    /// One counter's switch, wearing the mark the panel draws it with.
    ///
    /// The mark is on the label rather than only the words, because the row it
    /// governs has no words at all — the panel spends a glyph where it cannot
    /// spend seven characters, so the switch that turns that glyph off is the
    /// one place the two can be seen to be the same thing.
    ///
    /// A switch rather than the checkbox a `Toggle` renders as by default in a
    /// grouped `Form`, which is what every other control in this window is:
    /// these rows say whether something is on, and a window that answered that
    /// question two ways would be asking the reader which one meant what. The
    /// title goes to the `Toggle` and is then hidden, so the control the
    /// pointer lands on is still named for the reader who cannot see the label
    /// beside it.
    private func counterRow(_ counter: ForgeCounter) -> some View {
        LabeledContent {
            Toggle(
                ForgeCounterCopy.title(counter),
                isOn: Binding(
                    get: { model.engine.forgeCounters[counter] ?? true },
                    set: { model.engine.setForgeCounter(counter, $0) })
            )
            .labelsHidden()
            .toggleStyle(.switch)
        } label: {
            Label {
                Text(ForgeCounterCopy.title(counter))
            } icon: {
                Image(systemName: ProviderPalette.forgeSymbol(counter))
                    .foregroundStyle(ProviderPalette.forgeTint(counter))
            }
            Text(ForgeCounterCopy.caption(counter))
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
