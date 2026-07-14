import Foundation

struct ModelPricing: Sendable, Equatable, Codable {
    let inputPerMTok: Decimal
    let outputPerMTok: Decimal
    let cacheReadPerMTok: Decimal
    /// 5-minute cache-write rate (Anthropic: 1.25× base input).
    let cacheCreationPerMTok: Decimal
    /// 1-hour cache-write rate (Anthropic: 2× base input). Optional so a
    /// `pricingOverride` can set it independently of `inputPerMTok`; when nil
    /// (the built-in table and most overrides) it's derived as
    /// `inputPerMTok × Pricing.cacheCreation1hInputMultiplier` at cost time.
    /// Defaulted so existing initializers and `server.json` overrides that
    /// predate the field stay source- and decode-compatible. Must be `var`,
    /// not `let`: a `let` with an initial value is dropped from Decodable
    /// synthesis, which would silently pin every override's 1h rate to nil.
    var cacheCreation1hPerMTok: Decimal? = nil
}

/// Exact-then-longest-prefix lookup against a price-override table. Shared by
/// `Pricing` and `OpenAIPricing` so the override-matching precedence can't
/// drift between providers. The override path is hit at most once per unique
/// model seen and the table is typically empty or tiny, so the per-call sort
/// is acceptable.
func matchPricingOverride(_ table: [String: ModelPricing], model: String) -> ModelPricing? {
    if let p = table[model] { return p }
    let byLength = table.sorted(by: { $0.key.count > $1.key.count })
    for (prefix, p) in byLength where model.hasPrefix(prefix) {
        return p
    }
    return nil
}

/// Anthropic Claude API pricing per million tokens (USD). Cross-checked
/// against platform.claude.com/docs/en/about-claude/pricing on 2026-05-25.
///
/// `cacheCreationPerMTok` is the **5-minute** cache-write rate (1.25× base
/// input). The **1-hour** tier bills at 2× base input and is derived from
/// `inputPerMTok` at cost time (see `cacheCreation1hInputMultiplier`) rather
/// than carried per row — exact for every current model and it rides along
/// automatically with a `pricingOverride` input-rate change. Claude Code
/// JSONL splits the two tiers in `usage.cache_creation`
/// (`ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens`); 1h volume
/// dominates real traffic, so collapsing both onto the 5m rate underbilled
/// by ~7%. The `pricingOverride` map in `server.json` is the user-facing
/// escape hatch when Anthropic publishes a change; the weekly `pricing-drift`
/// workflow (`scripts/check_pricing_drift.py`) re-checks every emittable model
/// against LiteLLM and fails when this table drifts.
///
/// Naming maps the Anthropic model names that appear in `~/.claude/projects`
/// JSONL `message.model`, e.g. `claude-opus-4-7-20260101`. Longest-prefix
/// lookup means a point-release rolls onto its family entry without an
/// explicit row here — Opus 4.5/4.6/4.7 all hit `claude-opus-4-5` /
/// `-4-6` / `-4-7`; Opus 4.0 and 4.1 are the **deprecated** $15/$75 tier
/// and have their own exact rows.
enum Pricing {
    static let table: [String: ModelPricing] = [
        // Claude 5 family (current). Sonnet 5 is the $2 / $10 tier; Fable 5 the
        // premium $10 / $50 tier. Dated/point releases roll onto these rows via
        // longest-prefix match. `cacheCreationPerMTok` is the 5-minute rate
        // (1.25× input); the 1-hour tier derives as 2× input at cost time.
        "claude-sonnet-5": .init(
            inputPerMTok: 2.00, outputPerMTok: 10.00, cacheReadPerMTok: 0.20,
            cacheCreationPerMTok: 2.50),
        "claude-fable-5": .init(
            inputPerMTok: 10.00, outputPerMTok: 50.00, cacheReadPerMTok: 1.00,
            cacheCreationPerMTok: 12.50),
        // Opus 4.5+ (current). $5 / $25 with $0.50 cache hit. Each minor
        // version gets its own exact row so a future Opus 4.8 doesn't
        // accidentally fall to the deprecated 4.0/4.1 rate via the
        // `claude-opus-4` longest-prefix bucket.
        "claude-opus-4-8": .init(
            inputPerMTok: 5.00, outputPerMTok: 25.00, cacheReadPerMTok: 0.50,
            cacheCreationPerMTok: 6.25),
        "claude-opus-4-7": .init(
            inputPerMTok: 5.00, outputPerMTok: 25.00, cacheReadPerMTok: 0.50,
            cacheCreationPerMTok: 6.25),
        "claude-opus-4-6": .init(
            inputPerMTok: 5.00, outputPerMTok: 25.00, cacheReadPerMTok: 0.50,
            cacheCreationPerMTok: 6.25),
        "claude-opus-4-5": .init(
            inputPerMTok: 5.00, outputPerMTok: 25.00, cacheReadPerMTok: 0.50,
            cacheCreationPerMTok: 6.25),
        // Opus 4.1 and 4.0 (deprecated). $15 / $75. Anthropic still
        // accepts the model names for inference, so we keep them rated.
        "claude-opus-4-1": .init(
            inputPerMTok: 15.00, outputPerMTok: 75.00, cacheReadPerMTok: 1.50,
            cacheCreationPerMTok: 18.75),
        "claude-opus-4": .init(
            inputPerMTok: 15.00, outputPerMTok: 75.00, cacheReadPerMTok: 1.50,
            cacheCreationPerMTok: 18.75),
        // Sonnet 4 family — same rate across 4 (deprecated) / 4.5 / 4.6.
        "claude-sonnet-4-6": .init(
            inputPerMTok: 3.00, outputPerMTok: 15.00, cacheReadPerMTok: 0.30,
            cacheCreationPerMTok: 3.75),
        "claude-sonnet-4-5": .init(
            inputPerMTok: 3.00, outputPerMTok: 15.00, cacheReadPerMTok: 0.30,
            cacheCreationPerMTok: 3.75),
        "claude-sonnet-4": .init(
            inputPerMTok: 3.00, outputPerMTok: 15.00, cacheReadPerMTok: 0.30,
            cacheCreationPerMTok: 3.75),
        // Haiku 4.5 (current). $1 / $5.
        "claude-haiku-4-5": .init(
            inputPerMTok: 1.00, outputPerMTok: 5.00, cacheReadPerMTok: 0.10,
            cacheCreationPerMTok: 1.25),
        "claude-haiku-4": .init(
            inputPerMTok: 1.00, outputPerMTok: 5.00, cacheReadPerMTok: 0.10,
            cacheCreationPerMTok: 1.25),
        // Claude 3.x — retired except on Bedrock / Vertex.
        "claude-3-5-sonnet": .init(
            inputPerMTok: 3.00, outputPerMTok: 15.00, cacheReadPerMTok: 0.30,
            cacheCreationPerMTok: 3.75),
        "claude-3-5-haiku": .init(
            inputPerMTok: 0.80, outputPerMTok: 4.00, cacheReadPerMTok: 0.08,
            cacheCreationPerMTok: 1.00),
        "claude-3-opus": .init(
            inputPerMTok: 15.00, outputPerMTok: 75.00, cacheReadPerMTok: 1.50,
            cacheCreationPerMTok: 18.75),
        "claude-3-haiku": .init(
            inputPerMTok: 0.25, outputPerMTok: 1.25, cacheReadPerMTok: 0.03,
            cacheCreationPerMTok: 0.30),
    ]

    /// `table` entries ordered by longest prefix first. Computed once at type
    /// init so the hot lookup path (called ~44k times during cold backfill)
    /// doesn't re-sort the dict on every call.
    private static let sortedBuiltinPrefixes: [(String, ModelPricing)] =
        table.sorted(by: { $0.key.count > $1.key.count })

    /// Exact lookup first, then longest-prefix family match
    /// ("claude-opus-4-7-20260101" → "claude-opus-4-7"). When `override` is
    /// non-nil and matches the model, it shadows the built-in table —
    /// entries follow the same exact-then-prefix precedence. Returns nil
    /// for unknown models.
    static func price(for model: String, override: [String: ModelPricing]? = nil) -> ModelPricing? {
        if let override, let p = matchPricingOverride(override, model: model) { return p }
        return matchBuiltin(model: model)
    }

    private static func matchBuiltin(model: String) -> ModelPricing? {
        if let p = table[model] { return p }
        for (prefix, p) in sortedBuiltinPrefixes {
            if model.hasPrefix(prefix) { return p }
        }
        return nil
    }

    /// Default 1-hour cache-write multiplier over base input (Anthropic: 2×,
    /// versus the 5-minute tier's 1.25× stored per-model in
    /// `cacheCreationPerMTok`). Used only when a model's
    /// `cacheCreation1hPerMTok` is nil — exact for every current model, so the
    /// built-in table carries no per-row 1h literal and a `pricingOverride`
    /// input-rate change rides along automatically. An override that sets
    /// `cacheCreation1hPerMTok` explicitly bypasses this multiplier.
    static let cacheCreation1hInputMultiplier = Decimal(2)

    /// Cache creation is split by write duration: `fiveMinute` bills at the
    /// per-model 5-minute rate (`cacheCreationPerMTok`), `oneHour` at 2× base
    /// input. Callers that can't distinguish the tiers (pre-split logs) should
    /// pass the aggregate as `fiveMinute` with `oneHour: 0` — the historical
    /// behaviour.
    static func cost(
        model: String,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheCreation: (fiveMinute: Int, oneHour: Int),
        override: [String: ModelPricing]? = nil
    ) -> Decimal {
        guard let p = price(for: model, override: override) else { return 0 }
        let million = Decimal(1_000_000)
        let cache1hPerMTok =
            p.cacheCreation1hPerMTok ?? (p.inputPerMTok * cacheCreation1hInputMultiplier)
        let raw =
            Decimal(input) * p.inputPerMTok
            + Decimal(output) * p.outputPerMTok
            + Decimal(cacheRead) * p.cacheReadPerMTok
            + Decimal(cacheCreation.fiveMinute) * p.cacheCreationPerMTok
            + Decimal(cacheCreation.oneHour) * cache1hPerMTok
        var result = raw / million
        var rounded = Decimal()
        NSDecimalRound(&rounded, &result, 6, .bankers)
        return rounded
    }
}
