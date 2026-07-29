import Foundation
import NIOPosix

let logFile: FileHandle? = {
    let logsURL = SissyPaths.logsDir
    do {
        try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
        let url = logsURL.appendingPathComponent("sissy.err.log")
        // Rotate the previous run's log if it grew past the cap. Single
        // generation kept (`sissy.err.1.log`) — enough to grep for last
        // boot's stderr after a crash, small enough to never need manual
        // cleanup. Triggered at startup only so steady-state daemons don't
        // pay the size-check cost on every write.
        rotateLogIfNeeded(at: url, maxBytes: 2 * 1024 * 1024)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    } catch {
        return nil
    }
}()

private func rotateLogIfNeeded(at url: URL, maxBytes: UInt64) {
    let fm = FileManager.default
    guard let attrs = try? fm.attributesOfItem(atPath: url.path),
        let size = (attrs[.size] as? NSNumber)?.uint64Value,
        size > maxBytes
    else { return }
    let rotated = url.deletingLastPathComponent()
        .appendingPathComponent("sissy.err.1.log")
    try? fm.removeItem(at: rotated)
    try? fm.moveItem(at: url, to: rotated)
}

func daemonLog(_ message: String) {
    let line = message.hasSuffix("\n") ? message : "\(message)\n"
    let data = Data(line.utf8)
    FileHandle.standardError.write(data)
    logFile?.write(data)
}

/// One provider's totals as emitted by `--scan`. Optional previous-day fields
/// are omitted from the JSON when the provider has no prior-day data.
struct ScanEntry: Encodable {
    let tokens: Int
    let cost: String
    let filesWatched: Int
    let prevTokens: Int?
    let prevCost: String?
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
                prevCost: prev.map { NSDecimalNumber(decimal: $0.totalCost).stringValue }
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
