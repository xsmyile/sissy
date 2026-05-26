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

let args = CommandLine.arguments
if args.contains("--self-test") {
    runSelfTest()
    exit(0)
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
        var providers: [any UsageProvider] = []
        if scanFilter == "all" || scanFilter == "claude-code" {
            providers.append(ClaudeCodeUsageReader())
        }
        if scanFilter == "all" || scanFilter == "codex" {
            providers.append(CodexUsageReader())
        }
        var out: [String: Any] = [:]
        for p in providers {
            await p.start { _, _ in }
            try? await Task.sleep(for: .seconds(1))
            let (today, prev) = await p.current()
            var entry: [String: Any] = [
                "tokens": today.totalTokens,
                "cost": NSDecimalNumber(decimal: today.totalCost).stringValue,
                "filesWatched": p.filesWatched(),
            ]
            if let prev {
                entry["prevTokens"] = prev.totalTokens
                entry["prevCost"] = NSDecimalNumber(decimal: prev.totalCost).stringValue
            }
            out[p.id] = entry
            await p.stop()
        }
        let json = try? JSONSerialization.data(
            withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        if let data = json, let s = String(data: data, encoding: .utf8) {
            print(s)
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
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
