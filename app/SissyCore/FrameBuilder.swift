import Foundation

struct DayTotals: Sendable, Equatable {
    let totalTokens: Int
    let totalCost: Decimal
}

/// One subscription rate-limit window exactly as the vendor reports it.
///
/// `minutes` identifies the window rather than its position in the payload:
/// Codex labels its buckets `primary`/`secondary` but a `primary` bucket is
/// not always the 5-hour one, so anything that keys off position eventually
/// mislabels a weekly window as a session window.
struct UsageWindow: Sendable, Equatable, Codable {
    /// Ceiling for `usedPercent`. Deliberately far above a full window: a
    /// vendor reporting 105% is reporting an overage the panel shows as-is,
    /// and only a value this side of absurd is corruption rather than data.
    static let maxUsedPercent: Double = 10_000

    let minutes: Int
    let usedPercent: Double
    /// When the window rolls over. Nil for a window the vendor reports as
    /// inactive: measured, a session bucket at 0% arrives with a null reset
    /// until the first turn of the period. That is a window with nothing left
    /// to count down to, not a window that does not exist, and dropping it
    /// took the whole session row off the panel until someone used it.
    let resetsAt: Date?
    /// What the window meters, when it is not the whole plan — a model name
    /// as the vendor spells it for display. Nil is the plan-wide window.
    ///
    /// A vendor can publish two windows of the same length that count
    /// different things: measured, a weekly bucket for everything and a
    /// weekly bucket for one model. Without this they render as one row and
    /// the second silently replaces the first. It is the vendor's own display
    /// string and is shown as given, so a model shipped tomorrow needs no
    /// release. Optional so a snapshot written before it decodes unchanged.
    var scope: String?

    /// Fails on a percentage or a reset Sissy cannot draw, which is what
    /// makes both producers safe: the values come off a vendor payload, and
    /// a non-finite one reached `Int(_:)` in the panel and killed it on every
    /// render. It validates rather than substitutes — an overage above 100%
    /// is real and the panel renders it — so a rejected bucket drops its one
    /// gauge, exactly as a bucket missing half its fields already does.
    init?(minutes: Int, usedPercent: Double, resetsAt: Date?, scope: String? = nil) {
        guard usedPercent.isFinite, (0...Self.maxUsedPercent).contains(usedPercent),
            resetsAt.map(\.timeIntervalSince1970.isFinite) ?? true
        else { return nil }
        self.minutes = minutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.scope = scope
    }

    /// The windows a panel draws, in the order it stacks them.
    ///
    /// The order is here rather than at each producer because the panel draws
    /// the list as it is handed: two vendors listing the same two periods the
    /// other way round would stack their blocks differently for no reason a
    /// reader could see. Which row the block *leads* on is not positional —
    /// `UsagePanelSnapshot.binding` decides that from the pace.
    ///
    /// A bucket past its own reset is kept rather than dropped. Every source
    /// is between two readings most of the time, and Codex is where that
    /// showed: its buckets rode the CLI's own turns alone, so between a reset
    /// and the next turn the whole session row left the page with nothing
    /// said — measured 2026-09-16, a 5 h window resetting at 12:30 UTC was
    /// gone at 12:55 while the weekly beside it kept a caption implying the
    /// block was current. A poll behind that row shortens the gap and does
    /// not close it. The reading it carries is stale in the one way that
    /// matters, so the app words it as rolled over and prints no figure for
    /// it; what it must not do is state the period no longer exists, which is
    /// what an absent row says.
    ///
    /// One rule in one place because a provider's reading and an account's
    /// are drawn side by side, and two copies of this would eventually differ.
    static func ordered(_ windows: [UsageWindow]) -> [UsageWindow] {
        windows.sorted { ($0.minutes, $0.scope ?? "") < ($1.minutes, $1.scope ?? "") }
    }
}

/// One project's share of a day.
///
/// `path` is the repository's absolute path, raw — the app renders the last
/// component and keeps the rest for the tooltip, the same division every other
/// field on a slice uses. It is personal data: a client's name is a
/// directory's name, so it stays on the machine.
struct ProjectTotals: Sendable, Equatable, Identifiable {
    let path: String
    let tokens: Int
    let cost: Decimal
    /// The forge this repository is pushed to, when its `origin` names one.
    /// Nil for a repository with no such remote and for one whose checkout is
    /// gone, both of which keep the row the plain name it has.
    let remote: ProjectRemote?

    var id: String { path }

    init(path: String, tokens: Int, cost: Decimal, remote: ProjectRemote? = nil) {
        self.path = path
        self.tokens = tokens
        self.cost = cost
        self.remote = remote
    }
}

/// Why a provider's rate-limit windows are missing, when they are.
///
/// On the frame because the panel is the only surface where any of it can be
/// acted on. Until now the probe wrote these to the log — "switch them off and
/// on again", in a file nobody reads, on a Mac whose gauges had silently gone.
///
/// Only the states that change what the row means. A request that failed and
/// a keychain that did not answer in time are both transient and both leave
/// the last reading on screen with its age, which is already the honest
/// answer — but a vendor that has *refused* to answer is not transient, and
/// the age alone cannot say so.
enum ProviderLimitsState: Sendable, Equatable {
    /// Working, or switched off. Either way the row has nothing to say.
    case quiet
    /// The credentials are there and no read was allowed to ask for them,
    /// which is what a re-signed build meets. One user action recovers it.
    case needsAuthorization
    /// The user was asked and said no. Distinct from the above because
    /// re-asking on a timer would be harassment, and because it also stops
    /// the probe — recovering needs a restart, not just a read.
    case refused
    /// No credentials at all: the CLI is not signed in, or no claude.ai
    /// session has been imported, which is not something Sissy can fix from
    /// here.
    case signedOut
    /// A session that was imported and no longer works. Distinct from
    /// `signedOut` because there is nothing missing to supply — the user has
    /// to import again, and only saying which of the two happened tells them
    /// which button to press.
    case sessionExpired
    /// The credential is readable and the vendor will not accept it.
    ///
    /// Distinct from every state above it, which are all about *getting* a
    /// credential: here there is one, it reached the endpoint, and the
    /// endpoint answered 401 or 403. Distinct from `sessionExpired` too,
    /// which is the same refusal for a credential the user supplied by hand
    /// and can supply again — this one is Claude Code's own, the CLI rotates
    /// it on its own schedule, and there is no button that would help. So the
    /// notice carries no action: the honest instruction is to use the CLI, or
    /// wait for it to renew.
    case credentialRefused
    /// The vendor answered 429 and named when it will answer again.
    ///
    /// The one state here that keeps its windows: they are the last true
    /// reading and their age is the point. Without it the panel had nothing
    /// to say at all — measured 2026-09-17, a reading taken at 01:14 whose
    /// three windows had all rolled over by 07:00 sat under "awaiting a
    /// reading", which is the sentence for a row whose source has not come
    /// back yet. It had; it was being refused, and the row gave the user no
    /// way to know that.
    ///
    /// It carries the moment rather than a flag because the vendor names one,
    /// and the row is the only place it can be read. The deadline is the
    /// vendor's own and it moves: measured the same day, three requests
    /// within 77 s were all refused against the same instant, and 24 minutes
    /// later that instant had advanced by 142 s. So a request during a block
    /// neither resets the wait to a full window nor is free of it — which is
    /// two reasons the refresh button does not make one, and why the date the
    /// row prints is re-read from each refusal rather than counted down.
    case rateLimited(until: Date)

    /// Whether reading the credential is an answer to this state.
    ///
    /// Every state here is about the credential except one, so a read that
    /// found it clears them. A vendor refusing to serve that credential is
    /// not among them: the read said nothing about the block, and clearing it
    /// takes the notice off the row for the length of the request that is
    /// about to be refused again — up to 15 s, every backoff, on a panel
    /// something else is emitting into throughout.
    var isAnsweredByACredentialRead: Bool {
        if case .rateLimited = self { return false }
        // For the same reason as a block: the credential reading fine is not
        // evidence the vendor has started accepting it. Only a request that
        // came back can lift this, and clearing it on the read would put the
        // row back to quiet for the length of the request about to be refused
        // again.
        if case .credentialRefused = self { return false }
        return true
    }

    /// This state as it reads at `now`, which is itself for all but one of
    /// them.
    ///
    /// A block *is* the deadline it names, so once that has passed there is
    /// nothing left to report — and nothing is lost by dropping it, unlike
    /// the windows, because the reading and its age stay on the row and that
    /// is the honest answer when Sissy cannot say whether the vendor would
    /// serve it today.
    ///
    /// Published states normally end when the condition behind them is
    /// re-tested, and this is the one that can outlive its own test: a poll
    /// that reaches the deadline and then cannot spend a request at all — an
    /// access token the CLI has not renewed, a keychain that did not answer —
    /// returns without reaching the endpoint, leaving the block standing with
    /// no refusal behind it and a time in the past on the row.
    func live(at now: Date) -> Self {
        if case .rateLimited(let until) = self, until <= now { return .quiet }
        return self
    }
}

/// Who a provider is signed in as.
///
/// Every field comes off a file its adapter was already reading for the plan,
/// so an account costs no new source, no new poll and no permission. Every
/// field is optional because the two vendors answer for different halves of
/// it, and a provider that answers for none of it carries no account at all
/// rather than an identity of four blanks.
///
/// It is personal data — an address and an organisation's name are the same
/// class as a project path, which `AGENTS.md` already rules on. It stays on
/// the machine: `DiagnosticsReport` names the fields it prints rather than
/// dumping a slice, and there is a test that holds it to that.
struct ProviderAccount: Sendable, Equatable {
    /// The address the CLI is signed in as.
    let email: String?
    /// Organisation the seat belongs to, where the vendor names one. Nil
    /// rather than empty: both readers take it through
    /// `UsageReaderShared.sanitizedDisplayText`, and the panel prints it
    /// unguarded on the strength of that.
    let organization: String?
    /// Seat within that organisation, as the vendor's own token
    /// (`team_tier_1`). Raw rather than a label, the same division `plan`
    /// draws: `UsageFormat` is what decides whether it can word one.
    let seat: String?
    /// Fails when the vendor answered for nothing, so "signed in as nobody"
    /// and "no account line" are the same absence rather than an empty row.
    init?(
        email: String? = nil,
        organization: String? = nil,
        seat: String? = nil
    ) {
        guard email != nil || organization != nil || seat != nil else {
            return nil
        }
        self.email = email
        self.organization = organization
        self.seat = seat
    }
}

/// What a credits figure counts.
///
/// Anthropic bills a spend cap in the account's own currency; OpenAI answers
/// with a count of credits and names no currency for it. Putting a currency on
/// the second would be a figure Sissy made up, and giving Codex a shape of its
/// own would be a second row on the same page answering the same question —
/// which is how two formatters that drift apart get started. So the unit rides
/// on the reading and `UsageFormat` words each.
enum CreditsUnit: Sendable, Equatable, Codable {
    /// Minor units of an ISO 4217 currency, with the exponent the vendor
    /// stated. Read rather than assumed to be 2: not every currency has
    /// hundredths.
    case money(currency: String, exponent: Int)
    /// A count of credits the vendor prices in nothing.
    case credits

    /// Where the minor units put the decimal point.
    ///
    /// Two for a count as well, so a balance a vendor spells `"12.5"` survives
    /// the way in. Storing counts whole would truncate it, and truncation is a
    /// figure Sissy made up as surely as a currency would be; the formatter
    /// trims the zeroes a whole count does not need.
    var exponent: Int {
        switch self {
        case .money(_, let exponent): return exponent
        case .credits: return 2
        }
    }
}

/// What a vendor has billed against a spend cap the user set, and what is left
/// on the account, in whichever unit that vendor answers in.
///
/// Kept in minor units rather than converted on the way in: the currency is the
/// account's, not the machine's, and a division done here would be a rounding
/// nobody asked for. It is deliberately not comparable with
/// `ProviderSlice.cost`, which is Sissy's own estimate of what the metered
/// tokens were worth — one is what was charged, the other what was counted, and
/// the panel keeps them apart.
///
/// Every figure is optional because a source answers for the ones it can and
/// nothing about the rest, and folding those together invents a number: Codex
/// publishes a balance and neither a spend nor a cap, while Claude Code's
/// cached reply publishes a spend and a cap and no balance.
struct ProviderCredits: Sendable, Equatable, Codable {
    /// False when the vendor reports the facility switched off, which renders
    /// as a sentence rather than an empty gauge.
    let isEnabled: Bool
    let unit: CreditsUnit
    /// What has been billed against the cap. Nil for a source that answers
    /// only for what is left, which is not a spend of nothing.
    let usedMinor: Int?
    /// The ceiling, in the same units. Zero where the vendor answers for one
    /// and the account has none set, nil where it does not answer at all — a
    /// spend with no ceiling and an unknown ceiling are different readings,
    /// and only the first can say the spend is uncapped.
    let capMinor: Int?
    /// When the vendor last answered, as the vendor stamped it — not when the
    /// file was read. A reading is shown with this beside it, because a cached
    /// one is the ordinary case and a number with no age is a claim of being
    /// current.
    let observedAt: Date
    /// What is left on the account. Nil where the source cannot answer for it:
    /// the spend against a cap and the balance still on the account are two
    /// different questions, and the CLI's cached reply only carries the first.
    var balanceMinor: Int?

    /// Whether the vendor answered with a figure at all. A reading of zero is
    /// one; a source that named neither a spend nor a balance is not, and gets
    /// no row rather than a row of zeroes.
    var hasReading: Bool { usedMinor != nil || balanceMinor != nil }
    var hasCap: Bool { (capMinor ?? 0) > 0 }
    var capReached: Bool {
        guard let capMinor, capMinor > 0, let usedMinor else { return false }
        return usedMinor >= capMinor
    }

    /// How much of the cap the spend has taken, and nil without both: a bar
    /// drawn against no ceiling would be inventing one.
    var fraction: Double? {
        guard let capMinor, capMinor > 0, let usedMinor else { return nil }
        return min(1, Double(usedMinor) / Double(capMinor))
    }

    /// The figure as a decimal, for a formatter that takes one.
    func amount(_ minor: Int) -> Decimal {
        var scaled = Decimal(minor)
        var result = Decimal()
        NSDecimalMultiplyByPowerOf10(&result, &scaled, Int16(-unit.exponent), .plain)
        return result
    }

    var used: Decimal? { usedMinor.map(amount) }
    var cap: Decimal? { capMinor.map(amount) }
    /// What the cap still covers, and nil without both figures to subtract.
    var remaining: Decimal? {
        guard let capMinor, let usedMinor else { return nil }
        return amount(max(0, capMinor - usedMinor))
    }
    var balance: Decimal? { balanceMinor.map(amount) }
}

/// One provider's share of the day, and everything else its own files answer
/// for. The frame carries these raw so the header total and the per-provider
/// rows come off a single payload rather than two counts that can disagree.
struct ProviderSlice: Sendable, Equatable, Identifiable {
    let id: String
    let tokens: Int
    let cost: Decimal
    /// Plan, account, credits, windows and their age, as this provider last
    /// published them.
    let signals: ProviderSignals
    /// How this provider's day splits across projects. Empty for a provider
    /// whose format names no working directory, which reads the same as a
    /// provider that has spent nothing.
    let projects: [ProjectTotals]
    /// Sessions started and agents spawned today, as this provider counted
    /// them. `.none` where the format names neither.
    let agents: AgentCounts
    /// Which minutes of today carried a turn, and which of those a
    /// sub-agent's. Raw for the reason the counts are: the panel unions the
    /// slices to draw the day, and a slice that carried a pre-summed duration
    /// could not be unioned with another's.
    let activity: AgentActivityDay

    var windows: [UsageWindow] { signals.windows }
    var plan: String? { signals.plan }
    var planTier: String? { signals.planTier }
    var credits: ProviderCredits? { signals.credits }
    var account: ProviderAccount? { signals.account }
    var limitsState: ProviderLimitsState { signals.limitsState }
    var limitsObservedAt: Date? { signals.limitsObservedAt }

    init(
        id: String, tokens: Int, cost: Decimal, signals: ProviderSignals,
        projects: [ProjectTotals] = [], agents: AgentCounts = .none,
        activity: AgentActivityDay = .none
    ) {
        self.id = id
        self.tokens = tokens
        self.cost = cost
        self.agents = agents
        self.activity = activity
        var ordered = signals
        ordered.windows.sort { ($0.minutes, $0.scope ?? "") < ($1.minutes, $1.scope ?? "") }
        if ordered.plan == nil { ordered.planTier = nil }
        self.signals = ordered
        self.projects = projects
    }

    /// The field-by-field form, for the callers that name a slice's parts
    /// rather than hand over a reading — every test, and the placeholder the
    /// panel draws before any provider has reported.
    init(
        id: String, tokens: Int, cost: Decimal, windows: [UsageWindow] = [],
        plan: String? = nil, planTier: String? = nil, credits: ProviderCredits? = nil,
        projects: [ProjectTotals] = [], account: ProviderAccount? = nil,
        limitsState: ProviderLimitsState = .quiet, limitsObservedAt: Date? = nil,
        agents: AgentCounts = .none,
        activity: AgentActivityDay = .none
    ) {
        self.init(
            id: id, tokens: tokens, cost: cost,
            signals: ProviderSignals(
                windows: windows, plan: plan, planTier: planTier, account: account,
                credits: credits, limitsState: limitsState, limitsObservedAt: limitsObservedAt),
            projects: projects, agents: agents, activity: activity)
    }
}

struct FrameData: Sendable, Equatable {
    /// The day so far, raw. Rounding belongs to whichever surface draws it —
    /// the frame used to carry these pre-formatted for a 128×64 display, and
    /// keeping that shape cost the app a second set of formatters that had to
    /// be kept in step with the engine's by hand.
    let tokens: Int
    let cost: Decimal
    /// Tokens per hour so far today, nil on a day nothing has been spent on:
    /// a rate of zero is a claim about pace rather than the absence of one.
    let burn: Double?
    /// One slice per provider that has produced a reading, in a stable order:
    /// claude-code, codex, then alphabetical. A provider that spent nothing
    /// today keeps its slice — it is also what carries the plan, the account,
    /// the credits and the rate-limit gauges — and one that has not read yet
    /// has none, because no reading is not a reading of zero.
    let providers: [ProviderSlice]
    /// The keep-awake mode and whether it is holding right now. Not optional,
    /// including when off: the app renders the control from this, and "off"
    /// and "nothing reported" must not collapse into the same value.
    let keepAwake: KeepAwakeState
    /// What the archive holds for each period the panel offers over it, empty
    /// when there is no archive to read — switched off, or on and still empty.
    ///
    /// Every period at once rather than the selected one: the choice is the
    /// app's and changing it must not cost a round trip to the engine and a
    /// frame's wait. `today` is never a key here — it is what `tokens` and
    /// `cost` above already are, read live rather than from an archive written
    /// behind the tail's flush.
    let history: [UsagePeriod: UsageHistoryRollup]
    /// Today's spend by project, summed across every provider and ordered by
    /// cost. One repository is one row wherever the work ran — a worktree
    /// counts against the checkout it was cut from — and a line naming no
    /// directory is not given a row at all rather than inventing one.
    let projects: [ProjectTotals]
    /// What each vendor's own status page last said, keyed by provider.
    ///
    /// Beside the slices rather than on one, because a status is the vendor's
    /// and not the log tail's: it is the same answer for every account of that
    /// vendor, it costs no reading of theirs, and it exists for a provider
    /// whose cold scan has not finished. Empty for a provider with no feed to
    /// poll, and for every provider while the switch is off.
    let providerStatus: [String: ProviderStatusReading]
    /// What each connected forge last answered, in the connection order the
    /// index keeps.
    ///
    /// Beside the slices rather than on one, because a forge is not a metering
    /// provider: nothing here is a token or a cost, the two counts are the
    /// vendor's own arithmetic over a window the panel picks, and a connection
    /// exists on a Mac where neither CLI has run. Empty while nothing is
    /// connected, which is every install until the user connects one.
    let forge: [ForgeActivityReading]
    /// Which repositories commit under a name their forge does not expect,
    /// and which agree, for every repository the ledger names.
    ///
    /// Beside the projects rather than on them: a project row is today's
    /// spend and exists only for a repository that was worked in during the
    /// window, where this answers for every repository Sissy knows — which is
    /// the set the question is about. Empty where there is no git to read
    /// with, and while the sweep has not run.
    let identities: [RepositoryIdentity]
    /// What the CLIs on this Mac are holding right now, and the series of
    /// readings behind it.
    ///
    /// Beside the slices rather than on one, for the reason the identities
    /// are: a process belongs to the Mac rather than to a log tail, it exists
    /// for a provider that has spent nothing today, and the series is one
    /// series whatever is running in it. `nil` until the first sweep lands,
    /// which the panel draws as a dash — a reading of no agents is a
    /// measurement, and not having measured yet is not.
    let agentMemory: AgentMemoryReading?

    /// Defaulted so a frame can be built without naming the split: a caller
    /// that has none is saying there is none, and every test and future field
    /// that does not care about projects should not have to say so.
    init(
        tokens: Int,
        cost: Decimal,
        burn: Double?,
        providers: [ProviderSlice],
        keepAwake: KeepAwakeState,
        history: [UsagePeriod: UsageHistoryRollup] = [:],
        projects: [ProjectTotals] = [],
        providerStatus: [String: ProviderStatusReading] = [:],
        forge: [ForgeActivityReading] = [],
        identities: [RepositoryIdentity] = [],
        agentMemory: AgentMemoryReading? = nil
    ) {
        self.tokens = tokens
        self.cost = cost
        self.burn = burn
        self.providers = providers
        self.keepAwake = keepAwake
        self.history = history
        self.projects = projects
        self.providerStatus = providerStatus
        self.forge = forge
        self.identities = identities
        self.agentMemory = agentMemory
    }
}

enum FrameBuilder {
    static func burnRate(tokens: Int, hoursElapsed: Double) -> Double? {
        guard tokens > 0, hoursElapsed.isFinite, hoursElapsed > 0 else { return nil }
        return Double(tokens) / max(hoursElapsed, 1.0 / 60.0)
    }

    static func build(
        today: DayTotals,
        hoursElapsed: Double,
        providers: [ProviderSlice] = [],
        keepAwake: KeepAwakeState = .off,
        history: [UsagePeriod: UsageHistoryRollup] = [:],
        providerStatus: [String: ProviderStatusReading] = [:],
        forge: [ForgeActivityReading] = [],
        identities: [RepositoryIdentity] = [],
        agentMemory: AgentMemoryReading? = nil
    ) -> FrameData {
        let burn = burnRate(tokens: today.totalTokens, hoursElapsed: hoursElapsed)
        return FrameData(
            tokens: today.totalTokens,
            cost: today.totalCost,
            burn: burn,
            providers: providers,
            keepAwake: keepAwake,
            history: history,
            projects: combinedProjects(providers),
            providerStatus: providerStatus,
            forge: forge,
            identities: identities,
            agentMemory: agentMemory
        )
    }

    /// The one order every list of projects is shown in: dearest first, then
    /// by path so two that cost the same never trade places between frames.
    ///
    /// It lives here rather than at each list's source because a provider
    /// folds its day out of a dictionary, whose key order is arbitrary and not
    /// even stable across launches. Every surface that shows projects has to
    /// apply this, and the one that keeps only the first few rows has to apply
    /// it *before* it drops any: a prefix of an arbitrary order folds away
    /// whichever project happened to hash first, which can be the day's
    /// largest.
    static func orderedProjects(_ projects: [ProjectTotals]) -> [ProjectTotals] {
        projects.sorted {
            $0.cost == $1.cost ? $0.path < $1.path : $0.cost > $1.cost
        }
    }

    /// One row per project across every provider.
    static func combinedProjects(_ slices: [ProviderSlice]) -> [ProjectTotals] {
        var tokens: [String: Int] = [:]
        var cost: [String: Decimal] = [:]
        var remote: [String: ProjectRemote] = [:]
        for slice in slices {
            for project in slice.projects {
                tokens[project.path, default: 0] += project.tokens
                cost[project.path, default: 0] += project.cost
                if let named = project.remote { remote[project.path] = named }
            }
        }
        return orderedProjects(
            tokens.keys.map {
                ProjectTotals(
                    path: $0, tokens: tokens[$0] ?? 0, cost: cost[$0] ?? 0, remote: remote[$0])
            })
    }

    /// Stable order: claude-code first (v0.1.0 baseline), then codex, then
    /// anything else alphabetically, so the panel's rows never shuffle between
    /// frames.
    static func providerSortOrder(_ id: String) -> Int {
        switch id {
        case "claude-code": return 0
        case "codex": return 1
        default: return 2
        }
    }

    static func sortProviders(_ slices: [ProviderSlice]) -> [ProviderSlice] {
        slices.sorted { lhs, rhs in
            let lp = providerSortOrder(lhs.id)
            let rp = providerSortOrder(rhs.id)
            if lp != rp { return lp < rp }
            return lhs.id < rhs.id
        }
    }
}
