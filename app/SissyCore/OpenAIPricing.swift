import Foundation

/// OpenAI token pricing. Same three-source precedence as `Pricing` — override,
/// runtime LiteLLM catalog, embedded seed — and no hand-maintained table.
///
/// Codex emits `reasoning_output_tokens` alongside `output_tokens`, but
/// `output_tokens` is already gross (it includes the reasoning portion);
/// `reasoning_output_tokens` is a sub-breakdown for observability, not an
/// additive counter. `CodexAdapter` therefore passes `output_tokens`
/// straight through — same convention ccusage uses. Cached input is a separate
/// billable channel (`cacheReadPerMTok`); Codex rollouts report no
/// cache-creation tokens, so `cacheCreationPerMTok` stays 0 by convention.
enum OpenAIPricing {
    static func price(
        for model: String,
        override: PricingTable? = nil,
        catalog: PricingTable? = nil
    ) -> ModelPricing? {
        Pricing.price(for: model, override: override, catalog: catalog, seed: PricingSeed.openai)
    }

    static func cost(
        model: String,
        input: Int,
        output: Int,
        cacheRead: Int,
        override: PricingTable? = nil,
        catalog: PricingTable? = nil
    ) -> Decimal {
        guard let p = price(for: model, override: override, catalog: catalog) else { return 0 }
        return Pricing.roundedCost(
            Decimal(input) * p.inputPerMTok
                + Decimal(output) * p.outputPerMTok
                + Decimal(cacheRead) * p.cacheReadPerMTok)
    }
}
