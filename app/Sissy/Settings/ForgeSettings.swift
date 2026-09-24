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
        "Sissy reads two counters from each forge you connect: what you contributed and "
        + "what you had merged, using a token it keeps in a keychain item of its own. It "
        + "never writes to a repository and never changes what gh or glab hold."
    static let connect = "Connect…"
    static let disconnectItem = "Disconnect…"
    static let reconnectItem = "Reconnect…"
    static let allowItem = "Allow"

    /// When this connection last answered, which with the login beside it is
    /// what says a connection is alive. Sissy's own fetch time rather than
    /// anything off the payload, the rule `ProviderStatusMonitor` follows.
    static func lastRead(_ readAt: Date, now: Date = Date()) -> String {
        "read " + UsageFormat.age(now.timeIntervalSince(readAt))
    }
    static let sheetTitle = "Connect a forge"
    static let detected = "Tokens already on this Mac"

    /// What the sheet is called when it was opened to replace one connection's
    /// token rather than to add a connection.
    static func reconnectTitle(_ connection: ForgeConnection) -> String {
        "Reconnect \(connection.address)"
    }

    /// The heading over the one candidate a reconnection may offer.
    ///
    /// It names both CLIs and the *now*, because that is the whole reason this
    /// road exists: what `gh` holds today is not what Sissy copied out of it,
    /// and a token re-minted since the connection was made is the case a
    /// reconnection answers.
    static let detectedForHost = "What gh or glab holds for this host now"
    static let orPaste = "Or paste one"
    static let hostPrompt = "Host"

    /// Said under a host typed with `http://`, which is asked over https.
    static let askedOverHTTPS =
        "Sissy asks every forge over https, so the token never travels in the clear."

    static let pathPrompt = "Path, if served under one (optional)"
    static let tokenPrompt = "Token"
    static let cancel = "Cancel"
    static let confirm = "Connect"
    static let reconnectConfirm = "Reconnect"
    static let connecting = "Connecting…"
    static let connectAnyway = "Connect Anyway"
    /// Named for what failed rather than for the status behind it: the forge
    /// has already answered by the time this is said, so what failed is a
    /// local write and there is nothing the user can do but try again.
    static let connectFailed =
        "Sissy could not save the token or the connection, so nothing was connected. The token is still in the field. Try again."

    /// Said when a connect stops because the connection index would not read:
    /// whether the token replaces one it names cannot be told, so it is not
    /// sent anywhere.
    static let indexUnreadableOnConnect =
        "Sissy could not read its list of connected forges, so nothing was saved. The token is still in the field."

    /// What a connect attempt came to, nil for one that connected.
    ///
    /// A refusal names the address and says nothing was saved, because the
    /// probe runs before anything is written: the token has not left the
    /// field, and the user is told which of the host, the token or the network
    /// to look at rather than finding a failure on the row afterwards.
    static func failure(_ outcome: ForgeConnector.Outcome, connection: ForgeConnection) -> String? {
        let forge = UsageFormat.forgeName(connection.kind)
        let address = connection.address
        switch outcome {
        case .connected:
            return nil
        case .notFiled:
            return connectFailed
        case .indexUnreadable:
            return indexUnreadableOnConnect
        case .withdrawn:
            return "\(address) was disconnected while \(forge) was being asked, so nothing was saved."
        case .refused(.unauthorized):
            return "\(forge) at \(address) refused the token, so nothing was saved. "
                + "Check the token and its scopes."
        case .refused(.unreachable):
            return "\(address) could not be reached, so nothing was saved · "
                + "check the host, the network or the VPN. "
                + "Connect Anyway saves it, and Sissy reads it once it answers."
        case .refused(.malformed):
            return "\(address) did not answer as \(forge), so nothing was saved. "
                + "Check the forge, the host, the port and the path."
        case .refused(.redirected):
            return "\(address) sent Sissy to another host, so nothing was saved. "
                + "A sign-in proxy in front of the forge does this."
        case .refused(.rateLimited):
            return "\(forge) asked Sissy to slow down, so nothing was saved. Try again in a few minutes."
        case .refused(let other):
            return "\(address): \(UsageFormat.forgeFailure(other)), so nothing was saved."
        }
    }

    /// Why what was typed cannot be connected, said under the fields before
    /// anything is sent anywhere.
    static func addressProblem(_ problem: ForgeAddressProblem) -> String {
        switch problem {
        case .empty: "Type the forge's host."
        case .scheme: "Only https:// or http:// can go in front of the host."
        case .credentials: "Leave out the user@ part. The token is what signs Sissy in."
        case .query: "Leave out the ? and everything after it."
        case .fragment: "Leave out the # and everything after it."
        case .port: "The port has to be a number from 1 to 65535."
        case .host: "That is not a host name. Use letters, digits, dots and hyphens."
        case .path: "The path can hold letters, digits and - . _ ~ between slashes."
        }
    }

    /// A token Sissy holds for a forge no connection names, titled by the
    /// forge and address its keychain item is filed under.
    static func orphanTitle(_ id: String) -> String {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let kind = ForgeKind(rawValue: parts[0]) else { return id }
        return "\(UsageFormat.forgeName(kind)) · \(parts[1])"
    }

    static let orphanSubtitle = "A token with no connection. Nothing reads it."
    static let removeTokenItem = "Remove Token…"
    static let removeTokenConfirm = "Remove Token"
    static let removeTokenMessage =
        "Sissy deletes the token it kept for this forge. Nothing about gh, glab or the forge itself changes."

    static func removeTokenTitle(_ id: String) -> String {
        "Remove the token for \(orphanTitle(id))?"
    }

    static func orphanMenu(_ id: String) -> String {
        "Actions for the token kept for \(orphanTitle(id))"
    }

    static let orphanMenuHelp = "Remove this token"

    /// Said over the list while the connection index cannot be read. It is
    /// left in place rather than set aside, so nothing is listed and a
    /// connect is refused until it reads again.
    static let indexUnreadable =
        "The list of connected forges is there but could not be read, so none are shown and none can be added. Sissy has not touched it. Check the permissions on \(ForgeConnectionIndex.fileName)."

    /// Said over the list once an unreadable connection index has been set
    /// aside, so the connections that vanished with it are explained.
    static let indexSetAside =
        "The list of connected forges could not be read, so Sissy kept it aside as \(ForgeConnectionIndex.setAsidePrefix)….json. The tokens it named are listed below without a connection."

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
        scopes you gave them. That is often write access to every repository, \
        so a read-only token you mint yourself is the narrower choice.
        """

    static func unlinkTitle(_ connection: ForgeConnection) -> String {
        "Disconnect \(UsageFormat.forgeName(connection.kind)) · \(connection.address)?"
    }

    static let unlinkMessage =
        "Sissy deletes the token it holds and stops reading the counts. Nothing about gh, glab or the forge itself changes."
    static let unlinkConfirm = "Disconnect"

    /// What the row's menu is called, which is no longer what one of its items
    /// does. It named the disconnect while that was the only verb in it; a
    /// menu that also reconnects and copies cannot be called by one of three.
    static func rowMenu(_ connection: ForgeConnection) -> String {
        "Actions for \(UsageFormat.forgeName(connection.kind)) on \(connection.address)"
    }

    static let rowMenuHelp = "Reconnect, copy the host, or disconnect this forge"
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

/// What the connect sheet was opened for: a connection to add, or one whose
/// token is being replaced.
///
/// One sheet for both rather than two, because a replacement asks the same two
/// questions an addition does — which host, and which token — and the only
/// difference is that it has already answered the first.
struct ForgeConnectRequest: Identifiable, Equatable {
    /// The connection whose token is being replaced. Nil is a new connection.
    let replacing: ForgeConnection?

    static let new = Self(replacing: nil)

    /// The connection's own id, so a sheet opened from a row is keyed by that
    /// row. The addition has no connection to be named by and takes a key no
    /// host can spell, rather than the empty string a second nil-keyed sheet
    /// would collide on.
    var id: String { replacing?.id ?? "+" }
}

/// The forges the user has connected, and the control that adds one.
///
/// **A tab rather than a section under the metering providers**, which is
/// where it lived until 0.2.0. The rule that kept it a section — a tab is
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

    /// The forge `Disconnect…` was chosen for. What it deletes is a token the
    /// user cannot read back and never typed, so the click is asked about
    /// first.
    @State private var disconnecting: ForgeConnection?
    /// The orphaned token `Remove Token…` was chosen for, asked about first
    /// for the reason a disconnect is.
    @State private var removingToken: String?
    /// What the connect sheet is up for, and nil while it is not.
    @State private var connecting: ForgeConnectRequest?

    var body: some View {
        Form {
            Section {
                heading
                ForEach(model.engine.forgeConnections) { connection in
                    row(connection)
                }
                ForEach(model.engine.orphanedForgeTokens, id: \.self) { id in
                    orphanRow(id)
                }
                CredentialAddRow(ForgeConnectCopy.connect) { open(.new) }
                    .disabled(model.engine.connectingForge != nil || model.engine.forgeIndexUnreadable)
            }
            Section(ForgeCounterCopy.section) {
                ForEach(ForgeCounter.allCases, id: \.self) { counter in
                    counterRow(counter)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $connecting) { request in
            ForgeConnectSheet(model: model, request: request)
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
        .confirmationDialog(
            removingToken.map(ForgeConnectCopy.removeTokenTitle) ?? "",
            isPresented: Binding(
                get: { removingToken != nil }, set: { if !$0 { removingToken = nil } }),
            presenting: removingToken
        ) { id in
            Button(ForgeConnectCopy.removeTokenConfirm, role: .destructive) {
                model.engine.removeOrphanedForgeToken(id: id)
            }
            Button(ForgeConnectCopy.cancel, role: .cancel) {}
        } message: { _ in
            Text(ForgeConnectCopy.removeTokenMessage)
        }
    }

    /// A token Sissy holds that no connection names, which an interrupted
    /// connect or disconnect, or an index set aside, leaves behind. It is on
    /// the list so it can be removed: before it was, nothing on any surface
    /// said the keychain still held it.
    private func orphanRow(_ id: String) -> some View {
        CredentialRow(
            title: ForgeConnectCopy.orphanTitle(id),
            subtitle: ForgeConnectCopy.orphanSubtitle
        ) {
            CredentialDisc(tint: .secondary) {
                ForgeMark(host: id)
            }
        } actions: {
            CredentialRowMenu(
                label: ForgeConnectCopy.orphanMenu(id),
                help: ForgeConnectCopy.orphanMenuHelp
            ) {
                Button(ForgeConnectCopy.removeTokenItem, role: .destructive) {
                    removingToken = id
                }
            }
            .disabled(model.engine.connectingForge != nil)
        }
    }

    /// Raises the connect sheet, clearing what the last attempt failed with on
    /// the way. That message outlives the window that reported it, and both
    /// doors to this one lead to the same sheet, so it is dropped where the
    /// sheet is asked for rather than once it is on screen — a `task` runs
    /// after the first render and would show it for a frame.
    private func open(_ request: ForgeConnectRequest) {
        model.engine.clearForgeConnectFailure()
        connecting = request
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
            if model.engine.forgeIndexUnreadable {
                Text(ForgeConnectCopy.indexUnreadable)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.engine.forgeIndexSetAside {
                Text(ForgeConnectCopy.indexSetAside)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
    ///
    /// **`Reconnect…` is a named item and not a glyph**, for two reasons that
    /// both rule out the circular arrow it looks like. It cannot act on the
    /// press: reading what `gh` holds is a keychain call and a subprocess that
    /// has to *show* what came back before anything is filed, which is the
    /// rule `ForgeTokenImport` is under and the mistake #167 removed. And the
    /// arrow is already spoken for — `Refresh now` on the panel's own forge
    /// row re-reads the counters — so the same sign would mean two things one
    /// tooltip apart. macOS draws no icon inside a SwiftUI menu item anyway.
    private func row(_ connection: ForgeConnection) -> some View {
        let reading = model.liveFrame?.frame.forge.first { $0.id == connection.id }
        return CredentialRow(
            title: connection.address,
            subtitle: subtitle(connection, reading: reading),
            health: Self.health(of: reading),
            fix: fix(connection, reading: reading)
        ) {
            CredentialDisc(tint: .secondary, health: Self.health(of: reading)) {
                ForgeMark(host: connection.host)
            }
        } actions: {
            CredentialRowMenu(
                label: ForgeConnectCopy.rowMenu(connection),
                help: ForgeConnectCopy.rowMenuHelp
            ) {
                Button(ForgeConnectCopy.reconnectItem) {
                    open(ForgeConnectRequest(replacing: connection))
                }
                CredentialCopyButton(CredentialRowCopy.copyHost, of: connection.address)
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
    ///
    /// **A connection that has never answered gets neither**, which is the
    /// distinction `hasEverRead` is named for. `unavailable` stamps `readAt`
    /// with the *attempt* and re-stamps it on every failed round, so an age
    /// printed on its own told a connection that had never once answered it
    /// was read a moment ago — sitting directly above the reason it could not
    /// be read. The login is the test because it is the evidence: only a
    /// reading that arrived carries one, and a failure keeps the previous one
    /// along with the figures, so a row that has ever worked still dates
    /// itself while it is failing. `UsagePanelSnapshot` asks the same question
    /// of the same reading; this row simply was not asking it.
    private func subtitle(
        _ connection: ForgeConnection, reading: ForgeActivityReading?
    ) -> String? {
        if model.engine.connectingForge == connection.id { return ForgeConnectCopy.connecting }
        guard let reading, let login = reading.login else { return nil }
        return "\(login) · \(ForgeConnectCopy.lastRead(reading.readAt))"
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

    /// The read that may raise the keychain's dialog, on the row whose token
    /// the keychain would not hand over. Every other failure is the vendor's
    /// or the network's, and the next scheduled round asks again on its own.
    private func fix(
        _ connection: ForgeConnection, reading: ForgeActivityReading?
    ) -> CredentialFix? {
        guard reading?.failure == .credentialUnreadable else { return nil }
        return CredentialFix(title: ForgeConnectCopy.allowItem) {
            model.engine.refreshForge(connection.id)
        }
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
///
/// **A host already connected is not offered.** It used to be, and pressing it
/// replaced that row's token and dismissed the sheet, so the only visible
/// outcome was a list that had not changed — and a reader who takes the entry
/// for "already connected, nothing to do here" is reading it correctly.
/// Replacing a token is still how a refused or missing one is repaired, which
/// is what `Reconnect…` on the row itself is for; this sheet is the other half
/// of it, and opened that way it offers that one host and locks the two fields
/// that would make it a different connection.
struct ForgeConnectSheet: View {
    let model: SissyModel
    let request: ForgeConnectRequest

    @Environment(\.dismiss) private var dismiss

    @State private var candidates: [ForgeTokenCandidate] = []
    @State private var draft: ForgeConnectDraft
    @State private var token: String = ""
    /// What the last press sent, so Connect Anyway files the attempt that
    /// could not reach its forge, a detected token's included. Dropped on
    /// any edit to the fields, because Connect Anyway beside an address or a
    /// token the user has since changed would file the one they replaced.
    @State private var lastAttempt: ForgeConnectAttempt?

    private static let fieldWidth: CGFloat = 260
    private static let sheetWidth: CGFloat = 420

    init(model: SissyModel, request: ForgeConnectRequest) {
        self.model = model
        self.request = request
        _draft = State(initialValue: ForgeConnectDraft(replacing: request.replacing))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if !candidates.isEmpty {
                Text(replacing == nil ? ForgeConnectCopy.detected : ForgeConnectCopy.detectedForHost)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(candidates) { candidate in
                    Button(ForgeConnectCopy.candidate(candidate)) {
                        attempt(candidate.connection, token: candidate.token)
                    }
                    .disabled(busy)
                }
                Divider()
                Text(ForgeConnectCopy.orPaste)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Picker("Forge", selection: Binding(get: { draft.kind }, set: { draft.pick($0) })) {
                ForEach(ForgeKind.allCases, id: \.self) { kind in
                    Text(UsageFormat.forgeName(kind)).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .disabled(replacing != nil)
            TextField(ForgeConnectCopy.hostPrompt, text: $draft.host)
                .frame(width: Self.fieldWidth)
                .disabled(replacing != nil)
            TextField(ForgeConnectCopy.pathPrompt, text: $draft.path)
                .frame(width: Self.fieldWidth)
                .disabled(replacing != nil)
            if let problem = draft.problem {
                Text(ForgeConnectCopy.addressProblem(problem))
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if draft.upgradesToHTTPS {
                Text(ForgeConnectCopy.askedOverHTTPS)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                if let lastAttempt, model.engine.forgeConnectAnywayID == lastAttempt.connection.id {
                    Button(ForgeConnectCopy.connectAnyway) {
                        model.engine.connectForge(
                            lastAttempt.connection, token: lastAttempt.token, probing: false)
                    }
                    .disabled(busy)
                }
                Spacer()
                Button(ForgeConnectCopy.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(busy ? ForgeConnectCopy.connecting : confirmTitle) {
                    guard let connection else { return }
                    attempt(connection, token: token)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || connection == nil || typedToken.isEmpty)
            }
        }
        .padding(20)
        .frame(width: Self.sheetWidth)
        .task {
            candidates = Self.offered(
                await model.engine.forgeTokenCandidates(), for: request,
                connected: model.engine.forgeConnections)
        }
        // Dismiss on the attempt *finishing well*, never on the press: the
        // token is only in this window, so a failed write has to leave the
        // window standing with the field still in it.
        .onChange(of: [draft.host, draft.path, token]) {
            lastAttempt = nil
        }
        .onChange(of: model.engine.connectingForge) { previous, current in
            guard previous != nil, current == nil,
                model.engine.forgeConnectFailure == nil
            else { return }
            dismiss()
        }
    }

    /// Which candidates this sheet may offer, out of everything both CLIs hold.
    ///
    /// A replacement offers its own host alone — every other candidate would be
    /// a different connection, and the fields that could make it one are locked
    /// — and an addition offers what is not connected yet. The two filters are
    /// the same rule read from either end: a candidate is offered where
    /// pressing it would visibly change the list behind this sheet.
    ///
    /// Keyed on the ids rather than on the host, because `ForgeTokenCandidate`
    /// and `ForgeConnection` spell theirs identically — kind and host — so a
    /// `gh` token for `example.com` is not matched against a `glab` connection
    /// on the same machine.
    nonisolated static func offered(
        _ candidates: [ForgeTokenCandidate], for request: ForgeConnectRequest,
        connected: [ForgeConnection]
    ) -> [ForgeTokenCandidate] {
        guard let replacing = request.replacing else {
            let taken = Set(connected.map(\.id))
            return candidates.filter { !taken.contains($0.id) }
        }
        return candidates.filter { $0.id == replacing.id }
    }

    private var replacing: ForgeConnection? { request.replacing }

    private func attempt(_ connection: ForgeConnection, token: String) {
        lastAttempt = ForgeConnectAttempt(connection: connection, token: token)
        model.engine.connectForge(connection, token: token)
    }

    private var title: String {
        replacing.map(ForgeConnectCopy.reconnectTitle) ?? ForgeConnectCopy.sheetTitle
    }

    private var confirmTitle: String {
        replacing == nil ? ForgeConnectCopy.confirm : ForgeConnectCopy.reconnectConfirm
    }

    private var busy: Bool { model.engine.connectingForge != nil }

    private var typedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// What Connect files: the connection being replaced as it stands, or
    /// what the fields parse to. Nil while they do not parse.
    private var connection: ForgeConnection? {
        replacing ?? (try? draft.connection.get())
    }
}

/// One press of Connect in the sheet, held only while the sheet is open.
struct ForgeConnectAttempt: Equatable {
    let connection: ForgeConnection
    let token: String
}

/// What the connect sheet's fields hold, apart from the token.
///
/// A value rather than three `@State`s so the rule that picking a forge resets
/// the host can be held without a window: the field used to keep `github.com`
/// when GitLab was picked, and a GitLab token pasted under it was sent to
/// GitHub on every poll.
struct ForgeConnectDraft: Equatable {
    private(set) var kind: ForgeKind
    var host: String
    var path: String

    init(replacing: ForgeConnection? = nil) {
        kind = replacing?.kind ?? .gitHub
        host =
            replacing.map { connection in
                connection.host + (connection.port.map { ":\($0)" } ?? "")
            } ?? ForgeKind.gitHub.defaultHost
        path = replacing?.basePath ?? ""
    }

    /// Picks a forge, putting that forge's own host in the field and clearing
    /// the path. Picking the forge already picked changes nothing, so a host
    /// the user typed is not thrown away by a click on the segment it is on.
    mutating func pick(_ picked: ForgeKind) {
        guard picked != kind else { return }
        kind = picked
        host = picked.defaultHost
        path = ""
    }

    var connection: Result<ForgeConnection, ForgeAddressProblem> {
        ForgeConnection.parse(kind: kind, host: host, path: path)
    }

    /// The host was typed with `http://` and will be asked over https.
    var upgradesToHTTPS: Bool { ForgeConnection.namesPlainHTTP(host) }

    /// What to say under the fields, nil while they parse or the host is
    /// still empty: an empty field is one the user has not reached yet, and
    /// Connect being disabled already says it.
    var problem: ForgeAddressProblem? {
        guard case .failure(let problem) = connection, problem != .empty else { return nil }
        return problem
    }
}
