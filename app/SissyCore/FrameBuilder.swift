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

/// Raw per-provider slice carried on the frame so the app derives both the
/// menubar header total and the panel's per-provider rows from a single
/// payload rather than from two counts that can disagree.
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

    var id: String { path }
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

struct ProviderSlice: Sendable, Equatable, Identifiable {
    let id: String
    let tokens: Int
    let cost: Decimal
    /// Empty whenever the provider reports no limits — an API-key user, or a
    /// CLI that has not surfaced a window yet. The panel falls back to the
    /// share-of-today bar rather than rendering an empty gauge.
    let windows: [UsageWindow]
    /// Vendor's own plan token (`max`, `plus`), nil when the provider names
    /// none. Raw rather than a label so the app owns the wording — same
    /// division as `id`, which the app turns into a display name.
    let plan: String?
    /// Limit tier the plan is metered at (`max_5x`), for the one vendor that
    /// publishes one. Only ever set alongside `plan`.
    let planTier: String?
    /// How this provider's day splits across projects. Empty for a provider
    /// whose format names no working directory, which reads the same as a
    /// provider that has spent nothing.
    let projects: [ProjectTotals]
    /// Who this provider is signed in as, when its own files say.
    let account: ProviderAccount?

    init(
        id: String,
        tokens: Int,
        cost: Decimal,
        windows: [UsageWindow] = [],
        plan: String? = nil,
        planTier: String? = nil,
        projects: [ProjectTotals] = [],
        account: ProviderAccount? = nil
    ) {
        self.id = id
        self.tokens = tokens
        self.cost = cost
        self.windows = windows
        self.plan = plan
        self.planTier = plan == nil ? nil : planTier
        self.projects = projects
        self.account = account
    }
}

struct FrameData: Sendable, Equatable {
    let tokens: String
    let cost: String
    let burn: String
    /// Per-provider totals (raw tokens + Decimal cost) for every provider with
    /// spend today. Stable order: claude-code, codex, then alphabetical. Empty
    /// when no provider has tokens today (none active yet, or all idle today).
    let providers: [ProviderSlice]
    /// Yesterday's raw totals, carried so the menubar can render a
    /// day-over-day delta. Both nil until every active provider has produced
    /// a `prev` snapshot, so the app shows no delta instead of a false 0%.
    let prevTokens: Int?
    let prevCost: Decimal?
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
        prevTokens: Int?,
        prevCost: Decimal?,
        keepAwake: KeepAwakeState,
        history: UsageHistoryRollup?,
        projects: [ProjectTotals] = []
    ) {
        self.tokens = tokens
        self.cost = cost
        self.burn = burn
        self.providers = providers
        self.prevTokens = prevTokens
        self.prevCost = prevCost
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

    static func fmtBurn(tokens: Int, hoursElapsed: Double) -> String {
        if tokens <= 0 || hoursElapsed <= 0 { return placeholder }
        let safeHours = max(hoursElapsed, 1.0 / 60.0)
        let rate = Int(Double(tokens) / safeHours)
        return fmtTokens(rate)
    }

    static func fmtCost(_ c: Decimal) -> String {
        let d = NSDecimalNumber(decimal: c).doubleValue
        if d >= 100 { return "\(Int(d))" }
        if d >= 10 { return String(format: "%.1f", d) }
        return String(format: "%.2f", d)
    }

    static func build(
        today: DayTotals,
        prev: DayTotals?,
        hoursElapsed: Double,
        providers: [ProviderSlice] = [],
        keepAwake: KeepAwakeState = .off,
        history: UsageHistoryRollup? = nil
    ) -> FrameData {
        let tokens = fmtTokens(today.totalTokens)
        let burn = fmtBurn(tokens: today.totalTokens, hoursElapsed: hoursElapsed)
        return FrameData(
            tokens: tokens,
            cost: fmtCost(today.totalCost),
            burn: burn,
            providers: providers,
            prevTokens: prev?.totalTokens,
            prevCost: prev?.totalCost,
            keepAwake: keepAwake,
            history: history,
            projects: combinedProjects(providers)
        )
    }

    /// One row per project across every provider, ordered by cost and then by
    /// path so two projects that cost the same never trade places between
    /// frames.
    static func combinedProjects(_ slices: [ProviderSlice]) -> [ProjectTotals] {
        var tokens: [String: Int] = [:]
        var cost: [String: Decimal] = [:]
        for slice in slices {
            for project in slice.projects {
                tokens[project.path, default: 0] += project.tokens
                cost[project.path, default: 0] += project.cost
            }
        }
        return tokens.keys
            .map { ProjectTotals(path: $0, tokens: tokens[$0] ?? 0, cost: cost[$0] ?? 0) }
            .sorted {
                $0.cost == $1.cost ? $0.path < $1.path : $0.cost > $1.cost
            }
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

    /// Breakdown slices for the frame: only CLIs with spend today, in canonical
    /// order. A provider with zero tokens today is omitted so the menubar
    /// Breakdown reflects that day's actual per-CLI split rather than every
    /// warm reader.
    static func activeSlices(_ slices: [ProviderSlice]) -> [ProviderSlice] {
        sortProviders(slices.filter { $0.tokens > 0 })
    }
}
