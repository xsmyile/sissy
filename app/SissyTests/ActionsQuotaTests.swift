import XCTest

@testable import Sissy

/// The Actions allowance: the report rows it is read from, the arithmetic that
/// turns them into a gauge, and the rows the Forge tab draws.
///
/// The rows are radonforge's September 2026 report as GitHub answered it on
/// 2026-10-02, folded to one row per repository and SKU, plus a storage row
/// and a public repository's minutes, which are the two kinds the reader must
/// leave out.
final class ActionsQuotaTests: XCTestCase {
    private static let report = """
        {"usageItems":[
        {"date":"2026-09-22T00:00:00Z","product":"actions","sku":"Actions macOS 3-core",
         "quantity":154.0,"unitType":"Minutes","pricePerUnit":0.062,"grossAmount":9.548,
         "discountAmount":9.548,"netAmount":0.0,"organizationName":"radonforge",
         "repositoryName":"try-on-buddy"},
        {"date":"2026-09-22T00:00:00Z","product":"actions","sku":"Actions Linux",
         "quantity":228.667,"unitType":"Minutes","pricePerUnit":0.006,"grossAmount":1.372,
         "discountAmount":1.372,"netAmount":0.0,"organizationName":"radonforge",
         "repositoryName":"try-on-buddy"},
        {"date":"2026-09-09T00:00:00Z","product":"actions","sku":"Actions Linux",
         "quantity":181.0,"unitType":"Minutes","pricePerUnit":0.006,"grossAmount":1.086,
         "discountAmount":1.086,"netAmount":0.0,"organizationName":"radonforge",
         "repositoryName":"morphy.lol"},
        {"date":"2026-09-09T00:00:00Z","product":"actions","sku":"Actions storage",
         "quantity":0.298,"unitType":"GigabyteHours","pricePerUnit":0.00033602,
         "grossAmount":0.0001,"discountAmount":0.0001,"netAmount":0.0,
         "organizationName":"radonforge","repositoryName":"morphy.lol"}
        ]}
        """

    private static func items() throws -> [ActionsItem] {
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(body["usageItems"] as? [[String: Any]])
        return rows.compactMap(ActionsItem.init)
    }

    /// One owner's month, September's measured figures by default. Shared
    /// with `ActionsRowTests`.
    static func quota(
        plan: String? = "free", spent: Double = 12.006, billed: Double = 0,
        overrun: ActionsQuota.Overrun? = nil, id: String = "radonforge"
    ) -> ActionsQuota {
        ActionsQuota(
            id: id, owner: .organization, plan: plan, linuxRate: 0.006, minutes: 563.667,
            spent: spent, billed: billed,
            heaviest: ActionsSpender(repository: "try-on-buddy", runner: "macOS", share: 0.795),
            overrun: overrun, readAt: midOctober)
    }

    static let october: BillingMonth = {
        BillingMonth(containing: Date(timeIntervalSince1970: 1_790_942_400))!
    }()

    static let midOctober = Date(timeIntervalSince1970: 1_791_590_400)

    static func reading(_ quotas: [ActionsQuota], needsScope: Bool = false) -> ActionsReading {
        ActionsReading(
            quotas: quotas, ownNeedsUserScope: needsScope, resetsAt: october.end,
            monthMinutes: october.minutes)
    }

    // MARK: The report

    func testOnlyActionsMinutesAreRead() throws {
        let items = try Self.items()
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(Set(items.map(\.repository)), ["try-on-buddy", "morphy.lol"])
    }

    func testTheRunnerIsTheSystemTheSKUNames() throws {
        let runners = try Self.items().map(\.runner)
        XCTAssertEqual(runners, ["macOS", "Linux", "Linux"])
        XCTAssertEqual(
            ActionsItem(
                repository: "r", sku: "Actions Linux 16-core", quantity: 1, unitPrice: 0.042,
                gross: 0.042, discount: 0, net: 0.042
            ).runner, "Linux")
    }

    func testTheHeaviestSpenderIsTheMacRunnerOnTryOnBuddy() throws {
        let heaviest = try XCTUnwrap(GitHubActionsFeed.heaviest(Self.items()))
        XCTAssertEqual(heaviest.repository, "try-on-buddy")
        XCTAssertEqual(heaviest.runner, "macOS")
        XCTAssertEqual(heaviest.share, 9.548 / 12.006, accuracy: 0.0001)
    }

    func testTheLinuxRateComesOffTheStandardRunnersRow() throws {
        XCTAssertEqual(try Self.items().first(where: \.isLinuxStandard)?.unitPrice, 0.006)
    }

    // MARK: The arithmetic

    /// A larger runner is billed from its first minute and never draws on the
    /// allowance, so its bill is not the allowance running out.
    func testALargerRunnersBillIsNotPastTheAllowance() throws {
        let items =
            try Self.items() + [
                ActionsItem(
                    repository: "try-on-buddy", sku: "Actions Linux 16-core", quantity: 100,
                    unitPrice: 0.042, gross: 4.2, discount: 0, net: 4.2)
            ]
        let report = GitHubActionsFeed.OwnerReport(
            owner: "radonforge", kind: .organization, items: items)
        let quota = GitHubActionsFeed.month(
            report, items,
            pricing: GitHubActionsFeed.MonthPricing(
                linuxRate: 0.006, covered: GitHubActionsFeed.coveredRunners(items)),
            now: Self.midOctober
        )
        .withPlan("free")
        XCTAssertEqual(quota.billed, 0)
        XCTAssertNil(quota.overrun)
        XCTAssertEqual(try XCTUnwrap(quota.usedPercent), 12.006 / 12 * 100, accuracy: 0.001)
    }

    /// A standard runner no list names, an ARM one here, is covered by being
    /// discounted; a larger runner never is.
    func testARunnerTheMonthDiscountedIsCovered() throws {
        let items =
            try Self.items() + [
                ActionsItem(
                    repository: "rustmail", sku: "Actions Linux ARM", quantity: 10, unitPrice: 0.005,
                    gross: 0.05, discount: 0.05, net: 0),
                ActionsItem(
                    repository: "try-on-buddy", sku: "Actions Linux 16-core", quantity: 100,
                    unitPrice: 0.042, gross: 4.2, discount: 0, net: 4.2),
            ]
        XCTAssertEqual(
            GitHubActionsFeed.coveredRunners(items),
            GitHubActionsFeed.documentedStandardRunners.union(["Actions Linux ARM"]))
    }

    /// A standard runner first run once the allowance is spent is never
    /// discounted, and its charge is still the overage.
    func testAStandardRunnerFirstRunPastTheAllowanceIsStillOverage() throws {
        let items =
            try Self.items() + [
                ActionsItem(
                    repository: "try-on-buddy", sku: "Actions Windows", quantity: 30, unitPrice: 0.010,
                    gross: 0.3, discount: 0, net: 0.3)
            ]
        let report = GitHubActionsFeed.OwnerReport(
            owner: "radonforge", kind: .organization, items: items)
        let quota = GitHubActionsFeed.month(
            report, items,
            pricing: GitHubActionsFeed.MonthPricing(
                linuxRate: 0.006, covered: GitHubActionsFeed.coveredRunners(items)),
            now: Self.midOctober)
        XCTAssertEqual(quota.billed, 0.3, accuracy: 0.0001)
        XCTAssertEqual(quota.overrun, .bills)
    }

    /// Past the allowance a covered runner's charge is the overage.
    func testACoveredRunnersChargeIsPastTheAllowance() throws {
        let items =
            try Self.items() + [
                ActionsItem(
                    repository: "try-on-buddy", sku: "Actions Linux", quantity: 50, unitPrice: 0.006,
                    gross: 0.3, discount: 0, net: 0.3)
            ]
        let report = GitHubActionsFeed.OwnerReport(
            owner: "radonforge", kind: .organization, items: items)
        let quota = GitHubActionsFeed.month(
            report, items,
            pricing: GitHubActionsFeed.MonthPricing(
                linuxRate: 0.006, covered: GitHubActionsFeed.coveredRunners(items)),
            now: Self.midOctober)
        XCTAssertEqual(quota.billed, 0.3, accuracy: 0.0001)
        XCTAssertEqual(quota.overrun, .bills)
    }

    /// September as measured: $12.006 of discount against 2,000 minutes at
    /// $0.006, which is the allowance spent.
    func testSeptemberSpentTheWholeAllowance() throws {
        let quota = Self.quota()
        XCTAssertEqual(try XCTUnwrap(quota.allowance), 12, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(quota.usedPercent), 100.05, accuracy: 0.001)
    }

    func testAPlanTheTableDoesNotNameHasNoGauge() {
        XCTAssertNil(Self.quota(plan: "legacy_medium").usedPercent)
        XCTAssertNil(Self.quota(plan: nil).usedPercent)
    }

    func testThePlanIsMatchedWithoutCase() {
        XCTAssertEqual(ActionsAllowance.minutes(plan: "Pro"), 3_000)
    }

    func testAMonthEndsAtMidnightUTCOnTheFirst() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let parts = utc.dateComponents([.year, .month, .day, .hour], from: Self.october.end)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour], [2026, 11, 1, 0])
        XCTAssertEqual(Self.october.minutes, 31 * 24 * 60)
        XCTAssertEqual(Self.october.month, 10)
    }

    // MARK: The budget

    /// radonforge's budgets as GitHub answered them on 2026-10-02.
    func testAZeroActionsBudgetThatBlocksStopsCI() throws {
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(
                    """
                    {"budgets":[
                    {"budget_type":"ProductPricing","budget_product_sku":"codespaces",
                     "budget_scope":"organization","budget_amount":0,
                     "prevent_further_usage":true},
                    {"budget_type":"ProductPricing","budget_product_sku":"actions",
                     "budget_scope":"organization","budget_amount":0,
                     "prevent_further_usage":true}],
                    "has_next_page":false,"total_count":2}
                    """.utf8)) as? [String: Any])
        XCTAssertEqual(GitHubActionsFeed.overrun(budgets: body), .stops)
    }

    func testABudgetWithRoomBills() {
        let body: [String: Any] = [
            "budgets": [
                [
                    "budget_product_sku": "actions", "budget_scope": "organization",
                    "budget_amount": 10, "prevent_further_usage": true,
                ]
            ]
        ]
        XCTAssertEqual(GitHubActionsFeed.overrun(budgets: body), .bills)
    }

    func testNoActionsBudgetSaysNothing() {
        let body: [String: Any] = [
            "budgets": [["budget_product_sku": "packages", "budget_amount": 0]]
        ]
        XCTAssertNil(GitHubActionsFeed.overrun(budgets: body))
    }

    /// A budget on one repository says nothing about the rest of the
    /// organisation, so it is no answer for the allowance.
    func testARepositoryBudgetIsNotTheOrganisations() {
        let body: [String: Any] = [
            "budgets": [
                [
                    "budget_product_sku": "actions", "budget_scope": "repository",
                    "budget_amount": 0, "prevent_further_usage": true,
                ]
            ]
        ]
        XCTAssertNil(GitHubActionsFeed.overrun(budgets: body))
    }

    // MARK: The scope

    /// Measured 2026-10-02, the token `gh` holds answered the account's own
    /// report with this header and a `404`.
    func testAClassicTokenWithoutUserLacksTheScope() {
        XCTAssertTrue(
            GitHubActionsFeed.lacksUserScope(
                "admin:public_key, delete:packages, gist, read:org, read:packages, repo"))
        XCTAssertFalse(GitHubActionsFeed.lacksUserScope("read:org, repo, user"))
    }

    /// A fine-grained token sends no scopes header, so its refusal is not
    /// put down to a scope it does not have.
    func testARefusalWithNoScopesHeaderIsNotPutDownToTheScope() {
        XCTAssertFalse(GitHubActionsFeed.lacksUserScope(nil))
    }

    // MARK: A round that read some owners

    func testAnOwnerWhoseReportFailedKeepsItsLastQuota() throws {
        let previous = Self.reading([Self.quota(id: "radonforge"), Self.quota(id: "obliolabs")])
        var fresh = Self.reading([Self.quota(spent: 1, id: "obliolabs")])
        fresh.unread = ["radonforge"]
        let merged = try XCTUnwrap(ActionsReading.merged(fresh, over: previous))
        XCTAssertEqual(merged.quotas.map(\.id), ["obliolabs", "radonforge"])
        XCTAssertEqual(merged.quotas.first?.spent, 1)
    }

    /// An owner the fresh round read without usage, or could not see at all,
    /// is not brought back from the round before.
    func testAnOwnerTheRoundAnsweredForIsNotBroughtBack() throws {
        let previous = Self.reading([Self.quota(id: "radonforge")])
        let fresh = Self.reading([])
        XCTAssertEqual(try XCTUnwrap(ActionsReading.merged(fresh, over: previous)).quotas, [])
    }

    func testLastMonthsQuotaIsNotCarriedIntoThisOne() throws {
        let september = ActionsReading(
            quotas: [Self.quota()], ownNeedsUserScope: false,
            resetsAt: Self.october.start, monthMinutes: 30 * 24 * 60)
        var fresh = Self.reading([])
        fresh.unread = ["radonforge"]
        XCTAssertEqual(try XCTUnwrap(ActionsReading.merged(fresh, over: september)).quotas, [])
    }

    func testABillThatWouldNotAnswerKeepsTheLastOne() {
        let previous = Self.reading([Self.quota()])
        XCTAssertEqual(ActionsReading.merged(nil, over: previous), previous)
    }

    // MARK: Visibility

    /// The names are the vendor's, so they travel as variables and never in
    /// the document itself.
    func testRepositoryNamesTravelAsVariables() {
        let (query, variables) = GitHubActionsFeed.visibilityDocument([
            RepositoryKey(owner: "radonforge", name: "try-on-buddy"),
            RepositoryKey(owner: "rustmailapp", name: "rustmail"),
        ])
        XCTAssertFalse(query.contains("try-on-buddy"))
        XCTAssertTrue(query.contains("r1: repository(owner: $o1, name: $n1) { isPrivate }"))
        XCTAssertEqual(variables["o1"], "rustmailapp")
        XCTAssertEqual(variables["n0"], "try-on-buddy")
    }
}

extension ActionsQuota {
    fileprivate func withPlan(_ plan: String) -> Self {
        Self(
            id: id, owner: owner, plan: plan, linuxRate: linuxRate, minutes: minutes,
            spent: spent, billed: billed, heaviest: heaviest, overrun: overrun, readAt: readAt)
    }
}
