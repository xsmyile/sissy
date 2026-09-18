import Foundation

/// One provider's totals as emitted by `--scan`.
struct ScanEntry: Encodable {
    let tokens: Int
    let cost: String
    let filesWatched: Int
    /// Plan the provider named for this account, so the value the panel badges
    /// can be read without launching the app. Absent for a provider that
    /// names none — and for Codex also when the scan's one-second window
    /// closed before its first `token_count` event.
    let plan: String?
    let planTier: String?
    /// What the vendor has billed against the user's spend cap, when its own
    /// files say. Present so the reading can be checked without launching the
    /// app — it is the one number here that comes from neither the logs nor
    /// the pricing tables.
    let credits: ScanCredits?
    /// Sessions started and agents spawned today, so the count can be checked
    /// against the logs without launching the app. `--scan` runs the tail's own
    /// 48 h window and reports today, so these are today's, exactly as the
    /// tokens beside them are.
    let sessions: Int
    let agents: Int
}

/// The credits block of a `--scan` entry, in whichever unit the vendor
/// answered in. Each figure is absent where that vendor named none, so a
/// reading this tool prints can be told from a reading of zero.
struct ScanCredits: Encodable {
    let used: String?
    let cap: String?
    let balance: String?
    /// The account's ISO 4217 code, or absent for a vendor that counts credits
    /// and prices them in nothing.
    let currency: String?
    let observedAt: Date
}

let args = CommandLine.arguments
if args.contains("--self-test") {
    runSelfTest()
    exit(0)
}
if args.contains("--dump-seed") {
    // Regenerates `PricingSeed.swift` from a live LiteLLM fetch, using the same
    // parser that validates the runtime refresh. Release-time tool; see
    // AGENTS.md. Writes the Swift source to stdout.
    let sem = DispatchSemaphore(value: 0)
    var status: Int32 = 0
    Task.detached {
        do {
            let catalog = try await PriceCatalogSource.fetch()
            print(try PriceCatalogSource.swiftSeedSource(for: catalog))
        } catch {
            sissyLog("sissy: --dump-seed failed: \(error)")
            status = 1
        }
        sem.signal()
    }
    sem.wait()
    exit(status)
}
if args.contains("--refresh-catalog") {
    // Puts a live LiteLLM catalog in the cache and exits. The pricing-oracle
    // job needs Sissy priced from the same upstream snapshot `ccusage` reads,
    // so that a disagreement means a convention diverged rather than the
    // embedded seed simply being older. The oracle used to boot the daemon in
    // server mode and grep its log for the refresh line; this replaced that
    // when the server went.
    let sem = DispatchSemaphore(value: 0)
    var status: Int32 = 0
    Task.detached {
        defer { sem.signal() }
        do {
            let catalog = try await PriceCatalogSource.fetch()
            guard PriceCatalogSource.isUsable(catalog) else {
                sissyLog(
                    "sissy: --refresh-catalog rejected the fetched catalog "
                        + "(\(catalog.anthropic.count) anthropic, \(catalog.openai.count) openai rates) "
                        + "— upstream changed shape; the cache is left as it was")
                status = 1
                return
            }
            PriceCatalogSource.saveCache(catalog)
            sissyLog(
                "sissy: pricing catalog refreshed — "
                    + "\(catalog.anthropic.count + catalog.openai.count) rates cached at "
                    + PriceCatalogSource.cacheURL.path)
        } catch {
            sissyLog("sissy: --refresh-catalog failed: \(error)")
            status = 1
        }
    }
    sem.wait()
    exit(status)
}
// Optional `--config <path>` override. Lets smoke tests / integration runs
// point the tool at an isolated config + JSONL tree without touching the
// user's real `~/Library/Application Support/Sissy/server.json`.
let configURL: URL = {
    guard let idx = args.firstIndex(of: "--config") else { return ServerConfig.defaultURL }
    guard idx + 1 < args.count else {
        sissyLog("sissy: --config requires a path argument")
        exit(2)
    }
    return URL(fileURLWithPath: args[idx + 1])
}()
let config: ServerConfig
do {
    config = try ServerConfig.load(from: configURL)
} catch {
    sissyLog("sissy: config load failed: \(error)")
    exit(1)
}

if args.contains("--scan") {
    // Optional provider filter (`--scan-provider claude-code|codex|all`,
    // default all). Lets the ccusage drift CI job dump just the Codex
    // totals as JSON without launching the app.
    let scanFilter: String = {
        guard let idx = args.firstIndex(of: "--scan-provider"),
            idx + 1 < args.count
        else { return "all" }
        return args[idx + 1]
    }()
    let sem = DispatchSemaphore(value: 0)
    // `Task.detached` keeps the body off the main actor so `sem.wait()` below
    // does not block the actor that the body needs to make progress on. Under
    // Swift 6 strict concurrency, top-level `Task { … }` inherits the main
    // actor and deadlocks against the semaphore.
    Task.detached {
        // Same directories, overrides and pricing policy as the app, so
        // comparing this output against `ccusage` measures Sissy's real
        // behaviour rather than a set of defaults nobody runs.
        var providers: [any UsageProvider] = []
        // The install's own ledger, so a scan attributes what the app would
        // rather than only what is still on disk at the moment it runs.
        let projectLedger = ProjectLedger(
            url: ProjectLedger.defaultURL(in: configURL.deletingLastPathComponent()))
        if scanFilter == "all" || scanFilter == ProviderID.claudeCode {
            let home = config.providerHome(vendor: ProviderID.claudeCode)
            providers.append(
                LocalUsageProvider.claudeCode(
                    claudeDir: home.dataDir,
                    id: home.id,
                    pricingOverride: config.pricingOverride,
                    profile: ClaudeProfileSource(url: home.claudeProfileURL),
                    ledger: projectLedger))
        }
        if scanFilter == "all" || scanFilter == ProviderID.codex {
            let home = config.providerHome(vendor: ProviderID.codex)
            providers.append(
                LocalUsageProvider.codex(
                    codexDir: home.dataDir,
                    id: home.id,
                    pricingOverride: config.pricingOverride,
                    ledger: projectLedger))
        }
        // No fetch here — `--scan` stays offline and fast. The cached catalog
        // only exists once something has refreshed it; otherwise the embedded
        // seed prices, which is also what the app would do.
        if config.remotePricingEnabled, let cached = PriceCatalogSource.loadCache() {
            for p in providers { await p.applyPriceCatalog(cached) }
            sissyLog(
                "sissy: --scan pricing from cached catalog "
                    + "(fetched \(ISO8601DateFormatter().string(from: cached.fetchedAt)))")
        } else {
            sissyLog("sissy: --scan pricing from the embedded rate seed")
        }
        var out: [String: ScanEntry] = [:]
        for p in providers {
            await p.start { _ in }
            try? await Task.sleep(for: .seconds(1))
            let today = await p.current()
            let signals = p.currentSignals()
            out[p.id] = ScanEntry(
                tokens: today.totalTokens,
                cost: NSDecimalNumber(decimal: today.totalCost).stringValue,
                filesWatched: p.filesWatched(),
                plan: signals.plan,
                planTier: signals.planTier,
                credits: signals.credits.map { (credits: ProviderCredits) in
                    let figure = { (value: Decimal?) in
                        value.map { NSDecimalNumber(decimal: $0).stringValue }
                    }
                    var currency: String?
                    if case .money(let code, _) = credits.unit { currency = code }
                    return ScanCredits(
                        used: figure(credits.used),
                        cap: figure(credits.cap),
                        balance: figure(credits.balance),
                        currency: currency,
                        observedAt: credits.observedAt)
                },
                sessions: p.currentAgents().sessions,
                agents: p.currentAgents().agents
            )
            await p.stop()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(out), let s = String(data: data, encoding: .utf8) {
            print(s)
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

if args.contains("--backfill") {
    // Runs the archive backfill against the config's own state dir and prints
    // what the archive holds afterwards, a row per day per provider per model.
    // Always the whole window: it neither reads nor writes the coverage record
    // the app keeps, so a run is repeatable and says nothing about what the app
    // still owes. Point it at a `--config` of its own — without one it writes
    // into the same `history/` a running Sissy is writing.
    // That is the shape `ccusage <provider> --json` answers in, so the
    // agreement the issue asks for — a backfilled day landing on the oracle to
    // the token and the microdollar — is assertable in CI. `--scan` cannot:
    // it runs the tail's own 48 h window and reports today alone.
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        defer { sem.signal() }
        let stateDir = configURL.deletingLastPathComponent()
        guard
            let window = ArchiveBackfill.window(
                retentionDays: config.resolvedHistoryRetentionDays)
        else {
            sissyLog("sissy: --backfill has no window to cover — check historyRetentionDays")
            return
        }
        let projectLedger = ProjectLedger(url: ProjectLedger.defaultURL(in: stateDir))
        if config.remotePricingEnabled, let cached = PriceCatalogSource.loadCache() {
            sissyLog(
                "sissy: --backfill pricing from cached catalog "
                    + "(fetched \(ISO8601DateFormatter().string(from: cached.fetchedAt)))")
        }
        let catalog = config.remotePricingEnabled ? PriceCatalogSource.loadCache() : nil
        for vendor in [ProviderID.claudeCode, ProviderID.codex] {
            let home = config.providerHome(vendor: vendor)
            let provider: LocalUsageProvider =
                vendor == ProviderID.codex
                ? LocalUsageProvider.codex(
                    codexDir: home.dataDir, id: home.id, historyRoot: stateDir,
                    pricingOverride: config.pricingOverride, ledger: projectLedger,
                    backfill: window)
                : LocalUsageProvider.claudeCode(
                    claudeDir: home.dataDir, id: home.id, historyRoot: stateDir,
                    pricingOverride: config.pricingOverride,
                    profile: ClaudeProfileSource(url: home.claudeProfileURL),
                    ledger: projectLedger, backfill: window)
            if let catalog { await provider.applyPriceCatalog(catalog) }
            _ = await provider.backfillArchive()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(UsageHistoryStore.allDays(in: stateDir)),
            let text = String(data: data, encoding: .utf8)
        {
            print(text)
        }
    }
    sem.wait()
    exit(0)
}

// No flag, nothing to do. This binary used to be a LaunchAgent; the app runs
// the engine in-process now and it exists for CI — the self-test, the ccusage
// oracle's scan, the pricing seed and the catalog refresh. Saying so beats
// exiting silently on a typo'd flag.
sissyLog(
    """
    sissy-cli: no mode given. This binary is a CI tool, not a service.
      --self-test         pure formatter, pricing and parser assertions
      --scan              today's totals as JSON, optionally --scan-provider <id>
      --backfill          index what the CLIs already logged, then dump the archive
      --dump-seed         regenerate PricingSeed.swift from a live LiteLLM fetch
      --refresh-catalog   put a live LiteLLM catalog in the cache
      --config <path>     read an isolated server.json instead of the real one
    """)
exit(2)
