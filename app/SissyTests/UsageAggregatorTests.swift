import XCTest

@testable import Sissy

/// The fan-in rules, which are about what the aggregator does with what
/// providers report and not about reading a tree — so the providers here are
/// stubs that report on demand.
///
/// Two of them had never been executed outside the engine that uses them: the
/// day-over-day delta that waits for every provider, and the pair
/// `currentReading()` hands a replay.
final class UsageAggregatorTests: XCTestCase {
    private func totals(_ tokens: Int, _ cost: Int = 0) -> DayTotals {
        DayTotals(totalTokens: tokens, totalCost: Decimal(cost))
    }

    func testTheCombinedTotalIsEveryProvidersSum() async {
        let first = StubProvider(id: "a")
        let second = StubProvider(id: "b")
        let aggregator = UsageAggregator(providers: [first, second])
        let readings = ReadingLog()
        await aggregator.start { today, prev, slices in readings.record(today, prev, slices) }

        await first.emit(today: totals(10, 1))
        await second.emit(today: totals(5, 2))

        XCTAssertEqual(readings.last?.today.totalTokens, 15)
        XCTAssertEqual(readings.last?.today.totalCost, Decimal(3))
    }

    /// A provider still warming has no yesterday, and a delta measured against
    /// a half-populated one is worse than no delta at all.
    func testYesterdayIsWithheldUntilEveryProviderHasOne() async {
        let first = StubProvider(id: "a")
        let second = StubProvider(id: "b")
        let aggregator = UsageAggregator(providers: [first, second])
        let readings = ReadingLog()
        await aggregator.start { today, prev, slices in readings.record(today, prev, slices) }

        await first.emit(today: totals(10), prev: totals(4))
        await second.emit(today: totals(5), prev: nil)

        XCTAssertNil(readings.last?.prev, "one provider's yesterday was reported as everyone's")

        await second.emit(today: totals(5), prev: totals(6))

        XCTAssertEqual(readings.last?.prev?.totalTokens, 10)
    }

    /// What a replayed frame is built from. The totals and the breakdown are
    /// taken in one hop precisely so they cannot describe two moments.
    func testCurrentReadingPairsTheTotalsWithTheBreakdownTheyCameFrom() async {
        let first = StubProvider(id: "a")
        let second = StubProvider(id: "b")
        let aggregator = UsageAggregator(providers: [first, second])
        await aggregator.start { _, _, _ in }
        await first.emit(today: totals(10))
        await second.emit(today: totals(5))

        let reading = await aggregator.currentReading()

        XCTAssertEqual(reading.today.totalTokens, 15)
        XCTAssertEqual(reading.slices.map(\.id), ["a", "b"])
        XCTAssertEqual(reading.slices.reduce(0) { $0 + $1.tokens }, reading.today.totalTokens)
    }

    /// A provider that has spent nothing today is left out of the breakdown, so
    /// the panel shows the day's actual split instead of a stale `$0` row — and
    /// the scalars still count it.
    func testAProviderWithNothingTodayIsNotInTheBreakdown() async {
        let first = StubProvider(id: "a")
        let second = StubProvider(id: "b")
        let aggregator = UsageAggregator(providers: [first, second])
        await aggregator.start { _, _, _ in }
        await first.emit(today: totals(10))
        await second.emit(today: totals(0))

        let reading = await aggregator.currentReading()

        XCTAssertEqual(reading.slices.map(\.id), ["a"])
        XCTAssertEqual(reading.today.totalTokens, 10)
    }

    func testStoppingTheAggregatorStopsEveryProvider() async {
        let first = StubProvider(id: "a")
        let second = StubProvider(id: "b")
        let aggregator = UsageAggregator(providers: [first, second])
        await aggregator.start { _, _, _ in }

        await aggregator.stop()

        let firstStopped = await first.stopped
        let secondStopped = await second.stopped
        XCTAssertTrue(firstStopped)
        XCTAssertTrue(secondStopped)
    }
}

/// A provider with no tree behind it, which reports what a test tells it to.
private actor StubProvider: UsageProvider {
    nonisolated let id: String
    private(set) var stopped = false
    private var onChange: (@Sendable (DayTotals, DayTotals?) async -> Void)?
    private var today = DayTotals(totalTokens: 0, totalCost: 0)
    private var prev: DayTotals?

    init(id: String) {
        self.id = id
    }

    func start(onChange: @Sendable @escaping (DayTotals, DayTotals?) async -> Void) async {
        self.onChange = onChange
    }

    func stop() async {
        stopped = true
    }

    func current() async -> (today: DayTotals, prev: DayTotals?) { (today, prev) }

    nonisolated func filesWatched() -> Int { 0 }

    func isWarm() async -> Bool { true }

    func applyPriceCatalog(_ catalog: PriceCatalog) async {}

    /// Report a reading, the way a reader does when its tree has changed.
    func emit(today: DayTotals, prev: DayTotals? = nil) async {
        self.today = today
        self.prev = prev
        await onChange?(today, prev)
    }
}

/// The readings the aggregator fanned out, newest last. Written from whatever
/// task the emit came in on, so it is read back behind a lock.
private final class ReadingLog: @unchecked Sendable {
    private let lock = NSLock()
    private var readings: [(today: DayTotals, prev: DayTotals?, slices: [ProviderSlice])] = []

    func record(_ today: DayTotals, _ prev: DayTotals?, _ slices: [ProviderSlice]) {
        lock.withLock { readings.append((today, prev, slices)) }
    }

    var last: (today: DayTotals, prev: DayTotals?, slices: [ProviderSlice])? {
        lock.withLock { readings.last }
    }
}
