import XCTest

@testable import Sissy

/// What a subscriber cannot get anywhere else: the month's API-equivalent
/// usage against what the plan cost. The rules that matter are about what the
/// reading is allowed to *claim* — a month the archive only half covers, and a
/// price nobody entered, both have to read as questions rather than verdicts.
final class SubscriptionMonthTests: XCTestCase {
    private var root: URL!
    private let cal = Calendar.current

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-month-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func monthStart(_ now: Date) throws -> Date {
        try XCTUnwrap(cal.date(from: cal.dateComponents([.year, .month], from: now)))
    }

    private func write(provider: String, day: Date, cost: String) throws {
        try UsageHistoryStore.save(
            UsageHistoryDay(
                day: UsageReaderShared.dayFormatter.string(from: day),
                provider: provider,
                updatedAt: Date(),
                totals: [
                    UsageHistoryRow(model: "opus", project: nil):
                        UsageHistoryTotals(inputTokens: 10, cost: Decimal(string: cost) ?? 0)
                ]
            ),
            in: root
        )
    }

    // MARK: The archive's half

    /// The month is the calendar's, because no vendor publishes a renewal
    /// date anywhere Sissy can read. A day in the month before it is not part
    /// of this month's answer however recently it was written.
    func testTheDayBeforeTheFirstIsNotInThisMonth() throws {
        let now = Date()
        let start = try monthStart(now)
        let before = try XCTUnwrap(cal.date(byAdding: .day, value: -1, to: start))
        try write(provider: "claude-code", day: before, cost: "99")
        try write(provider: "claude-code", day: start, cost: "1.50")

        let months = UsageHistoryStore.monthToDate(in: root, now: now)

        XCTAssertEqual(months["claude-code"]?.cost, Decimal(string: "1.50"))
    }

    /// Each provider answers for itself, because the plan price it is compared
    /// against is its own.
    func testEachProviderIsCountedOnItsOwn() throws {
        let now = Date()
        let start = try monthStart(now)
        try write(provider: "claude-code", day: start, cost: "10")
        try write(provider: "codex", day: start, cost: "4")

        let months = UsageHistoryStore.monthToDate(in: root, now: now)

        XCTAssertEqual(months["claude-code"]?.cost, 10)
        XCTAssertEqual(months["codex"]?.cost, 4)
    }

    /// A provider with no day inside the month gets no entry at all. Zero
    /// beside a plan price is a verdict on the plan that nobody measured, and
    /// it is what every install would show on the day it was made.
    func testAProviderWithNoDayThisMonthGetsNoEntry() throws {
        let now = Date()
        let start = try monthStart(now)
        let before = try XCTUnwrap(cal.date(byAdding: .day, value: -1, to: start))
        try write(provider: "codex", day: before, cost: "5")

        let months = UsageHistoryStore.monthToDate(in: root, now: now)

        XCTAssertNil(months["codex"])
    }

    // MARK: What the reading is allowed to claim

    /// The label is the guard against the misreading this feature invites: a
    /// fortnight of usage held up against a whole month's price looks like a
    /// plan that did not pay for itself.
    func testAMonthTheArchiveDoesNotReachTheStartOfSaysSince() throws {
        let start = try monthStart(Date())
        let later = try XCTUnwrap(cal.date(byAdding: .day, value: 9, to: start))

        XCTAssertEqual(
            UsageFormat.monthLabel(earliestDay: start, monthStart: start), "This month")
        XCTAssertTrue(
            UsageFormat.monthLabel(earliestDay: later, monthStart: start).hasPrefix("Since "))
    }

    /// Without a price there is no comparison, and the row says so by naming
    /// only what the usage came to.
    func testWithoutAPlanPriceTheRowNamesTheUsageAlone() {
        XCTAssertEqual(
            UsageFormat.subscriptionMonth(cost: Decimal(string: "312.40")!, planPrice: nil),
            "$312.40 of usage"
        )
        XCTAssertEqual(
            UsageFormat.subscriptionMonth(
                cost: Decimal(string: "312.40")!, planPrice: Decimal(string: "200")!),
            "$312.40 of usage on a $200.00 plan"
        )
    }

    /// `nil` and `false` are different answers: nobody asked, against asked
    /// and not yet. Only the second may ever colour the row.
    func testWhetherThePlanPaidForItselfIsUnansweredWithoutAPrice() throws {
        let start = try monthStart(Date())
        func month(cost: String, price: Decimal?) -> SubscriptionMonth {
            SubscriptionMonth(
                cost: Decimal(string: cost)!, planPrice: price,
                earliestDay: start, monthStart: start)
        }

        XCTAssertNil(month(cost: "312", price: nil).returnedItsPrice)
        XCTAssertEqual(month(cost: "312", price: 200).returnedItsPrice, true)
        XCTAssertEqual(month(cost: "12", price: 200).returnedItsPrice, false)
        XCTAssertEqual(month(cost: "200", price: 200).returnedItsPrice, true)
    }

    // MARK: The price the user typed

    /// A price that will not parse, and one that parses to nothing, are both
    /// "no price" rather than a $0 plan — an answer nobody gave.
    func testAPriceThatIsNotAPositiveAmountIsNoPrice() {
        var config = ServerConfig.defaults
        config.planPrices = [
            "claude-code": "200", "codex": "  20.50  ", "a": "", "b": "0", "c": "nope", "d": "-5",
        ]

        XCTAssertEqual(config.planPrice(forProvider: "claude-code"), 200)
        XCTAssertEqual(config.planPrice(forProvider: "codex"), Decimal(string: "20.50"))
        for absent in ["a", "b", "c", "d", "missing"] {
            XCTAssertNil(config.planPrice(forProvider: absent), "\(absent) named a price")
        }
    }

    /// Whichever separator the user reached for means the same thing. Measured
    /// on a Mac whose region makes the comma the decimal separator, which is
    /// where the naive parse this replaced went wrong.
    func testEitherDecimalSeparatorMeansTheSameAmount() {
        XCTAssertEqual(ServerConfig.parsePlanPrice("200.50"), Decimal(string: "200.50"))
        XCTAssertEqual(ServerConfig.parsePlanPrice("200,50"), Decimal(string: "200.50"))
        XCTAssertEqual(ServerConfig.parsePlanPrice(" 200 "), 200)
        XCTAssertEqual(ServerConfig.parsePlanPrice("0.75"), Decimal(string: "0.75"))
    }

    /// The failure that made this parser necessary. `Decimal(string:)` takes
    /// the prefix it understands and answers with it, so a four-figure plan
    /// reads as one dollar — and a $1 plan is covered by the first turn of
    /// every month, which is the panel announcing something nobody measured.
    func testAThousandsSeparatorIsRefusedRatherThanReadAsOne() {
        XCTAssertEqual(Decimal(string: "1,234.56"), 1, "the trap this test exists for moved")

        XCTAssertNil(ServerConfig.parsePlanPrice("1,234.56"))
        XCTAssertNil(ServerConfig.parsePlanPrice("1.234,56"))
    }

    /// Anything that is not digits and at most one separator is refused whole
    /// rather than partly read.
    func testAValueThatIsNotAPriceIsRefusedWhole() {
        for raw in ["$200", "2e3", "20 0", "200.505", "abc", "", "   ", "-5", "0", "0.00", ".5"] {
            XCTAssertNil(ServerConfig.parsePlanPrice(raw), "\(raw.debugDescription) read as a price")
        }
    }

    /// The frame carries the month on the provider's own slice rather than
    /// beside it, so a row can never pair one provider's month with another's
    /// totals.
    func testTheMonthRidesOnTheSliceItBelongsTo() throws {
        let start = try monthStart(Date())
        let month = SubscriptionMonth(
            cost: 312, planPrice: 200, earliestDay: start, monthStart: start)

        let frame = FrameBuilder.build(
            today: DayTotals(totalTokens: 2, totalCost: 2),
            hoursElapsed: 1,
            providers: [
                ProviderSlice(id: "claude-code", tokens: 1, cost: 1),
                ProviderSlice(id: "codex", tokens: 1, cost: 1),
            ],
            months: ["claude-code": month]
        )

        XCTAssertEqual(frame.providers.first { $0.id == "claude-code" }?.month, month)
        XCTAssertNil(frame.providers.first { $0.id == "codex" }?.month)
    }

    /// The whole way through: a month on the slice reaches the provider page
    /// already worded, and a provider without one grows no block at all.
    func testTheProviderPageWordsTheMonthAndOmitsItWhenThereIsNone() throws {
        let start = try monthStart(Date())
        let frame = FrameBuilder.build(
            today: DayTotals(totalTokens: 2, totalCost: 2),
            hoursElapsed: 1,
            providers: [
                ProviderSlice(id: "claude-code", tokens: 1, cost: 1),
                ProviderSlice(id: "codex", tokens: 1, cost: 1),
            ],
            months: [
                "claude-code": SubscriptionMonth(
                    cost: Decimal(string: "312.40")!, planPrice: 200,
                    earliestDay: start, monthStart: start)
            ]
        )

        let rows = UsagePanelSnapshot.make(frame: frame).providers

        let claude = try XCTUnwrap(rows.first { $0.id == "claude-code" }?.month)
        XCTAssertEqual(claude.label, "This month")
        XCTAssertEqual(claude.amount, "$312.40 of usage on a $200.00 plan")
        XCTAssertEqual(claude.returnedItsPrice, true)
        XCTAssertNil(rows.first { $0.id == "codex" }?.month)
    }
}
