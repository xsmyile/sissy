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
    let resetsAt: Date

    /// Fails on a percentage or a reset Sissy cannot draw, which is what
    /// makes both producers safe: the values come off a vendor payload, and
    /// a non-finite one reached `Int(_:)` in the panel and killed it on every
    /// render. It validates rather than substitutes — an overage above 100%
    /// is real and the panel renders it — so a rejected bucket drops its one
    /// gauge, exactly as a bucket missing half its fields already does.
    init?(minutes: Int, usedPercent: Double, resetsAt: Date) {
        guard usedPercent.isFinite, (0...Self.maxUsedPercent).contains(usedPercent),
            resetsAt.timeIntervalSince1970.isFinite
        else { return nil }
        self.minutes = minutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
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
    /// The account this repository is pushed to, when its `origin` names a
    /// forge. Nil for a repository with no such remote and for one whose
    /// checkout is gone, both of which keep the row the plain name it has.
    let owner: String?

    var id: String { path }

    init(path: String, tokens: Int, cost: Decimal, owner: String? = nil) {
        self.path = path
        self.tokens = tokens
        self.cost = cost
        self.owner = owner
    }
}

/// Why a provider's rate-limit windows are missing, when they are.
///
/// On the frame because the panel is the only surface where any of it can be
/// acted on. Until now the probe wrote these to the log — "switch them off and
/// on again", in a file nobody reads, on a Mac whose gauges had silently gone.
///
/// Only the states a user can do something about. A request that failed and a
/// keychain that did not answer in time are both transient and both leave the
/// last reading on screen with its age, which is already the honest answer.
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
    /// No credentials at all: the CLI is not signed in, which is not
    /// something Sissy can fix from here.
    case signedOut
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
    /// Organisation the seat belongs to, where the vendor names one.
    let organization: String?
    /// Seat within that organisation, as the vendor's own token
    /// (`team_tier_1`). Raw rather than a label, the same division `plan`
    /// draws: `UsageFormat` is what decides whether it can word one.
    let seat: String?
    /// When the subscription renews, for the one vendor that says.
    let renewsAt: Date?

    /// Fails when the vendor answered for nothing, so "signed in as nobody"
    /// and "no account line" are the same absence rather than an empty row.
    init?(
        email: String? = nil,
        organization: String? = nil,
        seat: String? = nil,
        renewsAt: Date? = nil
    ) {
        guard email != nil || organization != nil || seat != nil || renewsAt != nil else {
            return nil
        }
        self.email = email
        self.organization = organization
        self.seat = seat
        self.renewsAt = renewsAt
    }
}

/// Money a vendor has billed against a spend cap the user set, in the
/// account's own currency.
///
/// Kept in minor units with the exponent the vendor stated rather than
/// converted on the way in: the currency is the account's, not the machine's,
/// and a division done here would be a rounding nobody asked for. It is
/// deliberately not comparable with `ProviderSlice.cost`, which is Sissy's own
/// estimate of what the metered tokens were worth — one is what was charged,
/// the other what was counted, and the panel keeps them apart.
struct ProviderCredits: Sendable, Equatable {
    /// False when the vendor reports the facility switched off, which renders
    /// as a sentence rather than an empty gauge.
    let isEnabled: Bool
    let usedMinor: Int
    /// The cap, in the same units. Zero when the account has none set, which
    /// is a spend with no ceiling rather than a ceiling of nothing.
    let capMinor: Int
    /// ISO 4217 code as the vendor gave it (`EUR`), so the app formats in the
    /// account's currency instead of assuming the machine's.
    let currency: String
    /// Where the minor units put the decimal point. Read rather than assumed
    /// to be 2: not every currency has hundredths.
    let exponent: Int
    /// When the vendor last answered, as the vendor stamped it — not when the
    /// file was read. A reading is shown with this beside it, because a cached
    /// one is the ordinary case and a number with no age is a claim of being
    /// current.
    let observedAt: Date

    var hasCap: Bool { capMinor > 0 }
    var capReached: Bool { hasCap && usedMinor >= capMinor }
    /// Zero without a cap: a bar drawn against no ceiling would be inventing
    /// one.
    var fraction: Double {
        guard hasCap else { return 0 }
        return min(1, Double(usedMinor) / Double(capMinor))
    }

    /// The amount as money, for a formatter that takes a `Decimal`.
    func amount(_ minor: Int) -> Decimal {
        var scaled = Decimal(minor)
        var result = Decimal()
        NSDecimalMultiplyByPowerOf10(&result, &scaled, Int16(-exponent), .plain)
        return result
    }

    var used: Decimal { amount(usedMinor) }
    var cap: Decimal { amount(capMinor) }
    var remaining: Decimal { amount(max(0, capMinor - usedMinor)) }
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

    var windows: [UsageWindow] { signals.windows }
    var plan: String? { signals.plan }
    var planTier: String? { signals.planTier }
    var credits: ProviderCredits? { signals.credits }
    var account: ProviderAccount? { signals.account }
    var limitsState: ProviderLimitsState { signals.limitsState }
    var limitsObservedAt: Date? { signals.limitsObservedAt }

    init(id: String, tokens: Int, cost: Decimal, signals: ProviderSignals, projects: [ProjectTotals] = []) {
        self.id = id
        self.tokens = tokens
        self.cost = cost
        var ordered = signals
        ordered.windows.sort { $0.minutes < $1.minutes }
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
        limitsState: ProviderLimitsState = .quiet, limitsObservedAt: Date? = nil
    ) {
        self.init(
            id: id, tokens: tokens, cost: cost,
            signals: ProviderSignals(
                windows: windows, plan: plan, planTier: planTier, account: account,
                credits: credits, limitsState: limitsState, limitsObservedAt: limitsObservedAt),
            projects: projects)
    }
}

struct FrameData: Sendable, Equatable {
    let tokens: String
    let cost: String
    let burn: String
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
    /// What the archive holds for the last week, or nil when there is no
    /// archive to read — switched off, or on and still empty.
    let history: UsageHistoryRollup?
    /// Today's spend by project, summed across every provider and ordered by
    /// cost. One repository is one row wherever the work ran — a worktree
    /// counts against the checkout it was cut from — and a line naming no
    /// directory is not given a row at all rather than inventing one.
    let projects: [ProjectTotals]

    /// Defaulted so a frame can be built without naming the split: a caller
    /// that has none is saying there is none, and every test and future field
    /// that does not care about projects should not have to say so.
    init(
        tokens: String,
        cost: String,
        burn: String,
        providers: [ProviderSlice],
        keepAwake: KeepAwakeState,
        history: UsageHistoryRollup?,
        projects: [ProjectTotals] = []
    ) {
        self.tokens = tokens
        self.cost = cost
        self.burn = burn
        self.providers = providers
        self.keepAwake = keepAwake
        self.history = history
        self.projects = projects
    }
}

enum FrameBuilder {
    /// What a formatter prints when there is nothing to print yet. Read back
    /// by the panel, which drops the burn line rather than showing it.
    static let placeholder = "..."

    static func fmtTokens(_ n: Int) -> String {
        if n >= 1_000_000_000 {
            let v = Double(n) / 1_000_000_000
            return v < 10 ? String(format: "%.1fB", v) : "\(Int(v))B"
        }
        if n >= 1_000_000 {
            let v = Double(n) / 1_000_000
            return v < 10 ? String(format: "%.1fM", v) : "\(Int(v))M"
        }
        if n >= 1_000 {
            let v = Double(n) / 1_000
            return v < 10 ? String(format: "%.1fK", v) : "\(Int(v))K"
        }
        return "\(n)"
    }

    static func burnRate(tokens: Int, hoursElapsed: Double) -> Double? {
        guard tokens > 0, hoursElapsed.isFinite, hoursElapsed > 0 else { return nil }
        return Double(tokens) / max(hoursElapsed, 1.0 / 60.0)
    }

    static func fmtBurn(tokens: Int, hoursElapsed: Double) -> String {
        guard let rate = burnRate(tokens: tokens, hoursElapsed: hoursElapsed) else {
            return placeholder
        }
        return fmtTokens(Int(rate))
    }

    static func fmtCost(_ c: Decimal) -> String {
        let d = NSDecimalNumber(decimal: c).doubleValue
        if d >= 100 { return "\(Int(d))" }
        if d >= 10 { return String(format: "%.1f", d) }
        return String(format: "%.2f", d)
    }

    static func build(
        today: DayTotals,
        hoursElapsed: Double,
        providers: [ProviderSlice] = [],
        keepAwake: KeepAwakeState = .off,
        history: UsageHistoryRollup? = nil
    ) -> FrameData {
        return FrameData(
            tokens: fmtTokens(today.totalTokens),
            cost: fmtCost(today.totalCost),
            burn: fmtBurn(tokens: today.totalTokens, hoursElapsed: hoursElapsed),
            providers: providers,
            keepAwake: keepAwake,
            history: history,
            projects: combinedProjects(providers)
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
        var owner: [String: String] = [:]
        for slice in slices {
            for project in slice.projects {
                tokens[project.path, default: 0] += project.tokens
                cost[project.path, default: 0] += project.cost
                if let named = project.owner { owner[project.path] = named }
            }
        }
        return orderedProjects(
            tokens.keys.map {
                ProjectTotals(
                    path: $0, tokens: tokens[$0] ?? 0, cost: cost[$0] ?? 0, owner: owner[$0])
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
