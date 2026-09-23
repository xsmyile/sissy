import XCTest

@testable import Sissy

/// What the cache answered and saved, priced after the events.
final class CacheReadingTests: XCTestCase {
    private static let model = "cache-test-model"

    /// One model name priced differently by each vendor's table, so which
    /// table answered is visible in the figure.
    private let pricing = ProviderPricing(
        override: [:],
        catalog: PriceCatalog(
            fetchedAt: Date(),
            anthropic: [
                model: ModelPricing(
                    inputPerMTok: 3, outputPerMTok: 15, cacheReadPerMTok: 0.3,
                    cacheCreationPerMTok: 3.75)
            ],
            openai: [
                model: ModelPricing(
                    inputPerMTok: 1.25, outputPerMTok: 10, cacheReadPerMTok: 0.125,
                    cacheCreationPerMTok: 0)
            ]))

    private func totals(input: Int = 0, cacheRead: Int = 0, cacheCreation: Int = 0)
        -> UsageHistoryTotals
    {
        UsageHistoryTotals(
            inputTokens: input, outputTokens: 1_000, cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreation, cost: 0)
    }

    func testAClaudeReadSavesTheGapBetweenInputAndCacheReadRates() {
        XCTAssertEqual(
            pricing.cacheSaving(
                provider: ProviderID.claudeCode, model: Self.model, cacheReadTokens: 1_000_000),
            Decimal(string: "2.7"))
    }

    func testACodexReadIsPricedAtTheOpenAITable() {
        XCTAssertEqual(
            pricing.cacheSaving(
                provider: ProviderID.codex, model: Self.model, cacheReadTokens: 1_000_000),
            Decimal(string: "1.125"))
    }

    /// A provider id with no vendor table of its own is not priced at
    /// Anthropic's, even for a model name that table carries.
    func testAnUnknownProviderSavesNothing() {
        XCTAssertEqual(
            pricing.cacheSaving(provider: "unknown-cli", model: Self.model, cacheReadTokens: 1_000_000),
            0)
    }

    /// The reader billed an unpriced model at $0, so the cache saved it $0
    /// too; anything else would be a saving on money nobody was charged.
    func testAModelNoSourcePricesSavesNothing() {
        XCTAssertEqual(
            pricing.cacheSaving(
                provider: ProviderID.claudeCode, model: "no-such-model", cacheReadTokens: 1_000),
            0)
    }

    /// Output is not sent, so it cannot be answered from the cache and must
    /// not dilute the share.
    func testTheShareIsReadsOverEverythingSentAndNothingElse() throws {
        var reading = CacheReading.none
        reading.add(
            provider: ProviderID.claudeCode, model: Self.model,
            totals: totals(input: 10, cacheRead: 80, cacheCreation: 10), pricing: pricing)

        XCTAssertEqual(try XCTUnwrap(reading.share), 0.8, accuracy: 1e-9)
    }

    func testAWindowThatSentNothingHasNoShare() {
        XCTAssertNil(CacheReading.none.share)
    }

    func testTodayIsSummedAcrossEverySliceModelByModel() {
        let frame = FrameBuilder.build(
            today: DayTotals(totalTokens: 0, totalCost: 0),
            hoursElapsed: 1,
            providers: [
                ProviderSlice(
                    id: ProviderID.claudeCode, tokens: 0, cost: 0,
                    models: [
                        ModelTotals(model: Self.model, totals: totals(cacheRead: 1_000_000))
                    ]),
                ProviderSlice(
                    id: ProviderID.codex, tokens: 0, cost: 0,
                    models: [
                        ModelTotals(
                            model: Self.model, totals: totals(input: 1_000_000, cacheRead: 1_000_000))
                    ]),
            ],
            pricing: pricing)

        XCTAssertEqual(frame.cache.cacheReadTokens, 2_000_000)
        XCTAssertEqual(frame.cache.inputSideTokens, 3_000_000)
        XCTAssertEqual(frame.cache.saved, Decimal(string: "3.825"))
    }
}
