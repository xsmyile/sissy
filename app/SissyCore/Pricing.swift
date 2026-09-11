import Foundation

struct ModelPricing: Sendable, Equatable, Codable {
    let inputPerMTok: Decimal
    let outputPerMTok: Decimal
    let cacheReadPerMTok: Decimal
    /// 5-minute cache-write rate (Anthropic: 1.25× base input).
    let cacheCreationPerMTok: Decimal
    /// 1-hour cache-write rate (Anthropic: 2× base input). Optional so a
    /// `pricingOverride` can set it independently of `inputPerMTok`; when nil
    /// it's derived as `inputPerMTok × Pricing.cacheCreation1hInputMultiplier`
    /// at cost time. Defaulted so `server.json` overrides that predate the
    /// field stay source- and decode-compatible. Must be `var`, not `let`: a
    /// `let` with an initial value is dropped from Decodable synthesis, which
    /// would silently pin every override's 1h rate to nil.
    var cacheCreation1hPerMTok: Decimal? = nil
}

/// A rate table that resolves a model name exact-first, then by longest
/// prefix, so `claude-opus-5-20260701` finds the `claude-opus-5` row.
///
/// The prefix order is computed once at construction. The lookup runs ~44k
/// times during a cold backfill, and re-sorting a 100-entry dictionary per call
/// was measurably the hot path.
struct PricingTable: Sendable {
    private let exact: [String: ModelPricing]
    private let byLongestPrefix: [(prefix: String, pricing: ModelPricing)]

    init(_ table: [String: ModelPricing]) {
        self.exact = table
        self.byLongestPrefix =
            table
            .sorted { $0.key.count > $1.key.count }
            .map { (prefix: $0.key, pricing: $0.value) }
    }

    var isEmpty: Bool { exact.isEmpty }
    var count: Int { exact.count }

    func match(_ model: String) -> ModelPricing? {
        if let p = exact[model] { return p }
        for entry in byLongestPrefix where model.hasPrefix(entry.prefix) {
            return entry.pricing
        }
        return nil
    }
}

/// Exact-then-longest-prefix lookup against a price-override table. Kept
/// separate from `PricingTable` because an override is read straight from
/// `server.json` on every call and is typically empty or a handful of rows, so
/// the per-call sort costs nothing and avoids a rebuild on config reload.
func matchPricingOverride(_ table: [String: ModelPricing], model: String) -> ModelPricing? {
    if let p = table[model] { return p }
    let byLength = table.sorted(by: { $0.key.count > $1.key.count })
    for (prefix, p) in byLength where model.hasPrefix(prefix) {
        return p
    }
    return nil
}

/// Anthropic token pricing.
///
/// There is no hand-maintained rate table. Rates resolve through three sources,
/// highest authority first:
///
/// 1. `override` — the user's `server.json` `pricingOverride`.
/// 2. `catalog` — LiteLLM's rate table, fetched at runtime by `PriceCatalog`.
/// 3. `PricingSeed` — a generated snapshot of the same LiteLLM data, embedded at
///    build time so a first run with no network still prices correctly.
///
/// LiteLLM is the source ccusage prices against, so reading it directly is what
/// keeps Sissy's cost agreeing with the number users cross-check.
///
/// `cacheCreationPerMTok` is the **5-minute** cache-write rate (1.25× base
/// input). The **1-hour** tier bills at 2× base input and is derived from
/// `inputPerMTok` at cost time rather than carried per row — exact for every
/// current model, and it rides along automatically with a `pricingOverride`
/// input-rate change. Claude Code JSONL splits the two tiers in
/// `usage.cache_creation` (`ephemeral_5m_input_tokens` /
/// `ephemeral_1h_input_tokens`); 1h volume dominates real traffic, so
/// collapsing both onto the 5m rate under-bills by ~7%.
enum Pricing {
    /// Exact-then-longest-prefix lookup across override, runtime catalog and
    /// the embedded seed, in that order. Returns nil for a model none of them
    /// carries — the caller bills it at $0, which the readers log.
    static func price(
        for model: String,
        override: [String: ModelPricing]? = nil,
        catalog: PricingTable? = nil
    ) -> ModelPricing? {
        if let override, let p = matchPricingOverride(override, model: model) { return p }
        if let catalog, let p = catalog.match(model) { return p }
        return PricingSeed.anthropic.match(model)
    }

    /// Default 1-hour cache-write multiplier over base input (Anthropic: 2×,
    /// versus the 5-minute tier's 1.25× carried per model in
    /// `cacheCreationPerMTok`). Used only when a model's
    /// `cacheCreation1hPerMTok` is nil. An override that sets it explicitly
    /// bypasses this multiplier.
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
        override: [String: ModelPricing]? = nil,
        catalog: PricingTable? = nil
    ) -> Decimal {
        guard let p = price(for: model, override: override, catalog: catalog) else { return 0 }
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
