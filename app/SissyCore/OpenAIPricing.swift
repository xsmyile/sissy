import Foundation

/// OpenAI token pricing. Same three-source precedence as `Pricing` — override,
/// runtime LiteLLM catalog, embedded seed — and no hand-maintained table.
///
/// Codex emits `reasoning_output_tokens` alongside `output_tokens`, but
/// `output_tokens` is already gross (it includes the reasoning portion);
/// `reasoning_output_tokens` is a sub-breakdown for observability, not an
/// additive counter. `CodexUsageReader` therefore passes `output_tokens`
/// straight through — same convention ccusage uses. Cached input is a separate
/// billable channel (`cacheReadPerMTok`); Codex rollouts report no
/// cache-creation tokens, so `cacheCreationPerMTok` stays 0 by convention.
enum OpenAIPricing {
    static func price(
        for model: String,
        override: [String: ModelPricing]? = nil,
        catalog: PricingTable? = nil
    ) -> ModelPricing? {
        if let override, let p = matchPricingOverride(override, model: model) { return p }
        if let catalog, let p = catalog.match(model) { return p }
        return PricingSeed.openai.match(model)
    }

    static func cost(
        model: String,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheCreation: Int = 0,
        override: [String: ModelPricing]? = nil,
        catalog: PricingTable? = nil
    ) -> Decimal {
        guard let p = price(for: model, override: override, catalog: catalog) else { return 0 }
        let million = Decimal(1_000_000)
        let raw =
            Decimal(input) * p.inputPerMTok
            + Decimal(output) * p.outputPerMTok
            + Decimal(cacheRead) * p.cacheReadPerMTok
            + Decimal(cacheCreation) * p.cacheCreationPerMTok
        var result = raw / million
        var rounded = Decimal()
        NSDecimalRound(&rounded, &result, 6, .bankers)
        return rounded
    }
}
