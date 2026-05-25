import Foundation

/// OpenAI pricing per million tokens (USD). Cross-checked against
/// LiteLLM's `model_prices_and_context_window.json` mirror (the same source
/// ccusage uses) on 2026-05-25. Override via `server.json.pricingOverride`
/// when OpenAI publishes a change; the CI drift job pins known fixtures so
/// a silent regression here trips a test.
///
/// Codex emits `reasoning_output_tokens` alongside `output_tokens`, but
/// `output_tokens` is already gross (it includes the reasoning portion);
/// `reasoning_output_tokens` is a sub-breakdown for observability, not an
/// additive counter. `CodexUsageReader` therefore passes `output_tokens`
/// straight through — same convention ccusage uses. Cached input is a
/// separate billable channel (`cacheReadPerMTok`); OpenAI has no parallel
/// to Anthropic's cache-write rate, so `cacheCreationPerMTok` stays 0.
enum OpenAIPricing {
    static let table: [String: ModelPricing] = [
        // gpt-5 family — base, codex variants, 5.1/5.2/5.5 generations. The
        // `.codex` and `.codex-experimental` shapes are what `codex` CLI
        // sessions actually emit; the bare `gpt-5` covers `chat`/`chat-latest`
        // siblings via longest-prefix match.
        "gpt-5": .init(
            inputPerMTok: 1.25, outputPerMTok: 10.00, cacheReadPerMTok: 0.125,
            cacheCreationPerMTok: 0),
        "gpt-5-codex": .init(
            inputPerMTok: 1.25, outputPerMTok: 10.00, cacheReadPerMTok: 0.125,
            cacheCreationPerMTok: 0),
        "gpt-5-mini": .init(
            inputPerMTok: 0.25, outputPerMTok: 2.00, cacheReadPerMTok: 0.025,
            cacheCreationPerMTok: 0),
        "gpt-5-nano": .init(
            inputPerMTok: 0.05, outputPerMTok: 0.40, cacheReadPerMTok: 0.005,
            cacheCreationPerMTok: 0),
        "gpt-5-pro": .init(
            inputPerMTok: 15.00, outputPerMTok: 120.00, cacheReadPerMTok: 0,
            cacheCreationPerMTok: 0),
        "gpt-5.1": .init(
            inputPerMTok: 1.25, outputPerMTok: 10.00, cacheReadPerMTok: 0.125,
            cacheCreationPerMTok: 0),
        "gpt-5.1-codex": .init(
            inputPerMTok: 1.25, outputPerMTok: 10.00, cacheReadPerMTok: 0.125,
            cacheCreationPerMTok: 0),
        "gpt-5.2": .init(
            inputPerMTok: 1.75, outputPerMTok: 14.00, cacheReadPerMTok: 0.175,
            cacheCreationPerMTok: 0),
        "gpt-5.2-codex": .init(
            inputPerMTok: 1.75, outputPerMTok: 14.00, cacheReadPerMTok: 0.175,
            cacheCreationPerMTok: 0),
        "gpt-5.2-pro": .init(
            inputPerMTok: 21.00, outputPerMTok: 168.00, cacheReadPerMTok: 0,
            cacheCreationPerMTok: 0),
        "gpt-5.5": .init(
            inputPerMTok: 5.00, outputPerMTok: 30.00, cacheReadPerMTok: 0.50,
            cacheCreationPerMTok: 0),
        "gpt-5.5-pro": .init(
            inputPerMTok: 30.00, outputPerMTok: 180.00, cacheReadPerMTok: 3.00,
            cacheCreationPerMTok: 0),
        // o-series reasoning models. o3-mini cache_read is half input rate
        // (LiteLLM's published value); kept verbatim.
        "o1": .init(
            inputPerMTok: 15.00, outputPerMTok: 60.00, cacheReadPerMTok: 7.50,
            cacheCreationPerMTok: 0),
        "o1-pro": .init(
            inputPerMTok: 150.00, outputPerMTok: 600.00, cacheReadPerMTok: 0,
            cacheCreationPerMTok: 0),
        "o3": .init(
            inputPerMTok: 2.00, outputPerMTok: 8.00, cacheReadPerMTok: 0.50,
            cacheCreationPerMTok: 0),
        "o3-mini": .init(
            inputPerMTok: 1.10, outputPerMTok: 4.40, cacheReadPerMTok: 0.55,
            cacheCreationPerMTok: 0),
        "o3-pro": .init(
            inputPerMTok: 20.00, outputPerMTok: 80.00, cacheReadPerMTok: 0,
            cacheCreationPerMTok: 0),
        "o4-mini": .init(
            inputPerMTok: 1.10, outputPerMTok: 4.40, cacheReadPerMTok: 0.275,
            cacheCreationPerMTok: 0),
        // 4o tier — kept for any rollouts that still reference it.
        "gpt-4o": .init(
            inputPerMTok: 2.50, outputPerMTok: 10.00, cacheReadPerMTok: 1.25,
            cacheCreationPerMTok: 0),
        "gpt-4o-mini": .init(
            inputPerMTok: 0.15, outputPerMTok: 0.60, cacheReadPerMTok: 0.075,
            cacheCreationPerMTok: 0),
        "gpt-4-turbo": .init(
            inputPerMTok: 10.00, outputPerMTok: 30.00, cacheReadPerMTok: 0,
            cacheCreationPerMTok: 0),
    ]

    private static let sortedBuiltinPrefixes: [(String, ModelPricing)] =
        table.sorted(by: { $0.key.count > $1.key.count })

    /// Exact lookup first, then longest-prefix family match
    /// (`"gpt-5-codex-experimental"` → `"gpt-5-codex"` → `"gpt-5"`). Same
    /// override semantics as `Pricing.price(for:override:)` so the
    /// `pricingOverride` map in `server.json` shadows OpenAI rates the same
    /// way it shadows Anthropic's.
    static func price(for model: String, override: [String: ModelPricing]? = nil) -> ModelPricing? {
        if let override, let p = matchOverride(override, model: model) { return p }
        if let p = table[model] { return p }
        for (prefix, p) in sortedBuiltinPrefixes {
            if model.hasPrefix(prefix) { return p }
        }
        return nil
    }

    private static func matchOverride(_ table: [String: ModelPricing], model: String) -> ModelPricing? {
        if let p = table[model] { return p }
        for (prefix, p) in table.sorted(by: { $0.key.count > $1.key.count }) {
            if model.hasPrefix(prefix) { return p }
        }
        return nil
    }

    static func cost(
        model: String,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheCreation: Int = 0,
        override: [String: ModelPricing]? = nil
    ) -> Decimal {
        guard let p = price(for: model, override: override) else { return 0 }
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
