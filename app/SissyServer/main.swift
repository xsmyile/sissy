import Foundation
import NIOPosix

/// One provider's totals as emitted by `--scan`. Optional previous-day fields
/// are omitted from the JSON when the provider has no prior-day data.
struct ScanEntry: Encodable {
    let tokens: Int
    let cost: String
    let filesWatched: Int
    let prevTokens: Int?
    let prevCost: String?
    /// Plan the provider named for this account, so the value the panel badges
    /// can be read without a WebSocket client. Absent for a provider that
    /// names none — and for Codex also when the scan's one-second window
    /// closed before its first `token_count` event.
    let plan: String?
    let planTier: String?
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
            daemonLog("sissy-serverd: --dump-seed failed: \(error)")
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
    // embedded seed simply being older. Booting the server and grepping its
    // log for the refresh line did that until there was a server to boot.
    let sem = DispatchSemaphore(value: 0)
    var status: Int32 = 0
    Task.detached {
        defer { sem.signal() }
        do {
            let catalog = try await PriceCatalogSource.fetch()
            guard PriceCatalogSource.isUsable(catalog) else {
                daemonLog(
                    "sissy-serverd: --refresh-catalog rejected the fetched catalog "
                        + "(\(catalog.anthropic.count) anthropic, \(catalog.openai.count) openai rates) "
                        + "— upstream changed shape; the cache is left as it was")
                status = 1
                return
            }
            PriceCatalogSource.saveCache(catalog)
            daemonLog(
                "sissy-serverd: pricing catalog refreshed — "
                    + "\(catalog.anthropic.count + catalog.openai.count) rates cached at "
                    + PriceCatalogSource.cacheURL.path)
        } catch {
            daemonLog("sissy-serverd: --refresh-catalog failed: \(error)")
            status = 1
        }
    }
    sem.wait()
    exit(status)
}
// Optional `--config <path>` override. Lets smoke tests / integration runs
// point the daemon at an isolated config + JSONL tree without touching the
// user's real `~/Library/Application Support/Sissy/server.json`.
let configURL: URL = {
    guard let idx = args.firstIndex(of: "--config") else { return ServerConfig.defaultURL }
    guard idx + 1 < args.count else {
        daemonLog("sissy-serverd: --config requires a path argument")
        exit(2)
    }
    return URL(fileURLWithPath: args[idx + 1])
}()
let config: ServerConfig
do {
    config = try ServerConfig.load(from: configURL)
} catch {
    daemonLog("sissy-serverd: config load failed: \(error)")
    exit(1)
}

if args.contains("--scan") {
    // Optional provider filter (`--scan-provider claude-code|codex|all`,
    // default all). Lets the ccusage drift CI job dump just the Codex
    // totals as JSON without spinning up an HTTP server.
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
        // Same directories, overrides and pricing policy as the daemon, so
        // comparing this output against `ccusage` measures the daemon's real
        // behaviour rather than a set of defaults nobody runs.
        var providers: [any UsageProvider] = []
        if scanFilter == "all" || scanFilter == "claude-code" {
            providers.append(
                ClaudeCodeUsageReader(
                    claudeDir: config.resolvedClaudeDataDir,
                    pricingOverride: config.pricingOverride))
        }
        if scanFilter == "all" || scanFilter == "codex" {
            providers.append(
                CodexUsageReader(
                    codexDir: config.resolvedCodexDataDir,
                    pricingOverride: config.pricingOverride))
        }
        // No fetch here — `--scan` stays offline and fast. The cached catalog
        // only exists once a daemon has refreshed it; otherwise the embedded
        // seed prices, which is also what the daemon would do.
        if config.remotePricingEnabled, let cached = PriceCatalogSource.loadCache() {
            for p in providers { await p.applyPriceCatalog(cached) }
            daemonLog(
                "sissy-serverd: --scan pricing from cached catalog "
                    + "(fetched \(ISO8601DateFormatter().string(from: cached.fetchedAt)))")
        } else {
            daemonLog("sissy-serverd: --scan pricing from the embedded rate seed")
        }
        var out: [String: ScanEntry] = [:]
        for p in providers {
            await p.start { _, _ in }
            try? await Task.sleep(for: .seconds(1))
            let (today, prev) = await p.current()
            out[p.id] = ScanEntry(
                tokens: today.totalTokens,
                cost: NSDecimalNumber(decimal: today.totalCost).stringValue,
                filesWatched: p.filesWatched(),
                prevTokens: prev?.totalTokens,
                prevCost: prev.map { NSDecimalNumber(decimal: $0.totalCost).stringValue },
                plan: p.currentPlan(),
                planTier: p.currentPlanTier()
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

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let server = SissyServer(config: config, group: group, configURL: configURL)

Task {
    do {
        try await server.start()
        daemonLog("sissy-serverd listening on \(config.host):\(config.port)")
    } catch {
        daemonLog("sissy-serverd: start failed: \(error)")
        exit(1)
    }
}

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let shutdown: @Sendable () -> Void = {
    Task {
        await server.stop()
        try? await group.shutdownGracefully()
        exit(0)
    }
}
sigterm.setEventHandler(handler: shutdown)
sigint.setEventHandler(handler: shutdown)
sigterm.resume()
sigint.resume()

dispatchMain()
