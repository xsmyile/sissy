import Foundation

/// How much of one GitHub owner's monthly Actions allowance its private
/// repositories have spent, and what spent it.
///
/// **The allowance is money at the Linux rate, not a count of minutes.**
/// GitHub no longer answers how many minutes a plan includes: measured
/// 2026-10-02, `/orgs/<org>/settings/billing/actions`, the endpoint that said
/// so, answers `410`. So the allowance is the plan's minutes valued at the
/// Linux 2-core rate the usage report itself carries. Measured the same day on
/// an organisation on the free plan, the discount it was given came to exactly
/// $12.006 in August and again in September, which is 2,000 minutes at $0.006,
/// and September's was 409.7 Linux minutes at $0.006 and 154 macOS minutes at
/// $0.062: a macOS minute spends 10.3 Linux ones.
///
/// **Only private repositories count.** The report lists public ones too, with
/// the whole of their cost discounted (measured 2026-10-02, a public
/// repository's $8.69 in September), and a public repository on a standard
/// runner spends none of the allowance, so summing every discount would charge
/// it free minutes.
struct ActionsQuota: Sendable, Equatable, Identifiable {
    enum Owner: Sendable, Equatable {
        case user
        case organization
    }

    /// What happens once the allowance is spent.
    enum Overrun: Sendable, Equatable {
        /// The owner's Actions budget is zero and blocks further use: CI stops
        /// until the month turns.
        case stops
        /// Use past the allowance is billed, or already has been.
        case bills
    }

    /// The owner's login.
    let id: String
    let owner: Owner
    /// The plan as GitHub names it, nil where it would not say.
    let plan: String?
    /// The Linux 2-core rate the allowance is valued at, from the report.
    let linuxRate: Double?
    /// Minutes run on private repositories this month, every runner alike.
    let minutes: Double
    /// What the allowance has covered, in dollars.
    let spent: Double
    /// What was billed past it, in dollars.
    let billed: Double
    /// The repository and runner that cost the most, nil with nothing spent.
    let heaviest: ActionsSpender?
    /// Nil where the budget was not asked for or would not answer.
    let overrun: Overrun?
    /// When Sissy read this owner's report, which is what the pace is
    /// measured from: an owner whose report failed keeps the last one it had,
    /// and its gauge must not be dated by a round that did not reach it.
    let readAt: Date

    /// The allowance in dollars, nil for a plan `ActionsAllowance` does not
    /// name or a month whose report carried no Linux rate.
    var allowance: Double? {
        guard let linuxRate, let minutes = plan.flatMap(ActionsAllowance.minutes) else {
            return nil
        }
        return Double(minutes) * linuxRate
    }

    /// The share of the allowance spent, as a percentage, nil without one.
    var usedPercent: Double? {
        guard let allowance, allowance > 0 else { return nil }
        return (spent + billed) / allowance * 100
    }

    /// Whether this owner ran anything that counts this month.
    var hasUsage: Bool { spent + billed > 0 }

    /// Whether the allowance is spent, unrounded, so 99.6% is not yet spent
    /// however the gauge rounds it.
    var isSpent: Bool { (usedPercent ?? 0) >= Self.fullPercent }

    private static let fullPercent: Double = 100
}

/// The repository and runner that spent the largest part of an owner's month.
struct ActionsSpender: Sendable, Equatable {
    let repository: String
    /// The runner's system as GitHub's SKU names it: `Linux`, `macOS`, `Windows`.
    let runner: String
    /// Its part of everything the owner's private repositories cost, 0 to 1.
    let share: Double
}

/// Every owner one token can read the Actions bill of, for one month.
struct ActionsReading: Sendable, Equatable {
    /// The owners whose report answered, the account's own first.
    var quotas: [ActionsQuota]
    /// Whether the account's own report was refused by a classic token that
    /// does not carry the `user` scope, which `X-OAuth-Scopes` names.
    let ownNeedsUserScope: Bool
    /// When the month these figures are for ends, which is when GitHub resets
    /// every allowance: midnight UTC on the first.
    let resetsAt: Date
    /// How long that month is, in minutes, which is the window the pace is
    /// measured over.
    let monthMinutes: Int
    /// Owners whose report failed this round, so the row keeps the quota the
    /// last round read for them rather than losing it.
    var unread: Set<String> = []

    /// A fresh reading with the quotas it could not read taken from the one
    /// before it, for the same month only: a quota carried across the first
    /// would put last month's figures under this month's heading.
    static func merged(_ fresh: Self?, over previous: Self?) -> Self? {
        guard let fresh else { return previous }
        guard let previous, previous.resetsAt == fresh.resetsAt, !fresh.unread.isEmpty else {
            return fresh
        }
        let read = Set(fresh.quotas.map(\.id))
        let kept = previous.quotas.filter { fresh.unread.contains($0.id) && !read.contains($0.id) }
        var merged = fresh
        merged.quotas = fresh.quotas + kept
        return merged
    }
}

/// The minutes each plan includes, keyed by the name GitHub answers for it.
///
/// **The one figure here that is not read**, because GitHub stopped
/// publishing it: see `ActionsQuota`. Rates are never kept here: they come
/// off the report. A plan missing from it leaves the owner's minutes on the
/// row without a gauge, which is a reading with less in it rather than a
/// guessed one. Figures from GitHub's Actions billing documentation, read
/// 2026-10-02.
enum ActionsAllowance {
    static let byPlan: [String: Int] = [
        "free": 2_000,
        "pro": 3_000,
        "team": 3_000,
        "enterprise": 50_000,
    ]

    static func minutes(plan: String) -> Int? { byPlan[plan.lowercased()] }
}

/// GitHub's billing reports, read for every owner the token can see the bill of.
///
/// **Non-throwing, for the reason the latest event is**: it rides a reading
/// whose counters have already arrived, and a billing endpoint that would not
/// answer must not throw those away. A nil reading keeps the previous one on
/// the row with its age, and an owner whose report alone failed keeps its
/// previous quota through `ActionsReading.merged`.
///
/// **A report the token may not read is not a failure.** An organisation the
/// account is only a member of answers `403` or `404`, and that is the answer:
/// its bill is not this account's to read, so it is left off. The account's
/// own `404` is the `user` scope missing only where `X-OAuth-Scopes` says the
/// token is classic and lacks it, measured 2026-10-02 with
/// `X-Accepted-OAuth-Scopes: user`; any other refusal is left off unexplained.
///
/// Per read: the organisations (the first hundred), one report per owner, a
/// GraphQL document per fifty repositories for which are public, a plan per
/// owner that spent anything and a budget per organisation that spent it all.
/// Measured 2026-10-02, the organisation reports answer with the classic `repo`
/// scope.
enum GitHubActionsFeed {
    private static let organizationsPage = 100
    /// Repositories per visibility document, well inside GitHub's node limit.
    static let visibilityChunk = 50
    private static let scopesHeader = "X-OAuth-Scopes"
    private static let userScope = "user"

    static func read(
        _ connection: ForgeConnection, token: String, login: String, now: Date
    ) async -> ActionsReading? {
        guard connection.isVendorHosted, let month = BillingMonth(containing: now) else {
            return nil
        }
        do {
            let owners: [(String, ActionsQuota.Owner)] =
                [(login, .user)] + (try await organizations(token: token)).map { ($0, .organization) }
            var reports: [OwnerReport] = []
            var unread: Set<String> = []
            var ownNeedsUserScope = false
            for (owner, kind) in owners {
                do {
                    switch try await report(kind, owner, month: month, token: token) {
                    case .items(let items):
                        reports.append(OwnerReport(owner: owner, kind: kind, items: items))
                    case .refused(let missingUserScope):
                        ownNeedsUserScope = ownNeedsUserScope || (kind == .user && missingUserScope)
                    }
                } catch {
                    try Task.checkCancellation()
                    unread.insert(owner)
                }
            }
            let isPublic = try await publicRepositories(
                Set(reports.flatMap(\.repositories)), connection: connection, token: token)
            let all = reports.flatMap(\.items)
            let pricing = MonthPricing(
                linuxRate: all.first(where: \.isLinuxStandard)?.unitPrice,
                covered: coveredRunners(all))
            var quotas: [ActionsQuota] = []
            for report in reports {
                let counted = report.items.filter {
                    !isPublic.contains(RepositoryKey(owner: report.owner, name: $0.repository))
                }
                do {
                    quotas.append(
                        try await quota(
                            report, counted, pricing: pricing, token: token, now: now))
                } catch {
                    try Task.checkCancellation()
                    unread.insert(report.owner)
                }
            }
            return ActionsReading(
                quotas: quotas, ownNeedsUserScope: ownNeedsUserScope, resetsAt: month.end,
                monthMinutes: month.minutes, unread: unread)
        } catch {
            return nil
        }
    }

    /// One owner's month, from its private repositories' rows.
    ///
    /// The plan is asked only of an owner that spent something, and the
    /// budget only of an organisation that spent all of it: the gauge is the
    /// only thing that needs the first and the caption at 100% the only thing
    /// that needs the second. A plan that would not answer fails the owner,
    /// which keeps its previous quota, rather than turn its gauge into bare
    /// minutes for a round; a budget that would not answer leaves the caption
    /// saying the allowance is spent without saying what follows.
    private static func quota(
        _ report: OwnerReport, _ items: [ActionsItem], pricing: MonthPricing, token: String,
        now: Date
    ) async throws -> ActionsQuota {
        let unpriced = month(report, items, pricing: pricing, now: now)
        guard unpriced.hasUsage else { return unpriced }
        let priced = unpriced.with(plan: try await plan(report.kind, report.owner, token: token))
        guard priced.overrun == nil, report.kind == .organization, priced.isSpent else {
            return priced
        }
        return priced.with(overrun: try? await budget(report.owner, token: token))
    }

    /// An owner's month before its plan is known, from its private rows.
    ///
    /// The spent figure is every discount, which a larger runner never gets;
    /// the billed one is only what the allowance's own runners were charged,
    /// so a larger runner's bill does not read as the allowance running out.
    static func month(
        _ report: OwnerReport, _ items: [ActionsItem], pricing: MonthPricing, now: Date
    ) -> ActionsQuota {
        let billed = items.filter { pricing.covered.contains($0.sku) }.reduce(0) { $0 + $1.net }
        return ActionsQuota(
            id: report.owner, owner: report.kind, plan: nil, linuxRate: pricing.linuxRate,
            minutes: items.reduce(0) { $0 + $1.quantity },
            spent: items.reduce(0) { $0 + $1.discount }, billed: billed, heaviest: heaviest(items),
            overrun: billed > 0 ? .bills : nil, readAt: now)
    }

    /// The runners the allowance covers: the standard three GitHub documents,
    /// and any other the month's own rows prove by discounting it.
    ///
    /// A larger runner is never discounted, in a private repository or a
    /// public one (GitHub's Actions billing documentation, read 2026-10-02),
    /// so a discount anywhere proves a SKU is covered: that is how a slim or
    /// ARM runner no list names is covered. The absence of one proves nothing,
    /// because a standard runner first run after the allowance is spent is
    /// never discounted either, which is why the documented three are covered
    /// whether or not the month discounted them. Every owner's rows are read,
    /// public repositories included, since their standard runners are
    /// discounted in full.
    static func coveredRunners(_ items: [ActionsItem]) -> Set<String> {
        documentedStandardRunners.union(items.filter { $0.discount > 0 }.map(\.sku))
    }

    /// GitHub's standard runners, as the usage report names them: the first
    /// two measured 2026-10-02, the third the Windows SKU documented beside
    /// them.
    static let documentedStandardRunners: Set<String> = [
        "Actions Linux", "Actions macOS 3-core", "Actions Windows",
    ]

    /// The repository and runner with the largest cost, as a share of all of
    /// it. Gross rather than discount, so a repository that ran past the
    /// allowance is not ranked by only the part the allowance paid for.
    static func heaviest(_ items: [ActionsItem]) -> ActionsSpender? {
        let total = items.reduce(0) { $0 + $1.gross }
        guard total > 0 else { return nil }
        let grouped = Dictionary(grouping: items) { "\($0.repository)\u{0}\($0.runner)" }
        guard
            let top = grouped.values.max(by: {
                $0.reduce(0) { $0 + $1.gross } < $1.reduce(0) { $0 + $1.gross }
            }), let first = top.first
        else { return nil }
        return ActionsSpender(
            repository: first.repository, runner: first.runner,
            share: top.reduce(0) { $0 + $1.gross } / total)
    }

    private static func organizations(token: String) async throws -> [String] {
        let url = api("user", "orgs", query: [("per_page", String(organizationsPage))])
        guard let rows = try await get(url, token: token) as? [[String: Any]] else {
            throw ForgeReadFailure.malformed
        }
        return rows.compactMap { $0["login"] as? String }
    }

    /// What an owner's report answered: its rows, or that the token may not
    /// read it, which is an answer rather than a failure.
    enum ReportAnswer: Equatable {
        case items([ActionsItem])
        /// Refused, and whether the refusal is a classic token without `user`.
        case refused(missingUserScope: Bool)
    }

    /// What the month's rows say about every owner's runners at once.
    struct MonthPricing {
        /// The Linux 2-core rate the allowance is valued at.
        let linuxRate: Double?
        /// The runner SKUs the allowance covers, from `coveredRunners`.
        let covered: Set<String>
    }

    /// One owner's report rows, kept with whose they are.
    struct OwnerReport {
        let owner: String
        let kind: ActionsQuota.Owner
        let items: [ActionsItem]

        var repositories: [RepositoryKey] {
            items.map { RepositoryKey(owner: owner, name: $0.repository) }
        }
    }

    /// One owner's usage report for the month.
    private static func report(
        _ kind: ActionsQuota.Owner, _ owner: String, month: BillingMonth, token: String
    ) async throws -> ReportAnswer {
        let root = kind == .user ? "users" : "organizations"
        let url = api(
            root, owner, "settings", "billing", "usage",
            query: [("year", String(month.year)), ("month", String(month.month))])
        let body: Any
        switch try await fetch(url, token: token) {
        case .body(let reply): body = reply
        case .refused(let scopes): return .refused(missingUserScope: lacksUserScope(scopes))
        }
        guard let body = body as? [String: Any], let rows = body["usageItems"] as? [[String: Any]]
        else { throw ForgeReadFailure.malformed }
        return .items(rows.compactMap(ActionsItem.init))
    }

    private static func plan(_ kind: ActionsQuota.Owner, _ owner: String, token: String) async throws
        -> String?
    {
        let url = kind == .user ? api("user") : api("orgs", owner)
        let body = try await get(url, token: token) as? [String: Any]
        return (body?["plan"] as? [String: Any])?["name"] as? String
    }

    private static func budget(_ organization: String, token: String) async throws
        -> ActionsQuota.Overrun?
    {
        let url = api("organizations", organization, "settings", "billing", "budgets")
        guard case .body(let reply) = try await fetch(url, token: token),
            let body = reply as? [String: Any]
        else { return nil }
        return overrun(budgets: body)
    }

    /// What an organisation's budgets say happens past the allowance: a zero
    /// Actions budget that blocks further use stops CI, anything else bills.
    /// Measured 2026-10-02, the free organisation that ran out had exactly the
    /// first: `budget_amount` 0 with `prevent_further_usage` on the `actions`
    /// SKU, scoped to the organisation. A budget scoped to one repository or a
    /// cost centre says nothing about the rest, so only the organisation's own
    /// is read, and none is no answer.
    static func overrun(budgets body: [String: Any]) -> ActionsQuota.Overrun? {
        guard let budgets = body["budgets"] as? [[String: Any]] else { return nil }
        let actions = budgets.first {
            ($0["budget_product_sku"] as? String) == actionsSKU
                && ($0["budget_scope"] as? String) == organizationScope
        }
        guard let actions else { return nil }
        let amount = (actions["budget_amount"] as? NSNumber)?.doubleValue ?? 0
        let blocks = actions["prevent_further_usage"] as? Bool ?? false
        return blocks && amount == 0 ? .stops : .bills
    }

    private static let actionsSKU = "actions"
    private static let organizationScope = "organization"

    /// Whether a refusal came from a classic token that does not carry `user`.
    /// A fine-grained token sends no scopes header at all, and then nothing
    /// can be said about why.
    static func lacksUserScope(_ scopes: String?) -> Bool {
        guard let scopes else { return false }
        let granted = scopes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return !granted.contains(userScope)
    }

    /// Which of `repositories` are public, in a document per
    /// `visibilityChunk`. The names are the vendor's own, so they travel as variables
    /// rather than spliced into the query. A repository GitHub no longer
    /// finds answers null and is counted as private: whatever it spent was
    /// spent, and only a public one is free.
    private static func publicRepositories(
        _ repositories: Set<RepositoryKey>, connection: ForgeConnection, token: String
    ) async throws -> Set<RepositoryKey> {
        guard !repositories.isEmpty, let endpoint = GitHubActivityFeed.endpoint(connection) else {
            return []
        }
        let ordered = repositories.sorted { ($0.owner, $0.name) < ($1.owner, $1.name) }
        var found: Set<RepositoryKey> = []
        for start in stride(from: 0, to: ordered.count, by: visibilityChunk) {
            let chunk = Array(ordered[start..<min(start + visibilityChunk, ordered.count)])
            let (query, variables) = visibilityDocument(chunk)
            let payload = try await ForgeActivityFeed.graphQL(
                endpoint, query: query, variables: variables, token: token,
                header: GitHubActivityFeed.authorizationHeader,
                scheme: GitHubActivityFeed.authorizationScheme)
            for (index, key) in chunk.enumerated() {
                let node = payload["r\(index)"] as? [String: Any]
                if node?["isPrivate"] as? Bool == false { found.insert(key) }
            }
        }
        return found
    }

    static func visibilityDocument(_ repositories: [RepositoryKey]) -> (String, [String: String]) {
        var parameters: [String] = []
        var fields: [String] = []
        var variables: [String: String] = [:]
        for (index, key) in repositories.enumerated() {
            parameters.append("$o\(index): String!, $n\(index): String!")
            fields.append("r\(index): repository(owner: $o\(index), name: $n\(index)) { isPrivate }")
            variables["o\(index)"] = key.owner
            variables["n\(index)"] = key.name
        }
        return (
            "query(\(parameters.joined(separator: ", "))) { \(fields.joined(separator: " ")) }",
            variables
        )
    }

    private static func api(_ path: String..., query: [(String, String)] = []) -> URL? {
        var url = GitHubActivityFeed.dotComREST
        for component in path { url.appendPathComponent(component) }
        guard !query.isEmpty else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components?.url
    }

    private static func get(_ url: URL?, token: String) async throws -> Any {
        guard case .body(let reply) = try await fetch(url, token: token, refusalIsAnswer: false)
        else { throw ForgeReadFailure.malformed }
        return reply
    }

    /// What one request answered: a JSON body, or a refusal that is an answer.
    enum Reply {
        case body(Any)
        /// `403` or `404` on a bill this token may not read, with the scopes a
        /// classic token says it carries.
        case refused(scopes: String?)
    }

    /// One request. A `403` that is the vendor asking for less traffic is a
    /// failure rather than a refusal, which `ForgeActivityFeed.askedToSlowDown`
    /// tells apart.
    private static func fetch(
        _ url: URL?, token: String, refusalIsAnswer: Bool = true
    ) async throws -> Reply {
        guard let url else { throw ForgeReadFailure.malformed }
        let request = ForgeActivityFeed.request(
            url, token: token, header: GitHubActivityFeed.authorizationHeader,
            scheme: GitHubActivityFeed.authorizationScheme)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await SissyHTTP.data(for: request)
        } catch {
            throw ForgeActivityFeed.failure(thrown: error)
        }
        guard let http = response as? HTTPURLResponse else { throw ForgeReadFailure.malformed }
        let refused =
            http.statusCode == 404
            || (http.statusCode == 403 && !ForgeActivityFeed.askedToSlowDown(http))
        if refusalIsAnswer, refused, SissyHTTP.sameOrigin(url, http.url) {
            return .refused(scopes: http.value(forHTTPHeaderField: scopesHeader))
        }
        if let failure = ForgeActivityFeed.failure(of: http, addressedTo: url) { throw failure }
        guard let body = try? JSONSerialization.jsonObject(with: data) else {
            throw ForgeReadFailure.malformed
        }
        return .body(body)
    }
}

/// A repository by owner and name, which is all the report says of one.
struct RepositoryKey: Sendable, Hashable {
    let owner: String
    let name: String
}

/// One row of a usage report that is Actions minutes, nil for any other: the
/// storage rows, Packages, Copilot.
///
/// The report spells product and unit differently from the summary beside it
/// (`actions` and `Minutes` against `Actions` and `minutes`, measured
/// 2026-10-02), so both are compared without case.
struct ActionsItem: Sendable, Equatable {
    let repository: String
    let sku: String
    let quantity: Double
    let unitPrice: Double
    let gross: Double
    let discount: Double
    let net: Double

    init(
        repository: String, sku: String, quantity: Double, unitPrice: Double, gross: Double,
        discount: Double, net: Double
    ) {
        self.repository = repository
        self.sku = sku
        self.quantity = quantity
        self.unitPrice = unitPrice
        self.gross = gross
        self.discount = discount
        self.net = net
    }

    init?(_ row: [String: Any]) {
        guard (row["product"] as? String)?.lowercased() == Self.product,
            (row["unitType"] as? String)?.lowercased() == Self.unit,
            let repository = row["repositoryName"] as? String, !repository.isEmpty,
            let sku = row["sku"] as? String
        else { return nil }
        func number(_ key: String) -> Double { (row[key] as? NSNumber)?.doubleValue ?? 0 }
        self.init(
            repository: repository, sku: sku, quantity: number("quantity"),
            unitPrice: number("pricePerUnit"), gross: number("grossAmount"),
            discount: number("discountAmount"), net: number("netAmount"))
    }

    private static let product = "actions"
    private static let unit = "minutes"
    private static let skuPrefix = "Actions "
    private static let linuxStandard = "Actions Linux"
    private static let systems = ["Linux", "macOS", "Windows"]

    /// The standard Linux runner, whose rate the allowance is valued at.
    var isLinuxStandard: Bool { sku == Self.linuxStandard }

    /// The runner's system, `macOS` for `Actions macOS 3-core`; the SKU
    /// without its prefix for one that names none of the three.
    var runner: String {
        Self.systems.first { sku.localizedCaseInsensitiveContains($0) }
            ?? (sku.hasPrefix(Self.skuPrefix) ? String(sku.dropFirst(Self.skuPrefix.count)) : sku)
    }
}

/// The calendar month GitHub bills by, in UTC.
struct BillingMonth: Sendable, Equatable {
    let year: Int
    let month: Int
    let start: Date
    let end: Date

    var minutes: Int { Int(end.timeIntervalSince(start) / 60) }

    init?(containing instant: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = calendar.dateComponents([.year, .month], from: instant)
        guard let year = parts.year, let month = parts.month,
            let start = calendar.date(from: parts),
            let end = calendar.date(byAdding: .month, value: 1, to: start)
        else { return nil }
        self.year = year
        self.month = month
        self.start = start
        self.end = end
    }
}

extension ActionsQuota {
    fileprivate func with(plan: String?) -> Self {
        Self(
            id: id, owner: owner, plan: plan, linuxRate: linuxRate, minutes: minutes,
            spent: spent, billed: billed, heaviest: heaviest, overrun: overrun, readAt: readAt)
    }

    fileprivate func with(overrun: Overrun?) -> Self {
        Self(
            id: id, owner: owner, plan: plan, linuxRate: linuxRate, minutes: minutes,
            spent: spent, billed: billed, heaviest: heaviest, overrun: overrun, readAt: readAt)
    }
}
