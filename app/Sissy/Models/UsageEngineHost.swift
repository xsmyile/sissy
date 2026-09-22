import Foundation
import Observation

/// Runs the metering engine inside the app and publishes what the surfaces
/// need from it.
///
/// The engine is an actor and the UI is `@MainActor`, so this is the one hop
/// between them: frames arrive here and land on `SissyModel` already on the
/// main actor, and every control the panel offers is forwarded the other way.
@MainActor
@Observable
final class UsageEngineHost {
    /// Whether the readers have finished their first pass over the log trees.
    ///
    /// Until they have, "no files" and "not looked yet" are the same zero,
    /// and the panel has to say the second rather than the first. A daemon
    /// warmed at login and the app connected to something already hot; in one
    /// process the first launch after an install pays that scan with the
    /// panel open.
    private(set) var isWarm: Bool = false
    private(set) var filesWatched: Int = 0
    /// Every provider Sissy knows about, metering or not. The Providers tab
    /// renders these; the two scalars above are the panel header's summary of
    /// the same list, so they cannot disagree with it.
    private(set) var providers: [ProviderReadiness] = []
    /// Whether Claude's limits come from the CLI's own credential file rather
    /// than from the keychain item or an imported claude.ai session. When they
    /// do, neither of those is read at all, and Settings has to say so instead
    /// of offering a control over a source nothing is using.
    private(set) var claudeUsesOwnCredential: Bool = false
    /// Days the archive is kept for, as `server.json` resolves it. Read from
    /// the same place and for the same reason as the rest: Settings
    /// says what the engine is actually doing, not what the app assumed.
    private(set) var historyRetentionDays: Int = UsageHistoryStore.defaultRetentionDays
    /// Whether the keep-awake hold is set to cover the screen. Read from
    /// `server.json` for the same reason as the rest: the engine owns
    /// that file, and a second copy in the app could disagree with the one the
    /// assertions are actually taken from.
    private(set) var keepScreenAwake: Bool = true
    /// Whether Sissy reads each vendor's own status page. Read from
    /// `server.json` for the reason the rest of these are: the engine owns the
    /// file and owns the poll, and a copy kept in the app could say the
    /// readings are on while nothing is fetching them.
    private(set) var statusChecks: Bool = true
    /// Which counters each forge row carries, for the Forge tab's switches.
    /// Held here the way `statusChecks` is: the engine owns the file, this owns
    /// what the window draws while a write is in flight.
    private(set) var forgeCounters: ForgeCounters = .defaults
    private(set) var agentHooks: Bool = false
    /// Set when the switch is on but a configuration file could not be
    /// rewritten — the name of the CLI whose file was left alone, so Settings
    /// can say which one rather than claiming the switch took effect.
    private(set) var agentHooksRefused: [String] = []
    /// Which registration attempt is current. Two quick toggles start two
    /// independent pieces of work, and installing is the slower of the two — it
    /// copies the script, spawns `sh -n` and takes a backup — so without this
    /// an enable that started first can land after the disable that replaced it
    /// and leave the caption describing a state that is no longer on disk.
    private var agentHooksGeneration = 0
    private var agentHooksTask: Task<Void, Never>?
    /// The keep-awake mode `server.json` holds, for the window before the
    /// first frame carries one.
    ///
    /// The engine takes the hold in `start()`, ahead of the readers' first
    /// pass, so there is a stretch — a price-catalog fetch and a cold scan —
    /// where the Mac is already being held and no frame has said so yet.
    /// Answering `off` across it is not a cosmetic lie: the panel and Settings
    /// render the mode as a radio group, which asserts a mode nobody chose,
    /// and `SissyModel.setKeepAwake` drops a request that matches what the app
    /// wrongly believes it is already in — so the click that would release the
    /// Mac reaches nothing. The frame is the record once one exists; this
    /// stands in until then, which is why it is kept in step at both ends.
    private(set) var keepAwakeMode: KeepAwakeMode = .off
    /// Which providers have a refresh in flight, so a surface can say it is
    /// refreshing rather than repeating an age that is about to change.
    private(set) var refreshing: Set<String> = []
    /// The same, for forge connections.
    ///
    /// Its own set rather than a second kind of member in `refreshing`: the
    /// panel header reads that one whole, as "the frame is being re-read", and
    /// a forge refresh moves none of the numbers that header is dating.
    private(set) var refreshingForge: Set<String> = []

    /// How long a refresh stays visible at the least.
    ///
    /// Not a delay on the work — the engine is already running by the time
    /// this is waited on — but a floor under the *word*. A Codex refresh
    /// re-reads one JSON file and returns inside a frame, so without a floor
    /// the label would never paint and the click would read as a button that
    /// does nothing, which is the complaint it exists to answer. A Claude
    /// refresh with the limits probe on makes a network call and never
    /// reaches the floor at all.
    private static let refreshFloor: Duration = .milliseconds(450)

    @ObservationIgnored private weak var model: SissyModel?
    @ObservationIgnored private var engine: UsageEngine?
    @ObservationIgnored private var readinessTask: Task<Void, Never>?
    /// Handle on the engine's own boot, so `stop()` has something to cancel
    /// rather than leaving a `start()` in flight against an engine it has
    /// already let go of.
    @ObservationIgnored private var bootTask: Task<Void, Never>?
    /// One handle per provider with a refresh in flight, which is what makes
    /// the work cancellable at shutdown and the button non-re-entrant: a
    /// second click while the first is still running has nothing to start.
    @ObservationIgnored private var refreshTasks: [String: Task<Void, Never>] = [:]

    /// How often the warming state is re-read while the cold scan runs. The
    /// readers emit nothing until they finish, so there is no frame to hang
    /// this off — and once warm the poll stops rather than running forever.
    private static let readinessPollInterval: Duration = .milliseconds(500)

    init() {}

    func attach(model: SissyModel) {
        self.model = model
    }

    /// `isLaunch` separates the app starting from a provider switch building a
    /// new engine. Only a launch re-affirms the agent hooks: those are lines
    /// in two other programs' configuration files, and a switch flipped in
    /// Settings has no business rewriting them.
    func start(isLaunch: Bool = true) {
        guard engine == nil else { return }
        // A `server.json` that will not parse is not a reason to meter
        // nothing: `load` overlays what it can read onto the defaults, and
        // an unreadable file leaves the defaults, which are what a fresh
        // install runs on anyway.
        let config = (try? ServerConfig.load()) ?? .defaults
        let engine = UsageEngine(config: config)
        self.engine = engine
        linkedClaudeAccounts = engine.linkedClaudeAccounts
        linkedCodexAccounts = engine.linkedCodexAccounts
        forgeConnections = engine.forgeConnections
        historyRetentionDays = config.resolvedHistoryRetentionDays
        keepScreenAwake = config.keepScreenAwake
        statusChecks = config.statusChecks
        forgeCounters = config.forgeCounters ?? .defaults
        keepAwakeMode = config.keepAwake
        agentHooks = config.agentHooks
        // Re-affirmed at every launch rather than written once: the CLIs
        // rewrite these files themselves, and a line that has gone has to come
        // back without the user noticing it was missing.
        if isLaunch, config.agentHooks || config.agentHooksRemovalPending {
            applyAgentHooks(config.agentHooks)
        }
        let host = self
        bootTask = Task {
            await engine.start { frame in
                await host.deliver(frame)
            }
        }
        pollReadiness()
    }

    /// Stops metering for good and waits for it, so the readers get their
    /// final offset flush before the process goes. Cancelling `bootTask` is
    /// not what stops a boot still in flight — `engine.stop()` is, by clearing
    /// the flag `start()` re-reads after each of its suspensions.
    ///
    /// Terminal, which is what a provider switch landing against a quit needs:
    /// the rebuild reads this back and leaves the engine down rather than
    /// building a new one behind an app that is going away.
    func stop() async {
        isStopped = true
        // Only a real stop waits for the hooks pass. It writes two other
        // programs' configuration files and spawns `sh -n` to check what it is
        // about to write, with no bound on either, so joining it is a debt a
        // process that is going away can afford and a provider switch cannot:
        // a rebuild waiting here would leave `switchingProvider` true and
        // every toggle dead for the rest of the session. A rebuild is not
        // going anywhere, so it lets the pass finish on its own.
        //
        // The handle is re-read rather than assumed: this is a suspension on
        // the main actor and the Settings switch is reachable across it, so
        // clearing whatever is there would drop a pass nothing awaits and
        // nothing can cancel. `isStopped` is what makes that unreachable;
        // this is what keeps it unreachable if it ever stops being.
        let joined = agentHooksTask
        await joined?.value
        if agentHooksTask == joined { agentHooksTask = nil }
        await tearDown()
    }

    /// Whether the app has asked for metering to end. Distinct from having no
    /// engine, which is also what the middle of a rebuild looks like.
    @ObservationIgnored private var isStopped = false
    /// The teardown in flight, so a second caller waits for it rather than
    /// finding `engine` already cleared and reporting a flush that has not
    /// happened yet. `applicationShouldTerminate` is the caller that must not
    /// be told Sissy is done while a switch's rebuild is still writing
    /// offsets.
    @ObservationIgnored private var teardownTask: Task<Void, Never>?

    private func tearDown() async {
        if let inFlight = teardownTask {
            await inFlight.value
            return
        }
        let host = self
        let task = Task { await host.releaseEngine() }
        teardownTask = task
        await task.value
        teardownTask = nil
    }

    private func releaseEngine() async {
        readinessTask?.cancel()
        readinessTask = nil
        bootTask?.cancel()
        bootTask = nil
        refreshTasks.values.forEach { $0.cancel() }
        refreshTasks.removeAll()
        refreshing.removeAll()
        refreshingForge.removeAll()
        switchingClaudeAccount = nil
        guard let engine else { return }
        self.engine = nil
        await engine.stop()
    }

    /// Re-reads what each provider is doing. The readiness poll below stops
    /// once the scan is warm, so a surface that opens later asks for itself
    /// rather than keeping a timer alive for the whole session.
    func refreshProviders() {
        guard let engine else { return }
        let host = self
        Task { host.apply(await engine.providerReadiness()) }
    }

    /// Why the last account switch did not happen, or nil when none has
    /// failed. Published because a switch that silently does nothing leaves
    /// the user typing `claude` and meeting the account they just left.
    private(set) var accountSwitchFailure: String?
    /// Every Claude Code account Sissy has archived, and which one is signed
    /// in. Refreshed from the engine rather than held here, so the app keeps
    /// no second copy of something the keychain decides.
    private(set) var claudeAccounts = ClaudeAccountRegistry.Snapshot()

    /// Which account a switch is running for, or nil when none is.
    ///
    /// Published because the work is a keychain write and a network round trip
    /// behind it: without a word on screen the panel sits unchanged for
    /// seconds and the click reads as a control that did nothing. It carries
    /// the uuid rather than a flag so the page can name the account it is
    /// moving to rather than saying "working".
    private(set) var switchingClaudeAccount: String?

    /// Makes an archived account the one Claude Code starts as.
    ///
    /// Sissy holds its own copy of every account it has seen signed in, so
    /// this overwrites the CLI's slots without putting any credential beyond
    /// recovery — which is the whole difference from the version that lost
    /// one.
    ///
    /// Non-re-entrant, on the same grounds as the refresh button: a second
    /// click while the first write is in flight would race two credentials
    /// into one slot.
    func activateClaudeAccount(uuid: String) {
        guard let engine, switchingClaudeAccount == nil else { return }
        accountSwitchFailure = nil
        switchingClaudeAccount = uuid
        Task { [weak self] in
            let startedAt = ContinuousClock.now
            let outcome = await engine.activateClaudeAccount(uuid: uuid)
            if case .failure(let why) = outcome {
                self?.accountSwitchFailure = ClaudeAccountSwitchCopy.failure(why)
            }
            self?.claudeAccounts = engine.claudeAccountSnapshot
            if let rest = Self.remainingFloor(elapsed: ContinuousClock.now - startedAt) {
                try? await Task.sleep(for: rest)
            }
            self?.switchingClaudeAccount = nil
        }
    }

    /// Whether a claude.ai session is filed, so Settings can offer the right
    /// button. Asked without decrypting one, so it is answerable on a build
    /// whose keychain grant has lapsed.
    private(set) var claudeWebSession: Bool = !ClaudeWebSessionStore.storedAccounts().isEmpty
    /// The accounts Settings lists, and the only surface one can be unlinked
    /// from. Stored rather than read through to the engine on each access:
    /// the engine holds it behind a lock, which no view is observing.
    private(set) var linkedClaudeAccounts: [ClaudeWebAccount] = []
    /// The login window, kept for as long as it is open and dropped with it.
    /// One at a time whichever vendor it is for: two logins would race for the
    /// same window and, on one vendor, for the same keychain item.
    private var loginWindow: VendorLoginWindow?
    /// The Codex accounts Settings lists, and the only surface one can be
    /// unlinked from.
    private(set) var linkedCodexAccounts: [CodexLinkedAccount] = []
    /// Whether a login is in flight, from the click until the session is
    /// filed. The panel's `Add account…` is disabled meanwhile: two logins
    /// would race for the same keychain item.
    private(set) var linkingClaudeAccount = false
    private(set) var claudeWebLinkFailure: ClaudeWebAccountLink.Failure?

    /// Opens claude.ai's own login and links whatever account it produces.
    ///
    /// The whole flow lives in that window — see `VendorLoginWindow`. A
    /// second press while it is open brings it back to the front rather than
    /// being refused, because Sissy has no Dock icon and that press is the
    /// only way back to a window that went behind.
    func addClaudeAccount() {
        guard let engine else { return }
        if let loginWindow, loginWindow.isOpen {
            loginWindow.bringToFront()
            return
        }
        linkingClaudeAccount = true
        claudeWebLinkFailure = nil
        let window = VendorLoginWindow(vendor: .claude)
        loginWindow = window
        window.present(
            onCredential: { [weak self] session in
                guard let self else { return }
                Task { [weak self] in
                    let outcome = await engine.linkClaudeWebSession(session)
                    guard let self, let window = loginWindow else { return }
                    switch outcome {
                    case .success(let choice):
                        guard let choice else { return complete(window) }
                        window.ask(Self.question(choice)) { [weak self] organization in
                            self?.pick(organization, in: window)
                        }
                    case .failure(let why):
                        claudeWebLinkFailure = why
                        window.report(ClaudeAccountLinkCopy.failure(why)) { [weak self] in
                            self?.addClaudeAccount()
                        }
                    }
                }
            },
            onCancel: { [weak self] in
                guard let self else { return }
                loginWindow = nil
                linkingClaudeAccount = false
                Task { await engine.cancelClaudeWebLink() }
            })
    }

    /// The organisation question as the window draws it.
    static func question(_ choice: ClaudeWebLinkChoice) -> VendorLoginQuestion {
        VendorLoginQuestion(
            title: ClaudeAccountLinkCopy.chooseLabel,
            caption: ClaudeAccountLinkCopy.chooseCaption(choice.identity.email),
            options: UsageFormat.organizationChoices(choice.organizations).map {
                VendorLoginQuestion.Option(id: $0.id, label: $0.label)
            })
    }

    private func pick(_ organization: String, in window: VendorLoginWindow) {
        guard let engine else { return }
        Task { [weak self] in
            let outcome = await engine.chooseClaudeWebOrganization(organization)
            guard let self else { return }
            switch outcome {
            case .success:
                complete(window)
            case .failure(let why):
                claudeWebLinkFailure = why
                window.report(ClaudeAccountLinkCopy.failure(why)) { [weak self] in
                    self?.addClaudeAccount()
                }
            }
        }
    }

    /// Takes the window down on a link that landed, and lets the surfaces
    /// notice the account that just appeared.
    private func complete(_ window: VendorLoginWindow) {
        window.finish()
        loginWindow = nil
        linkingClaudeAccount = false
        claudeWebSession = engine?.hasClaudeWebSession ?? false
        linkedClaudeAccounts = engine?.linkedClaudeAccounts ?? []
        linkedCodexAccounts = engine?.linkedCodexAccounts ?? []
        forgeConnections = engine?.forgeConnections ?? []
    }

    /// Opens OpenAI's own login and links whatever account it produces.
    ///
    /// The same window and the same rules as the Claude link, because the only
    /// difference is what the sign-in ends in: a cookie there, a redirect
    /// carrying an authorization code here. What it produces is a credential
    /// of Sissy's own — the CLI's `auth.json` is never written, so linking an
    /// account cannot change which account the terminal is on.
    func addCodexAccount() {
        guard let engine else { return }
        if let loginWindow, loginWindow.isOpen {
            loginWindow.bringToFront()
            return
        }
        let flow = CodexOAuth.begin()
        let window = VendorLoginWindow(vendor: .codex(flow: flow))
        loginWindow = window
        window.present(
            onCredential: { [weak self] code in
                guard let self else { return }
                Task { [weak self] in
                    let outcome = await engine.linkCodexAccount(code: code, flow: flow)
                    guard let self, let window = loginWindow else { return }
                    switch outcome {
                    case .success(let choice):
                        guard let choice else { return complete(window) }
                        window.ask(Self.question(choice)) { [weak self] workspace in
                            self?.pickWorkspace(workspace, in: window)
                        }
                    case .failure(let why):
                        window.report(CodexAccountLinkCopy.failure(why)) { [weak self] in
                            self?.addCodexAccount()
                        }
                    }
                }
            },
            onCancel: { [weak self] in
                guard let self else { return }
                loginWindow = nil
                Task { await engine.cancelCodexLink() }
            })
    }

    /// The workspace question as the window draws it.
    static func question(_ choice: CodexLinkChoice) -> VendorLoginQuestion {
        VendorLoginQuestion(
            title: CodexAccountLinkCopy.chooseLabel,
            caption: CodexAccountLinkCopy.chooseCaption(choice.identity.email),
            options: choice.workspaces.map {
                VendorLoginQuestion.Option(
                    id: $0.id, label: UsageFormat.workspaceLabel($0))
            })
    }

    private func pickWorkspace(_ workspace: String, in window: VendorLoginWindow) {
        guard let engine else { return }
        Task { [weak self] in
            let outcome = await engine.chooseCodexWorkspace(workspace)
            guard let self else { return }
            switch outcome {
            case .success:
                complete(window)
            case .failure(let why):
                window.report(CodexAccountLinkCopy.failure(why)) { [weak self] in
                    self?.addCodexAccount()
                }
            }
        }
    }

    /// The forges the user has connected. Settings lists these; the panel draws
    /// what they answered, which travels on the frame instead.
    private(set) var forgeConnections: [ForgeConnection] = []
    /// Set while a connection is being filed, so the control that started it
    /// can say so: it is a keychain write plus the first read of two counters.
    private(set) var connectingForge: String?
    /// Why the last attempt did not connect, nil once one has.
    ///
    /// It exists because the sheet must not dismiss on a failure: the token was
    /// typed or pasted and is gone the moment that window closes, so a keychain
    /// write that failed would leave no row, no explanation and nothing to
    /// retry with.
    private(set) var forgeConnectFailure: String?

    /// Forgets what the last attempt failed with.
    ///
    /// It outlives the window that reported it — a user who reads the failure
    /// and cancels leaves it standing — and there is more than one door to that
    /// window now, so a sheet opened for one host would otherwise lead with
    /// another host's failure and no attempt behind it.
    func clearForgeConnectFailure() {
        forgeConnectFailure = nil
    }

    /// The tokens `gh` and `glab` already hold, read on the click that offers
    /// them and never before — the rule every credential in this app is
    /// acquired under.
    ///
    /// **Off the main actor, because the read is a subprocess.** `gh`'s token
    /// comes back through `/usr/bin/security`, which means a fork, a pipe and a
    /// wait with a five-second budget per host; run where the sheet is built it
    /// would freeze the whole app — the Cancel button included — for as long as
    /// the keychain took to answer.
    func forgeTokenCandidates() async -> [ForgeTokenCandidate] {
        guard let engine else { return [] }
        return await Task.detached { engine.forgeTokenCandidates() }.value
    }

    /// Connects a forge with a token the user supplied or accepted.
    ///
    /// The outcome lands on `forgeConnectFailure` rather than being dropped, so
    /// the sheet can stay open with what was typed still in it.
    func connectForge(_ connection: ForgeConnection, token: String) {
        guard let engine, connectingForge == nil else { return }
        connectingForge = connection.id
        forgeConnectFailure = nil
        Task { [weak self] in
            let connected = await engine.connectForge(connection, token: token)
            guard let self else { return }
            connectingForge = nil
            forgeConnections = engine.forgeConnections
            forgeConnectFailure = connected ? nil : ForgeConnectCopy.connectFailed
        }
    }

    /// Disconnects a forge: the record, its token and the row it answered for.
    func disconnectForge(id: String) {
        guard let engine else { return }
        Task { [weak self] in
            await engine.disconnectForge(id: id)
            guard let self else { return }
            forgeConnections = engine.forgeConnections
        }
    }

    /// Unlinks one Codex account's credential. Nothing about the CLI's own
    /// sign-in moves with it.
    func forgetCodexAccount(id: String) {
        guard let engine else { return }
        Task { [weak self] in
            await engine.forgetCodexAccount(id: id)
            guard let self else { return }
            linkedCodexAccounts = engine.linkedCodexAccounts
        }
    }

    /// Unlinks one account's claude.ai session.
    ///
    /// The archived Claude Code sign-in stays: it is not something the user
    /// linked, Sissy cannot make another, and only `claude /login` can.
    func forgetClaudeWebSession(account: String) {
        guard let engine else { return }
        Task { [weak self] in
            await engine.forgetClaudeWebSession(account: account)
            guard let self else { return }
            claudeWebSession = engine.hasClaudeWebSession
            linkedClaudeAccounts = engine.linkedClaudeAccounts
        }
    }

    /// Re-reads one provider's out-of-band state. On Claude Code this is the
    /// gesture that may raise the keychain dialog, which is why it is only
    /// ever reached from a click.
    ///
    /// The engine re-emits when it is done, so the reading's age resets on its
    /// own and nothing here has to tell the panel the numbers moved.
    func refreshProvider(_ id: String) {
        guard let engine, refreshTasks[id] == nil else { return }
        refreshing.insert(id)
        refreshTasks[id] = Task {
            let startedAt = ContinuousClock.now
            await engine.refreshProvider(id: id)
            if let rest = Self.remainingFloor(elapsed: ContinuousClock.now - startedAt) {
                try? await Task.sleep(for: rest)
            }
            refreshing.remove(id)
            refreshTasks[id] = nil
        }
    }

    /// Re-reads one forge connection, for the refresh on its own row.
    ///
    /// It shares `refreshTasks` with the provider refresh above — a forge
    /// connection is keyed `kind:host`, which no provider id can be — so a
    /// teardown already cancels it along with the rest.
    func refreshForge(_ id: String) {
        guard let engine, refreshTasks[id] == nil else { return }
        refreshingForge.insert(id)
        refreshTasks[id] = Task {
            let startedAt = ContinuousClock.now
            await engine.refreshForge(id: id)
            if let rest = Self.remainingFloor(elapsed: ContinuousClock.now - startedAt) {
                try? await Task.sleep(for: rest)
            }
            refreshingForge.remove(id)
            refreshTasks[id] = nil
        }
    }

    /// Re-reads every repository's commit identity, for the identities page's
    /// own button.
    ///
    /// One task at a time: the sweep spawns a `git` per repository and a user
    /// pressing the button twice would run two of them over the same set for
    /// no second answer.
    func refreshIdentities() {
        guard let engine, identityRefresh == nil else { return }
        identityRefresh = Task {
            await engine.refreshIdentities()
            identityRefresh = nil
        }
    }

    private var identityRefresh: Task<Void, Never>?

    /// Counts the running agents again, for the agents page's own button.
    ///
    /// One task at a time for the reason above, though the sweep is 1.2 ms
    /// rather than a process per repository: two in flight would publish two
    /// readings a millisecond apart and the page would keep whichever landed
    /// last rather than whichever was asked for last.
    func refreshAgentProcesses() {
        guard let engine, agentRefresh == nil else { return }
        agentRefresh = Task {
            await engine.refreshAgentProcesses()
            agentRefresh = nil
        }
    }

    private var agentRefresh: Task<Void, Never>?

    /// What is left of the floor once the work has taken its time, and nil
    /// once there is nothing left to wait for.
    static func remainingFloor(elapsed: Duration) -> Duration? {
        elapsed < refreshFloor ? refreshFloor - elapsed : nil
    }

    func setKeepAwake(mode: KeepAwakeMode) {
        guard let engine else { return }
        keepAwakeMode = mode
        Task { await engine.setKeepAwake(mode: mode.rawValue) }
    }

    /// Why an export wrote nothing, when it wrote nothing.
    ///
    /// Two silences the caller must not report as one: an archive with no days
    /// in it is an answer, and an engine that is not running is the absence of
    /// one. Both would be `0` on their own, and the second told as the first
    /// sends somebody looking for usage they have.
    enum ExportFailure: LocalizedError {
        case engineNotRunning

        var errorDescription: String? {
            switch self {
            case .engineNotRunning:
                return "Sissy is not metering yet, so it has nothing to read the archive with. "
                    + "Try again once the menu bar icon has counted something."
            }
        }
    }

    /// Writes the archive out as CSV under `directory`, and answers with how
    /// many day files went into it — zero only for an archive that holds none,
    /// which the caller says rather than leaving three header-only files
    /// somebody has to open to find out.
    ///
    /// The read is the engine's because the project paths are re-resolved
    /// against the ledger it owns, though it runs off the engine's actor; the
    /// write is neither's, and runs detached so a user's slow volume stalls the
    /// export rather than the metering or the main thread.
    func exportUsageHistory(to directory: URL) async throws -> Int {
        guard let engine else { throw ExportFailure.engineNotRunning }
        let days = engine.exportableHistory()
        guard !days.isEmpty else { return 0 }
        try await Task.detached { try UsageHistoryExport.write(days, to: directory) }.value
        return days.count
    }

    /// What the archive holds for one provider over the panel's own window,
    /// oldest first and never including today.
    ///
    /// Today is the frame's to answer. The archive is written on the tail's
    /// throttle while the frame is emitted as events land, so a page taking
    /// both from here would print a figure that disagrees with the "Today"
    /// row above it for as long as the throttle holds.
    ///
    /// An engine that is not running answers no days rather than nothing,
    /// because a page that opens before the first frame has no provider on it
    /// to draw them against anyway.
    func usageHistorySeries(provider: String) async -> [UsageHistoryDaySummary] {
        guard let engine else { return [] }
        return await engine.historySeries(
            provider: provider, days: UsagePanelSnapshot.dayStripDays)
    }

    /// Deletes the archive. The engine re-emits once it is gone, which is
    /// what takes the panel's archive line away with it.
    func deleteUsageHistory() {
        guard let engine else { return }
        Task { await engine.deleteHistory() }
    }

    /// Refused, the published flag with it, wherever the pass cannot run:
    /// once teardown has begun, and across the window a provider switch leaves
    /// with no engine — `releaseEngine` clears it before awaiting the stop it
    /// is built on. Nothing is written in either, and a switch left showing
    /// the position it was moved to claims a configuration that is not on
    /// disk. On this control that claim is the serious one: it is the one
    /// thing Sissy writes outside its own folder, so a dropped *off* says two
    /// other programs have stopped running Sissy's line while they have not,
    /// and the next launch re-affirms from the file and undoes the click.
    ///
    /// The engine is asked for here as well as in the pass, because every
    /// other control on this object asks for it before it publishes anything.
    func setAgentHooks(_ enabled: Bool) {
        guard engine != nil, !isStopped, enabled != agentHooks else { return }
        agentHooks = enabled
        applyAgentHooks(enabled)
    }

    /// The same pass again, on the one gesture there is for a configuration
    /// Sissy could not write. A failed *removal* is what needs it: the switch
    /// is already off, so nothing else on this path would ever try again until
    /// the next launch.
    func retryAgentHooks() { applyAgentHooks(agentHooks) }

    /// Registers or unregisters the hook with both CLIs.
    ///
    /// Off the main actor: it reads and rewrites two files and spawns `sh -n`
    /// to check what it is about to write, and it runs at every launch. This
    /// app already measures its own main-thread cost in single percent points.
    ///
    /// Nothing here is fatal to metering: a file Sissy could not rewrite is
    /// named back to the user and left exactly as it was found — and the
    /// intent is written to `server.json` *before* either file is touched, so
    /// a removal interrupted half-way is retried at the next launch instead of
    /// leaving a line in someone else's configuration under a switch that is
    /// already off.
    ///
    /// No pass begins once teardown has: `stop()` joins the one it finds and
    /// the process exits on its reply, so a pass started inside that window is
    /// one nothing awaits and nothing can cancel, writing two other programs'
    /// files after the app has said it is done. Refusing to start is the
    /// recoverable end of it — an install is re-affirmed at the next launch,
    /// a removal is retried from `agentHooksRemovalPending` — where a pass
    /// killed between its two targets leaves one CLI registered and the other
    /// not, which nothing goes back for.
    private func applyAgentHooks(_ enabled: Bool) {
        guard let engine, !isStopped else { return }
        // A test host is not a user launching Sissy. `xcodebuild test` runs the
        // app against this machine's real `Sissy-Dev` tree, so without this the
        // suite rewrites the developer's own `~/.claude/settings.json` and
        // `~/.codex/hooks.json` every time it runs.
        guard NSClassFromString("XCTestCase") == nil else { return }
        guard let home = AgentHookInstaller.userHome else {
            agentHooksRefused = [AgentHookCopy.unknownHome]
            return
        }
        let script = Bundle.main.url(forResource: "session-start", withExtension: "sh")
        if enabled && script == nil {
            agentHooksRefused = [AgentHookCopy.missingScript]
            return
        }
        let stateDirectory = ServerConfig.defaultURL.deletingLastPathComponent()
        let targets = AgentHookInstaller.targets(home: home)
        agentHooksGeneration += 1
        let generation = agentHooksGeneration
        let host = self
        let previous = agentHooksTask
        agentHooksTask = Task.detached(priority: .utility) {
            await previous?.value
            // Asked again here, and not only at the call: a pass queued behind
            // another waits out an install — a script copy, an `sh -n` and two
            // rewrites — and teardown can begin across that wait. What it is
            // still untouched at is this line, which is the only place the
            // refusal is free.
            let stopping = await MainActor.run { host.isStopped }
            guard !stopping else { return }
            // Persist the retry before touching either foreign configuration.
            await engine.setAgentHooks(enabled: enabled, removalPending: !enabled)
            let installer = AgentHookInstaller(stateDirectory: stateDirectory, targets: targets)
            let report: [AgentHookTarget: AgentHookOutcome]
            if enabled, let script {
                report = installer.install(bundledScript: script)
            } else {
                report = installer.remove()
            }
            let refused =
                report
                .filter { _, outcome in outcome == .failed || outcome == .unreadable }
                .keys.map(\.name)
                .sorted()
            await engine.setAgentHooks(enabled: enabled, removalPending: !enabled && !refused.isEmpty)
            await MainActor.run {
                guard host.agentHooksGeneration == generation else { return }
                host.agentHooksRefused = refused
            }
        }
    }

    func setKeepScreenAwake(_ enabled: Bool) {
        guard let engine, enabled != keepScreenAwake else { return }
        keepScreenAwake = enabled
        Task { await engine.setKeepScreenAwake(enabled: enabled) }
    }

    func setStatusChecks(_ enabled: Bool) {
        guard let engine, enabled != statusChecks else { return }
        statusChecks = enabled
        Task { await engine.setStatusChecks(enabled: enabled) }
    }

    /// Switches one of a forge row's counters. Off also stops it being read,
    /// which is the engine's call to make and the reason this is not a view's
    /// own state.
    func setForgeCounter(_ counter: ForgeCounter, _ enabled: Bool) {
        guard let engine, forgeCounters[counter] ?? true != enabled else { return }
        forgeCounters[counter] = enabled
        Task { await engine.setForgeCounter(counter, enabled: enabled) }
    }

    /// Whether anything is being metered at all.
    ///
    /// False for the window before the first readiness lands as well as for a
    /// run with every provider switched off, which is why the header reads it
    /// behind `isWarm` rather than in front of it: an empty list is warm, so
    /// the two are told apart by the order they are asked in.
    var isMetering: Bool { providers.contains { $0.activation.isMetering } }

    /// Whether a provider switch is still being applied. The rebuild is
    /// several awaits long, and a second flip landing inside it would stop an
    /// engine the first one has already let go of.
    private(set) var switchingProvider: Bool = false

    /// Switches one provider's metering on or off, and applies it.
    ///
    /// The toggle is written as an explicit value in both directions, so a
    /// provider Sissy had auto-detected stops being auto-detected the moment
    /// someone touches its switch — which is the honest reading of the
    /// gesture, and what keeps the row from claiming Sissy decided something
    /// the user did.
    func setProvider(_ id: String, enabled: Bool) {
        guard let engine, !switchingProvider else { return }
        guard providers.first(where: { $0.id == id })?.activation.isMetering != enabled else {
            return
        }
        switchingProvider = true
        // Shown thrown before the rebuild rather than after it. Tearing an
        // engine down flushes every reader's offsets first, so the row would
        // otherwise sit in its old position for the length of that flush,
        // which reads as a switch refusing the click. The state written here
        // is the one being persisted, not a guess: an explicit toggle resolves
        // to `on` or `off` whatever is on disk.
        providers = providers.map {
            guard $0.id == id else { return $0 }
            return ProviderReadiness(
                id: $0.id,
                activation: enabled ? .on : .off,
                dataDir: $0.dataDir,
                scan: nil
            )
        }
        isWarm = false
        filesWatched = 0
        Task {
            if await engine.setProvider(id: id, enabled: enabled) {
                await rebuild()
            }
            switchingProvider = false
            // The correction, for the path where the engine refused to write
            // it: the row is already showing a switch that was never
            // persisted, and only re-reading the engine puts it back.
            refreshProviders()
        }
    }

    /// Tears the engine down and builds a new one from the config on disk.
    ///
    /// The reading on screen goes with it rather than staying: it still counts
    /// the provider that has just been switched off, and a panel that keeps
    /// showing it reads as a switch that did nothing. What does not go is
    /// anything on disk — every reader resumes from the offsets its own
    /// snapshot holds, so nothing is re-scanned and no day is counted twice.
    private func rebuild() async {
        await tearDown()
        // A quit that landed inside the teardown has already said metering is
        // over. Building a new engine here would put one behind an app that
        // has replied it is done.
        guard !isStopped else { return }
        model?.clearFrame()
        start(isLaunch: false)
    }

    private func deliver(_ frame: FrameData) {
        if frame.keepAwake.mode != keepAwakeMode { keepAwakeMode = frame.keepAwake.mode }
        syncClaudeCredentialSource()
        syncClaudeAccounts()
        model?.applyFrame(frame)
    }

    /// Re-reads which accounts the registry has archived.
    ///
    /// The registry learns an account on its own watch — a `/login`, a switch
    /// made outside Sissy, a token rotation — and none of those is an action
    /// the app took, so nothing else here would hear about it. It is reached
    /// from both paths that publish, for the reason the credential source
    /// beside it is: the frame, which the registry re-emits on when it files
    /// something, and the readiness a surface asks for when it opens, which is
    /// the path that exists precisely because a frame may not come. The
    /// compare is what keeps a steady state from invalidating the panel's view
    /// graph on every emit.
    ///
    /// Without it the switcher could not appear at all: the property was
    /// written only by `activateClaudeAccount`, which is reachable only from
    /// the control that the list it populates is what draws.
    ///
    /// The linked accounts are re-read with it because their names fall back
    /// to this archive. Read once at `start`, they were named from whatever it
    /// held then, which on a first launch is nothing: the archive fills on the
    /// registry's first capture, after the engine is built, and a session with
    /// no link of its own stayed a bare uuid in Settings until a relaunch.
    private func syncClaudeAccounts() {
        guard let engine else { return }
        let snapshot = engine.claudeAccountSnapshot
        guard snapshot != claudeAccounts else { return }
        claudeAccounts = snapshot
        linkedClaudeAccounts = engine.linkedClaudeAccounts
    }

    /// Re-reads which credential Claude's limits came from.
    ///
    /// The engine answers this off its construction path — finding out costs a
    /// `security` call — so a value read when the engine is built is always
    /// the placeholder it was initialised with, and Settings wording a row
    /// from that placeholder says Sissy is reading claude.ai while it is
    /// reading the CLI's own token. Called from both paths that publish: the
    /// frame that the probe's first reading re-emits, and the readiness the
    /// Providers tab asks for when it opens.
    private func syncClaudeCredentialSource() {
        guard let engine, engine.claudeUsesOwnCredential != claudeUsesOwnCredential else { return }
        claudeUsesOwnCredential = engine.claudeUsesOwnCredential
    }

    /// Folds the per-provider list into the two scalars the panel header
    /// reads. Only a metering provider has a scan, and an empty list is warm:
    /// a run with every provider switched off has nothing left to wait for,
    /// and must not pin the header in its cold-start placeholder.
    private func apply(_ readiness: [ProviderReadiness]) {
        providers = readiness
        syncClaudeCredentialSource()
        syncClaudeAccounts()
        let scans = readiness.compactMap(\.scan)
        filesWatched = scans.reduce(0) { $0 + $1.filesWatched }
        isWarm = scans.allSatisfy(\.isWarm)
    }

    private func pollReadiness() {
        readinessTask?.cancel()
        let host = self
        readinessTask = Task {
            while !Task.isCancelled {
                guard let engine = host.engine else { return }
                host.apply(await engine.providerReadiness())
                if host.isWarm { return }
                try? await Task.sleep(for: Self.readinessPollInterval)
            }
        }
    }
}
