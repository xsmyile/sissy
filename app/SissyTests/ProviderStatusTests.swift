import XCTest

@testable import Sissy

/// The status feed, the poll around it, and the row it becomes.
///
/// The two payloads below are the real replies, recorded 2026-09-15. OpenAI's
/// is kept whole for one field in particular: its `page.updated_at` reads
/// `2026-07-09`, two months before the day it was fetched, because the vendor
/// moves it on incidents rather than on polls. A reading that dated itself from
/// the payload would call a healthy provider two months stale.
final class ProviderStatusTests: XCTestCase {
    private static let claudePayload = """
        {"page":{"id":"tymt9n04zgry","name":"Claude","url":"https://status.claude.com",
        "time_zone":"Etc/UTC","updated_at":"2026-09-15T12:50:33.250Z"},
        "status":{"indicator":"none","description":"All Systems Operational"}}
        """
    private static let openAIPayload = """
        {"page":{"id":"01JMDK9XYNY6RXSED6SDWW50WY","name":"OpenAI",
        "url":"https://status.openai.com/","updated_at":"2026-07-09T19:25:56Z"},
        "status":{"description":"All Systems Operational","indicator":"none"}}
        """
    private static let fetchedAt = Date(timeIntervalSince1970: 1_789_300_000)

    private func parse(_ payload: String, at when: Date = fetchedAt) throws -> ProviderStatusReading {
        try StatuspageFeed.parse(Data(payload.utf8), checkedAt: when)
    }

    // MARK: The feed

    func testBothVendorsAnswerTheSameShape() throws {
        for payload in [Self.claudePayload, Self.openAIPayload] {
            let reading = try parse(payload)
            XCTAssertEqual(reading.indicator, .operational)
            XCTAssertEqual(reading.description, "All Systems Operational")
        }
    }

    func testAgeIsTheFetchAndNeverTheFeedsOwnTimestamp() throws {
        let reading = try parse(Self.openAIPayload)
        XCTAssertEqual(reading.checkedAt, Self.fetchedAt)
    }

    func testAnIndicatorThisBuildDoesNotKnowIsUnknownRatherThanAFailure() throws {
        let payload = """
            {"status":{"indicator":"apocalyptic","description":"Something New"}}
            """
        let reading = try parse(payload)
        XCTAssertEqual(reading.indicator, .unknown)
        XCTAssertEqual(reading.description, "Something New")
    }

    func testDegradedLevelsAreTheOnesWorthColouring() {
        XCTAssertEqual(ProviderStatusIndicator(page: "minor"), .minor)
        XCTAssertEqual(ProviderStatusIndicator(page: "critical"), .critical)
        XCTAssertTrue(ProviderStatusIndicator(page: "major").isDegraded)
        XCTAssertFalse(ProviderStatusIndicator(page: "none").isDegraded)
        XCTAssertFalse(ProviderStatusIndicator(page: "gibberish").isDegraded)
    }

    func testAPayloadWithNoStatusBlockThrows() {
        XCTAssertThrowsError(try parse("{\"page\":{}}"))
    }

    func testEveryMeteredVendorHasAFeedToRead() {
        XCTAssertNotNil(ProviderStatusFeed.root(for: ProviderID.claudeCode))
        XCTAssertNotNil(ProviderStatusFeed.root(for: ProviderID.codex))
        XCTAssertNil(ProviderStatusFeed.root(for: "something-else"))
    }

    func testTheRequestGoesToStatuspagesOwnEndpoint() throws {
        let root = try XCTUnwrap(ProviderStatusFeed.root(for: ProviderID.claudeCode))
        XCTAssertEqual(
            StatuspageFeed.statusURL(root: root).absoluteString,
            "https://status.claude.com/api/v2/status.json")
    }

    // MARK: The poll

    /// Answers whatever it is told to, and counts how often it was asked.
    private final class Feed: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: Result<ProviderStatusReading, any Error>
        private(set) var calls = 0

        init(_ outcome: Result<ProviderStatusReading, any Error>) { self.outcome = outcome }

        func answer(_ next: Result<ProviderStatusReading, any Error>) {
            lock.withLock { outcome = next }
        }

        func fetch() throws -> ProviderStatusReading {
            let current = lock.withLock {
                calls += 1
                return outcome
            }
            return try current.get()
        }
    }

    private struct Unreachable: Error {}

    private func reading(
        _ indicator: ProviderStatusIndicator, _ description: String, at when: Date = fetchedAt
    ) -> ProviderStatusReading {
        ProviderStatusReading(indicator: indicator, description: description, checkedAt: when)
    }

    private func makeMonitor(_ feed: Feed) -> ProviderStatusMonitor {
        ProviderStatusMonitor(providers: [ProviderID.claudeCode]) { _ in try feed.fetch() }
    }

    func testAReadingReachesThePublishedMap() async {
        let feed = Feed(.success(reading(.minor, "Partially Degraded Service")))
        let monitor = makeMonitor(feed)
        _ = await monitor.refreshOnce {}
        XCTAssertEqual(
            monitor.currentStatus()[ProviderID.claudeCode]?.indicator, .minor)
    }

    func testOnlyAChangedReadingCostsAFrame() async {
        let feed = Feed(.success(reading(.operational, "All Systems Operational")))
        let monitor = makeMonitor(feed)
        let changes = Counter()
        _ = await monitor.refreshOnce { changes.bump() }
        _ = await monitor.refreshOnce { changes.bump() }
        XCTAssertEqual(changes.value, 1)
        XCTAssertEqual(feed.calls, 2)
    }

    func testAFailedFetchKeepsTheLastReadingAndItsAge() async {
        let good = reading(.operational, "All Systems Operational")
        let feed = Feed(.success(good))
        let monitor = makeMonitor(feed)
        _ = await monitor.refreshOnce {}
        feed.answer(.failure(Unreachable()))
        let changes = Counter()
        _ = await monitor.refreshOnce { changes.bump() }
        XCTAssertEqual(monitor.currentStatus()[ProviderID.claudeCode], good)
        XCTAssertEqual(changes.value, 0)
    }

    /// A feed that has never answered is unknown, and stays at the one age it
    /// was first found unreachable at: republishing it every five minutes
    /// would move an age that dates no reading.
    func testAFeedThatNeverAnsweredIsUnknownAndDoesNotKeepMoving() async {
        let feed = Feed(.failure(Unreachable()))
        let monitor = makeMonitor(feed)
        _ = await monitor.refreshOnce {}
        let first = monitor.currentStatus()[ProviderID.claudeCode]
        XCTAssertEqual(first?.indicator, .unknown)
        XCTAssertNil(first?.description)
        let changes = Counter()
        _ = await monitor.refreshOnce { changes.bump() }
        XCTAssertEqual(monitor.currentStatus()[ProviderID.claudeCode], first)
        XCTAssertEqual(changes.value, 0)
    }

    func testStoppingTakesTheRowsWithIt() async {
        let feed = Feed(.success(reading(.major, "Major Service Outage")))
        let monitor = makeMonitor(feed)
        _ = await monitor.refreshOnce {}
        await monitor.stop()
        XCTAssertTrue(monitor.currentStatus().isEmpty)
    }

    func testAProviderWithNoFeedIsNeverAskedForOne() async {
        let feed = Feed(.success(reading(.operational, "All Systems Operational")))
        let monitor = ProviderStatusMonitor(providers: ["no-such-provider"]) { _ in try feed.fetch() }
        _ = await monitor.refreshOnce {}
        XCTAssertEqual(feed.calls, 0)
        XCTAssertTrue(monitor.currentStatus().isEmpty)
    }

    /// The cadence is the whole of what agent activity decides, so it is worth
    /// pinning: a Mac being worked on is polled on the short interval, one
    /// that has seen nothing for an hour on the long one.
    func testTheIdleMacIsPolledMoreSlowly() async {
        let feed = Feed(.success(reading(.operational, "All Systems Operational")))
        let monitor = makeMonitor(feed)
        let idle = await monitor.refreshOnce {}
        XCTAssertGreaterThanOrEqual(idle, ProviderStatusMonitor.idleRefreshInterval)
        monitor.noteActivity()
        let working = await monitor.refreshOnce {}
        XCTAssertLessThan(working, ProviderStatusMonitor.idleRefreshInterval)
        XCTAssertGreaterThanOrEqual(working, ProviderStatusMonitor.refreshInterval)
    }

    // MARK: The row

    private func row(_ status: [String: ProviderStatusReading]) -> UsagePanelSnapshot.ProviderRow? {
        let frame = FrameData(
            tokens: 10,
            cost: 1,
            burn: nil,
            providers: [ProviderSlice(id: ProviderID.claudeCode, tokens: 10, cost: 1)],
            keepAwake: .off,
            history: nil,
            providerStatus: status)
        return UsagePanelSnapshot.make(frame: frame).providers.first
    }

    func testTheRowCarriesTheVendorsOwnSentence() throws {
        let status = try XCTUnwrap(
            row([ProviderID.claudeCode: reading(.minor, "Partially Degraded Service")])?.status)
        XCTAssertEqual(status.label, "Partially Degraded Service")
        XCTAssertEqual(status.indicator, .minor)
        XCTAssertEqual(status.checkedAt, Self.fetchedAt)
    }

    func testAProviderWithNoReadingHasNoRow() {
        XCTAssertNil(row([:])?.status)
    }

    /// The unavailable row says so and carries no age: the age would date a
    /// fetch that produced nothing, which reads as a reading that is merely
    /// old.
    func testTheUnavailableRowIsWordedAndUndated() throws {
        let status = try XCTUnwrap(
            row([ProviderID.claudeCode: .unavailable(at: Self.fetchedAt)])?.status)
        XCTAssertEqual(status.label, "Status unavailable")
        XCTAssertNil(status.checkedAt)
    }

    func testTheAgeIsWordedFromSissysOwnClock() {
        XCTAssertEqual(
            UsageFormat.statusAge(
                checkedAt: Self.fetchedAt, now: Self.fetchedAt.addingTimeInterval(120)),
            "checked 2m ago")
    }

    /// The colour on the Overview's provider name cannot be the only carrier
    /// of this, so the sentence behind it is asserted here — it is what the
    /// tooltip and VoiceOver both read.
    func testTheSummaryNamesTheProviderAndTheSentence() {
        XCTAssertEqual(
            UsageFormat.statusSummary(
                provider: ProviderID.codex, label: "Major Service Outage", checkedAt: nil),
            "Codex · Major Service Outage")
    }

    func testABlankSentenceIsNoSentence() {
        XCTAssertEqual(UsageFormat.statusLabel("   "), "Status unavailable")
        XCTAssertEqual(UsageFormat.statusLabel(nil), "Status unavailable")
    }
}

/// Counts callbacks from whichever isolation they arrive on.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
