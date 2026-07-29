import Foundation

/// Which provider's rates a catalog slice carries.
enum CatalogProvider: String, Sendable, Codable {
    case anthropic
    case openai
}

/// Per-provider rate tables sourced from LiteLLM's
/// `model_prices_and_context_window.json` — the same file ccusage prices
/// against, which is why reading it directly keeps Sissy's cost agreeing with
/// the number users cross-check.
///
/// This is the only rate source in the daemon. There is no hand-maintained
/// table to keep current, so a provider shipping a new model needs no Sissy
/// release: the runtime refresh picks it up, and `PricingSeed` — a snapshot of
/// this same structure generated at build time — covers a first run with no
/// network.
///
/// Cache-write tiers: `cache_creation_input_token_cost` is the 5-minute tier
/// (1.25× input) and `cache_creation_input_token_cost_above_1hr` the 1-hour tier
/// (2× input). The 1-hour value is adopted only inside a plausible band around
/// input — a few retired `claude-3-*` rows upstream carry a copy-pasted value
/// 24× input, which would badly over-bill. Rejecting those leaves
/// `cacheCreation1hPerMTok` nil so `Pricing.cacheCreation1hInputMultiplier`
/// derives the tier.
struct PriceCatalog: Sendable, Codable {
    /// Bumped when the cached shape changes so an older file is discarded
    /// rather than half-decoded. Same quarantine convention the per-provider
    /// usage snapshots use.
    static let currentSchemaVersion = 1

    var schemaVersion: Int = Self.currentSchemaVersion
    let fetchedAt: Date
    let anthropic: [String: ModelPricing]
    let openai: [String: ModelPricing]

    func rates(for provider: CatalogProvider) -> [String: ModelPricing] {
        switch provider {
        case .anthropic: return anthropic
        case .openai: return openai
        }
    }

    /// Lookup-ready table for one provider. Building it presorts the prefix
    /// order once, so the caller should hold the result rather than rebuild it
    /// per priced event.
    func table(for provider: CatalogProvider) -> PricingTable {
        PricingTable(rates(for: provider))
    }
}

/// Fetch / cache / validate pipeline for `PriceCatalog`.
enum PriceCatalogSource {
    /// Kept as a string and resolved at fetch time so a typo surfaces as a
    /// thrown `invalidURL` in the daemon log rather than a launch-time trap.
    static let litellmURLString =
        "https://raw.githubusercontent.com/BerriAI/litellm/main/"
        + "model_prices_and_context_window.json"

    static let refreshInterval: Duration = .seconds(24 * 60 * 60)
    /// Retry cadence after a failed refresh. Short enough that a transient
    /// upstream outage doesn't cost a full day of staleness, long enough not to
    /// hammer GitHub from every installed daemon.
    static let retryInterval: Duration = .seconds(60 * 60)
    static let requestTimeout: TimeInterval = 20
    static let fetchAttempts = 3
    static let fetchBackoffBase: Duration = .seconds(2)
    /// How long the cold backfill will wait for a first catalog when there is
    /// no cache to start from. Short enough that a slow network delays the
    /// first frame rather than the daemon, long enough to cover a normal fetch.
    static let coldStartBudget: Duration = .seconds(8)

    private static let perMillion = 1_000_000.0
    /// A usable catalog must carry at least this many models per provider.
    /// Guards against adopting a truncated or mid-refactor upstream file that
    /// parses as valid JSON but prices almost nothing.
    static let minimumEntriesPerProvider = 8
    /// No first-party text model has ever cost this much per million tokens;
    /// a value above it means the upstream units changed.
    private static let maximumRatePerMTok: Decimal = 2_000
    /// Accepted band for the 1-hour cache-write rate, as a multiple of input.
    /// Anthropic's published tier is exactly 2×.
    private static let cacheCreation1hRatioBounds: (min: Decimal, max: Decimal) = (1.5, 2.5)
    /// Accepted ceiling for the 5-minute cache-write rate, as a multiple of
    /// input. Anthropic's published tier is 1.25×.
    private static let cacheCreation5mRatioCeiling: Decimal = 3

    private static let trackedModes: Set<String> = ["chat", "responses"]
    /// Key fragments that mark a non-text model or a vendor-scoped alias
    /// (`bedrock/…`, `ft:…`) that Sissy's readers never see in a session log.
    private static let excludedKeyFragments = [
        "audio", "realtime", "transcribe", "tts", "whisper", "image", "dall-e",
        "embedding", "moderation", "-search-", "computer-use", "guard", ":", "/",
    ]

    static var cacheURL: URL {
        SissyPaths.appSupportDir.appendingPathComponent("pricing-catalog.json")
    }

    // MARK: - Pure parsing

    /// Maps a decoded LiteLLM payload into per-provider rate tables.
    ///
    /// Returns nil when either provider ends up below
    /// `minimumEntriesPerProvider`, which is the signal that the upstream file
    /// changed shape rather than that Sissy's filters are wrong — adopting a
    /// near-empty catalog would price almost nothing.
    static func parse(litellm payload: [String: Any], fetchedAt: Date) -> PriceCatalog? {
        var anthropic: [String: ModelPricing] = [:]
        var openai: [String: ModelPricing] = [:]
        for (key, raw) in payload {
            guard let entry = raw as? [String: Any],
                let provider = trackedProvider(of: entry),
                isTrackedTextModel(key: key, entry: entry),
                let pricing = rates(from: entry, provider: provider)
            else { continue }
            switch provider {
            case .anthropic: anthropic[key] = pricing
            case .openai: openai[key] = pricing
            }
        }
        guard anthropic.count >= minimumEntriesPerProvider,
            openai.count >= minimumEntriesPerProvider
        else { return nil }
        return PriceCatalog(fetchedAt: fetchedAt, anthropic: anthropic, openai: openai)
    }

    private static func trackedProvider(of entry: [String: Any]) -> CatalogProvider? {
        guard let raw = entry["litellm_provider"] as? String else { return nil }
        return CatalogProvider(rawValue: raw)
    }

    private static func isTrackedTextModel(key: String, entry: [String: Any]) -> Bool {
        if let mode = entry["mode"] as? String, !trackedModes.contains(mode) { return false }
        return !excludedKeyFragments.contains { key.contains($0) }
    }

    /// Validates one LiteLLM entry into a `ModelPricing`, rejecting anything
    /// whose rates aren't internally coherent. A rejected entry is simply
    /// absent from the catalog rather than priced from nonsense.
    static func rates(from entry: [String: Any], provider: CatalogProvider) -> ModelPricing? {
        guard let input = perMTok(entry["input_cost_per_token"]),
            let output = perMTok(entry["output_cost_per_token"])
        else { return nil }

        // Codex rollouts carry no cache-creation token count, so the OpenAI
        // cache-write rate stays 0 by convention.
        var cacheCreation5m: Decimal = 0
        var cacheCreation1h: Decimal?
        if provider == .anthropic {
            guard let write5m = perMTok(entry["cache_creation_input_token_cost"]) else {
                return nil
            }
            cacheCreation5m = write5m
            // Out-of-band 1h rates drop to nil rather than rejecting the row:
            // `Pricing.cacheCreation1hInputMultiplier` then derives the tier,
            // which is still exact for every current model.
            if let write1h = perMTok(entry["cache_creation_input_token_cost_above_1hr"]),
                isCoherent1h(write1h, input: input)
            {
                cacheCreation1h = write1h
            }
        }

        let pricing = ModelPricing(
            inputPerMTok: input,
            outputPerMTok: output,
            cacheReadPerMTok: perMTok(entry["cache_read_input_token_cost"]) ?? 0,
            cacheCreationPerMTok: cacheCreation5m,
            cacheCreation1hPerMTok: cacheCreation1h
        )
        return isCoherent(pricing, provider: provider) ? pricing : nil
    }

    /// Semantic validation for one model's rates, shared by the remote-payload
    /// parser and the cache loader.
    ///
    /// Both paths must hold rates to the same bar: the cache outranks the
    /// embedded seed, so anything the parser would have rejected upstream must
    /// also be rejected on the way back in, or a hand-edited file could shadow
    /// correct rates with inflated or negative ones.
    static func isCoherent(_ pricing: ModelPricing, provider: CatalogProvider) -> Bool {
        let input = pricing.inputPerMTok
        guard input > 0, pricing.outputPerMTok > 0,
            input <= maximumRatePerMTok, pricing.outputPerMTok <= maximumRatePerMTok,
            pricing.cacheReadPerMTok >= 0, pricing.cacheReadPerMTok <= input
        else { return false }
        switch provider {
        case .anthropic:
            guard pricing.cacheCreationPerMTok > 0,
                pricing.cacheCreationPerMTok <= input * cacheCreation5mRatioCeiling
            else { return false }
        case .openai:
            guard pricing.cacheCreationPerMTok == 0, pricing.cacheCreation1hPerMTok == nil
            else { return false }
        }
        guard let write1h = pricing.cacheCreation1hPerMTok else { return true }
        return isCoherent1h(write1h, input: input)
    }

    private static func isCoherent1h(_ rate: Decimal, input: Decimal) -> Bool {
        rate >= input * cacheCreation1hRatioBounds.min
            && rate <= input * cacheCreation1hRatioBounds.max
    }

    /// LiteLLM stores per-token costs as JSON numbers. Scaling to per-million
    /// through a fixed 6-decimal string keeps the value an exact `Decimal`
    /// instead of inheriting a binary-float artifact from `Decimal(_: Double)`.
    private static func perMTok(_ raw: Any?) -> Decimal? {
        guard let number = raw as? NSNumber else { return nil }
        let scaled = number.doubleValue * perMillion
        guard scaled.isFinite else { return nil }
        return Decimal(string: String(format: "%.6f", scaled))
    }

    // MARK: - Cache

    /// Reads the cached catalog, or nil when absent, unreadable, written by a
    /// different schema version, semantically invalid, or older than the
    /// embedded seed.
    ///
    /// The decoded model is re-validated, not just decoded: the cache outranks
    /// the embedded seed, so a hand-edited or truncated file that happens to
    /// satisfy `Codable` would otherwise shadow correct rates.
    static func loadCache(from url: URL = Self.cacheURL) -> PriceCatalog? {
        guard let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(PriceCatalog.self, from: data),
            isUsable(decoded),
            outranksSeed(decoded)
        else { return nil }
        return decoded
    }

    /// Whether a cache is newer than the snapshot this binary ships.
    ///
    /// A cache written before the seed was generated is not an upgrade over it:
    /// a daemon that sat idle across a release would otherwise boot, prefer its
    /// months-old file, and never see the rates the new build was cut with —
    /// permanently so if the machine is offline.
    static func outranksSeed(_ catalog: PriceCatalog) -> Bool {
        guard let seedFetchedAt else { return true }
        return catalog.fetchedAt >= seedFetchedAt
    }

    /// When the embedded seed was generated. Read back out of `PricingSeed.json`
    /// rather than added as a generated field, so the snapshot stays a plain
    /// dump of the same `PriceCatalog` the runtime fetch produces.
    private static let seedFetchedAt: Date? = {
        guard let data = PricingSeed.json.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(PriceCatalog.self, from: data)
        else { return nil }
        return decoded.fetchedAt
    }()

    static func isUsable(_ catalog: PriceCatalog) -> Bool {
        catalog.schemaVersion == PriceCatalog.currentSchemaVersion
            && catalog.anthropic.count >= minimumEntriesPerProvider
            && catalog.openai.count >= minimumEntriesPerProvider
            && catalog.anthropic.values.allSatisfy { isCoherent($0, provider: .anthropic) }
            && catalog.openai.values.allSatisfy { isCoherent($0, provider: .openai) }
    }

    static func saveCache(_ catalog: PriceCatalog, to url: URL = Self.cacheURL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? encoder().encode(catalog) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    // MARK: - Fetch

    /// One fetch attempt round, with bounded exponential backoff + jitter.
    /// Cancellation propagates out of both the request and the backoff sleep.
    static func fetch(from urlString: String = Self.litellmURLString) async throws -> PriceCatalog {
        guard let url = URL(string: urlString) else {
            throw PriceCatalogError.invalidURL(urlString)
        }
        var lastError: any Error = PriceCatalogError.exhaustedAttempts
        for attempt in 1...fetchAttempts {
            try Task.checkCancellation()
            do {
                return try await fetchOnce(url: url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                guard attempt < fetchAttempts else { break }
                let backoff = fetchBackoffBase * attempt
                try await Task.sleep(for: backoff + .milliseconds(Int.random(in: 0...500)))
            }
        }
        throw lastError
    }

    /// Single-attempt fetch capped at `coldStartBudget`, for the one call that
    /// the cold backfill waits on.
    ///
    /// Without it the first run on a machine with no cache races its own
    /// refresh: part of the two-day window gets priced from the seed and the
    /// rest from the live catalog, purely on task scheduling. Returns nil on
    /// timeout or any failure — the caller then backfills from the seed
    /// deterministically while the background loop keeps retrying. Offline
    /// boots fail fast rather than burning the budget.
    static func fetchForColdStart(from urlString: String = Self.litellmURLString) async
        -> PriceCatalog?
    {
        guard let url = URL(string: urlString) else { return nil }
        return await withTaskGroup(of: PriceCatalog?.self) { group in
            group.addTask { try? await fetchOnce(url: url) }
            group.addTask {
                try? await Task.sleep(for: coldStartBudget)
                return nil
            }
            var winner: PriceCatalog?
            for await result in group {
                winner = result
                break
            }
            group.cancelAll()
            return winner
        }
    }

    private static func fetchOnce(url: URL) async throws -> PriceCatalog {
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "GET"
        // The whole point of the refresh is freshness; a URLCache hit would hand
        // back the copy we already have on disk.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw PriceCatalogError.badStatus(http.statusCode)
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PriceCatalogError.malformedPayload
        }
        guard let catalog = parse(litellm: payload, fetchedAt: Date()) else {
            throw PriceCatalogError.insufficientEntries
        }
        return catalog
    }

    /// Refreshes on `refreshInterval` for the daemon's lifetime, starting after
    /// `initialDelay` so a restart that already loaded a recent cache doesn't
    /// refetch immediately.
    ///
    /// A refreshed catalog applies to events ingested from that point on;
    /// already-accumulated day totals are not repriced, same as a
    /// `pricingOverride` edit. Rate changes are logged so that is visible rather
    /// than implied.
    ///
    /// `initialPrevious` is the catalog the backfill already ran against, so
    /// the very first refresh reports what moved since then. Nil only when no
    /// runtime catalog was resolved at all and the seed did the pricing.
    static func refreshLoop(
        initialDelay: Duration,
        initialPrevious: PriceCatalog? = nil,
        publish: @Sendable @escaping (PriceCatalog) async -> Void
    ) async {
        var delay = initialDelay
        var previous: PriceCatalog? = initialPrevious
        while !Task.isCancelled {
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            do {
                let catalog = try await fetch()
                saveCache(catalog)
                await publish(catalog)
                let changed = changedModelCount(from: previous, to: catalog)
                previous = catalog
                if changed > 0 {
                    daemonLog(
                        "sissy-serverd: pricing catalog refreshed — \(changed) rate(s) changed; "
                            + "applies to events ingested from now on, already-counted events "
                            + "are not repriced")
                } else {
                    daemonLog(
                        "sissy-serverd: pricing catalog refreshed — "
                            + "anthropic=\(catalog.anthropic.count), openai=\(catalog.openai.count)")
                }
                delay = refreshInterval
            } catch is CancellationError {
                return
            } catch {
                daemonLog(
                    "sissy-serverd: pricing catalog refresh failed (\(error)) — "
                        + "keeping previous rates, retrying later")
                delay = retryInterval
            }
        }
    }

    /// Number of models whose rate differs between two catalogs, counting
    /// additions and removals. Nil `old` reports 0 so the first refresh of a
    /// process isn't announced as a change.
    static func changedModelCount(from old: PriceCatalog?, to new: PriceCatalog) -> Int {
        guard let old else { return 0 }
        var changed = 0
        for provider in [CatalogProvider.anthropic, .openai] {
            let before = old.rates(for: provider)
            let after = new.rates(for: provider)
            for (key, pricing) in after where before[key] != pricing { changed += 1 }
            for key in before.keys where after[key] == nil { changed += 1 }
        }
        return changed
    }

    /// How long to wait before the first refresh given a cache of `age`.
    /// Clamped to zero so an already-stale cache refreshes immediately.
    static func refreshDelay(forCacheAge age: TimeInterval) -> Duration {
        let remaining = refreshInterval - .seconds(age)
        return remaining > .zero ? remaining : .zero
    }

    // MARK: - Seed generation

    /// Renders `PricingSeed.swift`. Invoked by `sissy-serverd --dump-seed` at
    /// release time so the embedded snapshot is produced by the same parser that
    /// validates the runtime fetch — there is no second implementation to drift.
    static func swiftSeedSource(for catalog: PriceCatalog) throws -> String {
        let json = try encoder().encode(catalog)
        guard let body = String(data: json, encoding: .utf8) else {
            throw PriceCatalogError.malformedPayload
        }
        return """
            // Generated by `sissy-serverd --dump-seed`. Do not edit by hand.
            //
            // A snapshot of the LiteLLM rate tables, embedded so a first run with
            // no network still prices correctly. `PriceCatalog`'s runtime refresh
            // supersedes it within a day, so this only needs regenerating when
            // cutting a release.

            import Foundation

            enum PricingSeed {
                static let json = #\"\"\"
                    \(body)
                    \"\"\"#

                private static let catalog: PriceCatalog? = {
                    guard let data = json.data(using: .utf8),
                        let decoded = try? JSONDecoder().decode(PriceCatalog.self, from: data),
                        PriceCatalogSource.isUsable(decoded)
                    else { return nil }
                    return decoded
                }()

                static let anthropic = PricingTable(catalog?.anthropic ?? [:])
                static let openai = PricingTable(catalog?.openai ?? [:])
            }
            """
    }
}

enum PriceCatalogError: Error, CustomStringConvertible {
    case invalidURL(String)
    case badStatus(Int)
    case malformedPayload
    case insufficientEntries
    case exhaustedAttempts

    var description: String {
        switch self {
        case .invalidURL(let raw): return "LiteLLM catalog URL is not parseable: \(raw)"
        case .badStatus(let code): return "HTTP \(code) from LiteLLM catalog"
        case .malformedPayload: return "LiteLLM catalog is not a JSON object"
        case .insufficientEntries:
            return "LiteLLM catalog priced too few models — upstream shape likely changed"
        case .exhaustedAttempts: return "no fetch attempt was made"
        }
    }
}
