import Foundation

/// The rates every provider's events are priced at, resolved by provider id.
///
/// The readers each hold their own half of this — `ClaudeCodeAdapter` the
/// Anthropic table, `CodexAdapter` the OpenAI one — because an event is priced
/// where it is parsed. A reading taken *after* the events, across providers and
/// out of the archive, has no adapter to ask, so this is the same precedence
/// held once for all of them: it resolves through `Pricing.price` and
/// `OpenAIPricing.price` rather than beside them, so there is still exactly one
/// lookup per vendor and no rate of its own.
struct ProviderPricing: Sendable {
    private let override: PricingTable
    private let anthropic: PricingTable?
    private let openai: PricingTable?

    init(override: [String: ModelPricing], catalog: PriceCatalog?) {
        self.override = PricingTable(override)
        self.anthropic = catalog?.table(for: .anthropic)
        self.openai = catalog?.table(for: .openai)
    }

    /// The seed's rates alone, which is what a first run with no network
    /// prices at.
    static let seed = Self(override: [:], catalog: nil)

    func price(provider: String, model: String) -> ModelPricing? {
        switch provider {
        case ProviderID.codex:
            OpenAIPricing.price(for: model, override: override, catalog: openai)
        default:
            Pricing.price(for: model, override: override, catalog: anthropic)
        }
    }

    /// What the cache reads of one model would have cost as fresh input,
    /// less what they did cost, at today's list price.
    ///
    /// Zero for a model no source prices, which is the same answer the reader
    /// gave for its cost; a rate where a cache read costs more than input
    /// saves nothing rather than a negative amount.
    func cacheSaving(provider: String, model: String, cacheReadTokens: Int) -> Decimal {
        guard cacheReadTokens > 0, let rates = price(provider: provider, model: model) else {
            return 0
        }
        let perMTok = max(rates.inputPerMTok - rates.cacheReadPerMTok, 0)
        var raw = Decimal(cacheReadTokens) * perMTok / Self.tokensPerRate
        var rounded = Decimal()
        NSDecimalRound(&rounded, &raw, Self.savingScale, .bankers)
        return rounded
    }

    /// Rates are quoted per million tokens.
    private static let tokensPerRate = Decimal(1_000_000)
    /// The scale `Pricing.cost` rounds a cost to, so a saving and the cost
    /// beside it are rounded alike.
    private static let savingScale = 6
}

/// How much of a window's input the prompt cache answered, and what that saved.
///
/// **The input side is every token sent, not `inputTokens`.** Claude Code logs
/// fresh input, cache reads and cache writes as three counters, and Codex's
/// `CodexAdapter` splits its gross input into fresh and cached before it
/// reaches the archive, so the share is reads over the sum of the three for
/// both — output has nothing to do with the cache and would dilute it.
///
/// **The saving is at list price and priced when read**, not when the tokens
/// were logged: the archive keeps the counters and not a saving, so a window
/// of thirty days is priced at today's rates. That is the reading's own
/// wording — `at list price` — and it is also why a subscription user, who is
/// billed none of it, can read it at all.
struct CacheReading: Sendable, Equatable {
    var cacheReadTokens: Int = 0
    /// Fresh input, cache reads and cache writes together.
    var inputSideTokens: Int = 0
    var saved: Decimal = 0

    static let none = Self()

    /// Reads over everything sent, nil for a window that sent nothing — a
    /// share of zero input is not a share of zero.
    var share: Double? {
        inputSideTokens > 0 ? Double(cacheReadTokens) / Double(inputSideTokens) : nil
    }

    mutating func add(_ other: Self) {
        cacheReadTokens += other.cacheReadTokens
        inputSideTokens += other.inputSideTokens
        saved += other.saved
    }

    mutating func add(
        provider: String, model: String, totals: UsageHistoryTotals, pricing: ProviderPricing
    ) {
        cacheReadTokens += totals.cacheReadTokens
        inputSideTokens += totals.inputTokens + totals.cacheReadTokens + totals.cacheCreationTokens
        saved += pricing.cacheSaving(
            provider: provider, model: model, cacheReadTokens: totals.cacheReadTokens)
    }

    /// One reading across today's slices, model by model.
    static func of(_ slices: [ProviderSlice], pricing: ProviderPricing) -> Self {
        var reading = Self.none
        for slice in slices {
            for model in slice.models {
                reading.add(
                    provider: slice.id, model: model.model, totals: model.totals, pricing: pricing)
            }
        }
        return reading
    }
}
