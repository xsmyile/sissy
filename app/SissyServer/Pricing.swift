import Foundation

struct ModelPricing: Sendable, Equatable, Codable {
    let inputPerMTok: Decimal
    let outputPerMTok: Decimal
    let cacheReadPerMTok: Decimal
    let cacheCreationPerMTok: Decimal
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
/// Cache creation is the **5-minute** write rate (1.25× base input). Claude
/// Code JSONL doesn't surface the 5m-vs-1h distinction so we always bill at
/// 5m; the 1h rate (2× base input) is rare in real traffic and would
/// underbill by at most a few percent. The `pricingOverride` map in
/// `server.json` is the user-facing escape hatch when Anthropic publishes a
/// change.
///
/// Naming maps the Anthropic model names that appear in `~/.claude/projects`
/// JSONL `message.model`, e.g. `claude-opus-4-7-20260101`. Longest-prefix
/// lookup means a point-release rolls onto its family entry without an
/// explicit row here — Opus 4.5/4.6/4.7 all hit `claude-opus-4-5` /
/// `-4-6` / `-4-7`; Opus 4.0 and 4.1 are the **deprecated** $15/$75 tier
/// and have their own exact rows.
enum Pricing {
    static let table: [String: ModelPricing] = [
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

    static func cost(
        model: String,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheCreation: Int,
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
