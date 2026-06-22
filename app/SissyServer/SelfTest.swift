import Foundation

// CLI self-test is single-threaded; the mutable state is only ever touched
// from `runSelfTest`. `nonisolated(unsafe)` silences the Swift 6 diagnostic
// without adding lock overhead nobody benefits from.
nonisolated(unsafe) private var failures: [String] = []

/// Small reference holder used by tests that bridge an `async` reader API
/// to a `DispatchSemaphore.wait()` so the CLI driver stays sequential.
/// Swift 6 rejects capturing a `var` inside a `@Sendable` Task body; a
/// `final class` with `@unchecked Sendable` is the smallest workaround
/// that doesn't drag a lock into a single-threaded harness.
private final class TestBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

private func expect<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
    if actual == expected {
        print("  ok   \(name)")
    } else {
        failures.append("\(name): got \(actual), want \(expected)")
        print("  FAIL \(name): got \(actual), want \(expected)")
    }
}

func runSelfTest() {
    print(
        "build: \(SissyPaths.isDev ? "dev" : "release") · supportDir=\(SissyPaths.supportDirName) · defaultPort=\(SissyPaths.defaultServerPort)"
    )
    print("=== FrameBuilder ===")

    expect("fmtTokens(0)", FrameBuilder.fmtTokens(0), "0")
    expect("fmtTokens(999)", FrameBuilder.fmtTokens(999), "999")
    expect("fmtTokens(1000)", FrameBuilder.fmtTokens(1_000), "1.0K")
    expect("fmtTokens(9999)", FrameBuilder.fmtTokens(9_999), "10.0K")
    expect("fmtTokens(10000)", FrameBuilder.fmtTokens(10_000), "10K")
    expect("fmtTokens(1_234_567)", FrameBuilder.fmtTokens(1_234_567), "1.2M")
    expect("fmtTokens(12_000_000)", FrameBuilder.fmtTokens(12_000_000), "12M")

    expect("fmtBurn(0,1)", FrameBuilder.fmtBurn(tokens: 0, hoursElapsed: 1), "...")
    expect("fmtBurn(neg,1)", FrameBuilder.fmtBurn(tokens: -5, hoursElapsed: 1), "...")
    expect("fmtBurn(60k,1h)", FrameBuilder.fmtBurn(tokens: 60_000, hoursElapsed: 1), "60K")
    // 0.5h elapsed => double rate
    expect("fmtBurn(60k,0.5h)", FrameBuilder.fmtBurn(tokens: 60_000, hoursElapsed: 0.5), "120K")

    expect("fmtCost(0)", FrameBuilder.fmtCost(0), "0.00")
    expect("fmtCost(1.234)", FrameBuilder.fmtCost(Decimal(string: "1.234")!), "1.23")
    expect("fmtCost(9.99)", FrameBuilder.fmtCost(Decimal(string: "9.99")!), "9.99")
    expect("fmtCost(10)", FrameBuilder.fmtCost(10), "10.0")
    expect("fmtCost(99.9)", FrameBuilder.fmtCost(Decimal(string: "99.9")!), "99.9")
    expect("fmtCost(100)", FrameBuilder.fmtCost(100), "100")
    expect("fmtCost(199.7)", FrameBuilder.fmtCost(Decimal(string: "199.7")!), "199")

    let th = StateThresholds()
    expect(
        "state empty",
        FrameBuilder.pickState(today: DayTotals(totalTokens: 0, totalCost: 0), prev: nil, thresholds: th),
        "sleep")
    expect(
        "state think",
        FrameBuilder.pickState(today: DayTotals(totalTokens: 1_000, totalCost: 5), prev: nil, thresholds: th),
        "think")
    expect(
        "state code",
        FrameBuilder.pickState(
            today: DayTotals(totalTokens: 1_000, totalCost: 25), prev: nil, thresholds: th), "code")
    expect(
        "state glow",
        FrameBuilder.pickState(
            today: DayTotals(totalTokens: 1_000, totalCost: 120), prev: nil, thresholds: th), "glow")
    expect(
        "state angry",
        FrameBuilder.pickState(
            today: DayTotals(totalTokens: 1_000, totalCost: 250), prev: nil, thresholds: th), "angry")
    expect(
        "state trend",
        FrameBuilder.pickState(
            today: DayTotals(totalTokens: 1_000, totalCost: 15),
            prev: DayTotals(totalTokens: 1_000, totalCost: 10),
            thresholds: th), "trend")

    let frame = FrameBuilder.build(
        today: DayTotals(totalTokens: 2_500_000, totalCost: Decimal(string: "42.5")!),
        prev: nil,
        hoursElapsed: 5,
        primaryMetric: .tokens
    )
    expect("frame tokens", frame.tokens, "2.5M")
    expect("frame cost", frame.cost, "42.5")
    expect("frame burn", frame.burn, "500K")
    expect("frame state", frame.state, "code")
    expect("frame primary", frame.primary, "2.5M")
    expect("frame label", frame.primaryLabel, "TOKENS")

    let frameBurn = FrameBuilder.build(
        today: DayTotals(totalTokens: 2_500_000, totalCost: Decimal(string: "42.5")!),
        prev: nil,
        hoursElapsed: 5,
        primaryMetric: .burnRate
    )
    expect("burn primary", frameBurn.primary, "500K")
    expect("burn label", frameBurn.primaryLabel, "BURN/H")

    // ProviderSlice path: build() passes the array through verbatim and
    // sortProviders enforces the canonical wire order (claude-code, codex,
    // alphabetical). This is the contract `rebuildAndBroadcast` and the
    // app's `headerSubtitle` both depend on.
    let unordered = [
        ProviderSlice(id: "codex", tokens: 200, cost: Decimal(string: "1.50")!),
        ProviderSlice(id: "zzz", tokens: 1, cost: 0),
        ProviderSlice(id: "claude-code", tokens: 100, cost: Decimal(string: "2.00")!),
    ]
    let sorted = FrameBuilder.sortProviders(unordered)
    expect("provider order [0]", sorted[0].id, "claude-code")
    expect("provider order [1]", sorted[1].id, "codex")
    expect("provider order [2]", sorted[2].id, "zzz")
    let active = FrameBuilder.activeSlices([
        ProviderSlice(id: "codex", tokens: 0, cost: 0),
        ProviderSlice(id: "claude-code", tokens: 100, cost: Decimal(string: "2.00")!),
    ])
    expect("activeSlices drops zero-token CLI", active.count, 1)
    expect("activeSlices keeps used CLI", active.first?.id, "claude-code")
    let frameWithProviders = FrameBuilder.build(
        today: DayTotals(totalTokens: 301, totalCost: Decimal(string: "3.50")!),
        prev: nil,
        hoursElapsed: 1,
        primaryMetric: .tokens,
        providers: sorted
    )
    expect("frame providers count", frameWithProviders.providers.count, 3)
    expect("frame providers head id", frameWithProviders.providers.first?.id, "claude-code")
    expect("frame providers head tokens", frameWithProviders.providers.first?.tokens, 100)
    expect("frame providers head cost", frameWithProviders.providers.first?.cost, Decimal(string: "2.00")!)
    let frameNoProviders = FrameBuilder.build(
        today: DayTotals(totalTokens: 0, totalCost: 0),
        prev: nil,
        hoursElapsed: 1,
        primaryMetric: .tokens
    )
    expect("frame providers empty default", frameNoProviders.providers.isEmpty, true)

    print("=== Hub.encode ===")
    runHubEncodeTests()

    print("=== Pricing ===")

    // claude-opus-4 (deprecated) bills at $15/$75 — the row we ship matches
    // platform.claude.com's deprecated tier. A user-facing regression here
    // historically caused 3x under-billing on opus 4.0/4.1 sessions.
    expect(
        "opus deprecated exact", Pricing.price(for: "claude-opus-4"),
        ModelPricing(
            inputPerMTok: 15, outputPerMTok: 75, cacheReadPerMTok: 1.50,
            cacheCreationPerMTok: 18.75))
    expect(
        "opus 4.1 exact", Pricing.price(for: "claude-opus-4-1"),
        ModelPricing(
            inputPerMTok: 15, outputPerMTok: 75, cacheReadPerMTok: 1.50,
            cacheCreationPerMTok: 18.75))
    // Opus 4.5+ is the current $5/$25 tier; longest-prefix routes
    // `claude-opus-4-7-<dateversion>` onto the matching family row.
    expect(
        "opus 4.5+ family", Pricing.price(for: "claude-opus-4-7"),
        ModelPricing(
            inputPerMTok: 5, outputPerMTok: 25, cacheReadPerMTok: 0.5,
            cacheCreationPerMTok: 6.25))
    // Regression: a current Opus minor without its own row falls through
    // longest-prefix to `claude-opus-4` (deprecated $15/$75) and triple-bills.
    // The date-suffixed name is what `message.model` actually carries.
    expect(
        "opus 4.8 current rate", Pricing.price(for: "claude-opus-4-8-20260515"),
        ModelPricing(
            inputPerMTok: 5, outputPerMTok: 25, cacheReadPerMTok: 0.5,
            cacheCreationPerMTok: 6.25))
    expect(
        "sonnet family", Pricing.price(for: "claude-sonnet-4-6"),
        ModelPricing(inputPerMTok: 3, outputPerMTok: 15, cacheReadPerMTok: 0.3, cacheCreationPerMTok: 3.75))
    expect(
        "haiku family", Pricing.price(for: "claude-haiku-4-5"),
        ModelPricing(inputPerMTok: 1, outputPerMTok: 5, cacheReadPerMTok: 0.1, cacheCreationPerMTok: 1.25))
    expect(
        "3-5-sonnet", Pricing.price(for: "claude-3-5-sonnet-20241022"),
        ModelPricing(inputPerMTok: 3, outputPerMTok: 15, cacheReadPerMTok: 0.3, cacheCreationPerMTok: 3.75))
    expect("unknown", Pricing.price(for: "gpt-4"), nil)

    // 1M input + 100k output on Sonnet = 1*3 + 0.1*15 = 4.50
    let cost = Pricing.cost(
        model: "claude-sonnet-4-6", input: 1_000_000, output: 100_000, cacheRead: 0, cacheCreation: 0)
    expect("sonnet 1M+100k", cost, Decimal(string: "4.50")!)

    // input 6*5/M = 0.00003, output 411*25/M = 0.010275,
    // cache_creation 36582*6.25/M = 0.2286375; total raw = 0.2389425
    let cacheCost = Pricing.cost(
        model: "claude-opus-4-7", input: 6, output: 411, cacheRead: 0, cacheCreation: 36582)
    expect("opus cached", cacheCost, Decimal(string: "0.238942")!)

    // pricingOverride shadows the built-in table — exact key wins.
    let exactOverride: [String: ModelPricing] = [
        "claude-sonnet-4-6": .init(
            inputPerMTok: 10, outputPerMTok: 20, cacheReadPerMTok: 1, cacheCreationPerMTok: 2)
    ]
    let overriddenExact = Pricing.cost(
        model: "claude-sonnet-4-6", input: 1_000_000, output: 0, cacheRead: 0, cacheCreation: 0,
        override: exactOverride)
    expect("override exact wins", overriddenExact, Decimal(string: "10.00")!)
    // Override entries match by longest-prefix the same way the built-in
    // table does, so a family-level override propagates to point releases.
    let prefixOverride: [String: ModelPricing] = [
        "claude-opus-4": .init(
            inputPerMTok: 100, outputPerMTok: 100, cacheReadPerMTok: 100, cacheCreationPerMTok: 100)
    ]
    let overriddenPrefix = Pricing.cost(
        model: "claude-opus-4-7", input: 1_000_000, output: 0, cacheRead: 0, cacheCreation: 0,
        override: prefixOverride)
    expect("override prefix wins", overriddenPrefix, Decimal(string: "100.00")!)
    // Unmatched models fall back to the built-in table.
    let unrelatedOverride: [String: ModelPricing] = [
        "claude-haiku-4": .init(
            inputPerMTok: 999, outputPerMTok: 999, cacheReadPerMTok: 999, cacheCreationPerMTok: 999)
    ]
    let fallback = Pricing.cost(
        model: "claude-sonnet-4-6", input: 1_000_000, output: 100_000, cacheRead: 0, cacheCreation: 0,
        override: unrelatedOverride)
    expect("override miss falls back", fallback, Decimal(string: "4.50")!)
    // Empty override map must not poison the fallback.
    let emptyOverride = Pricing.cost(
        model: "claude-sonnet-4-6", input: 1_000_000, output: 100_000, cacheRead: 0, cacheCreation: 0,
        override: [:])
    expect("empty override falls back", emptyOverride, Decimal(string: "4.50")!)

    print("=== ServerConfig ===")
    runServerConfigTests()

    print("=== ClaudeCodeUsageReader.parseISODate ===")
    runISODateTests()

    print("=== ClaudeCodeUsageReader.bufferContainsAssistantMarker ===")
    runAssistantMarkerTests()

    print("=== UsageStatePersistence ===")
    runPersistenceTests()

    print("=== MilestoneTracker ===")
    runMilestoneTests()

    print("=== ClaudeCodeUsageReader.streamingIngest ===")
    runStreamingIngestTests()

    print("=== OpenAIPricing ===")
    runOpenAIPricingTests()

    print("=== CodexUsageReader.streamingIngest ===")
    runCodexParserTests()
    runCodexModelBackfillTest()

    print("=== FSWatcher ===")
    runFSWatcherTests()

    print("=== done ===")
    if failures.isEmpty {
        print("ALL PASS")
    } else {
        print("FAILURES: \(failures.count)")
        for f in failures { print("  - \(f)") }
        exit(1)
    }
}

/// Round-trip a `FrameData` through `Hub.broadcast` and inspect the encoded
/// payload via a captive sink. Guarantees the wire shape app + firmware both
/// parse against stays in lock-step with what `FrameBuilder` produces.
private func runHubEncodeTests() {
    final class CapturingSink: FrameSink, @unchecked Sendable {
        let lock = NSLock()
        var payload: Data?
        func deliver(_ data: Data) async {
            lock.withLock { self.payload = data }
        }
    }
    let sink = CapturingSink()
    let frame = FrameBuilder.build(
        today: DayTotals(totalTokens: 33_121_400, totalCost: Decimal(string: "23.99")!),
        prev: nil,
        hoursElapsed: 1,
        primaryMetric: .tokens,
        providers: [
            ProviderSlice(id: "claude-code", tokens: 33_121_400, cost: Decimal(string: "23.99")!),
            ProviderSlice(id: "codex", tokens: 0, cost: 0),
        ]
    )
    let sem = DispatchSemaphore(value: 0)
    Task {
        let hub = Hub()
        await hub.register(sink)
        await hub.broadcast(frame)
        sem.signal()
    }
    sem.wait()
    let data = sink.lock.withLock { sink.payload } ?? Data()
    expect("hub encoded payload non-empty", !data.isEmpty, true)
    guard
        let any = try? JSONSerialization.jsonObject(with: data),
        let dict = any as? [String: Any]
    else {
        expect("hub payload decodes as dict", false, true)
        return
    }
    expect("hub payload type", dict["type"] as? String, "frame")
    guard let providers = dict["providers"] as? [[String: Any]] else {
        expect("hub payload providers is array", false, true)
        return
    }
    expect("hub payload providers count", providers.count, 2)
    expect("hub payload providers[0].id", providers[0]["id"] as? String, "claude-code")
    expect("hub payload providers[0].tokens", providers[0]["tokens"] as? Int, 33_121_400)
    // Cost round-trips lossless: stringValue on the daemon, Decimal(string:)
    // on the consumer. Drift here would re-introduce the bug this refactor
    // exists to fix.
    let costStr = providers[0]["cost"] as? String ?? ""
    expect("hub payload providers[0].cost roundtrip", Decimal(string: costStr), Decimal(string: "23.99")!)
    expect("hub payload providers[1].id", providers[1]["id"] as? String, "codex")
    expect("hub payload providers[1].tokens", providers[1]["tokens"] as? Int, 0)
}

private func runServerConfigTests() {
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory.appendingPathComponent(
        "sissy-config-self-test-\(UUID().uuidString)"
    )
    try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempDir) }

    expect("defaults tokenless loopback", ServerConfig.defaults.host, "127.0.0.1")

    let tokenlessURL = tempDir.appendingPathComponent("tokenless.json")
    try? Data(#"{"host":"0.0.0.0","port":8787,"authToken":""}"#.utf8).write(to: tokenlessURL)
    do {
        let loaded = try ServerConfig.load(from: tokenlessURL)
        expect("tokenless wildcard restricted", loaded.host, "127.0.0.1")
    } catch {
        expect("tokenless config loads", false, true)
    }

    let tokenURL = tempDir.appendingPathComponent("token.json")
    try? Data(#"{"host":"0.0.0.0","port":8787,"authToken":"abc123"}"#.utf8).write(to: tokenURL)
    do {
        let loaded = try ServerConfig.load(from: tokenURL)
        expect("token wildcard preserved", loaded.host, "0.0.0.0")
    } catch {
        expect("token config loads", false, true)
    }

    // MilestoneFrequency lookup + invalid-key fallback.
    expect("normal cost step", MilestoneFrequency.costStep(for: "normal"), 25)
    expect(
        "invalid preset falls back to normal",
        MilestoneFrequency.costStep(for: "asdf-not-a-preset"), 25)
    expect("preset validator accepts normal", MilestoneFrequency.isValid("normal"), true)
    expect("preset validator rejects junk", MilestoneFrequency.isValid("frenetic"), false)

    // ServerConfig.save roundtrip: emits valid JSON that ServerConfig.load
    // can ingest, and milestoneFrequency carries through.
    let saveURL = tempDir.appendingPathComponent("roundtrip.json")
    var cfg = ServerConfig.defaults
    cfg.milestoneFrequency = "sparse"
    cfg.authToken = "tok"
    do {
        try ServerConfig.save(cfg, to: saveURL)
        let reloaded = try ServerConfig.load(from: saveURL)
        expect("save roundtrip milestoneFrequency", reloaded.milestoneFrequency, "sparse")
        expect("save roundtrip authToken", reloaded.authToken, "tok")
    } catch {
        expect("save roundtrip", false, true)
    }

    // Backwards compat: a server.json without `milestoneFrequency` merges
    // into the default ("normal") rather than failing to load.
    let legacyURL = tempDir.appendingPathComponent("legacy.json")
    try? Data(
        #"{"host":"127.0.0.1","port":8787,"authToken":"x","primaryMetric":"tokens"}"#.utf8
    ).write(to: legacyURL)
    do {
        let loaded = try ServerConfig.load(from: legacyURL)
        expect("legacy config defaults milestoneFrequency", loaded.milestoneFrequency, "normal")
    } catch {
        expect("legacy config loads", false, true)
    }
}

private func runISODateTests() {
    // Fractional seconds round-trip
    let withFrac = ClaudeCodeUsageReader.parseISODate("2026-05-19T10:01:38.269Z")
    expect("iso with frac non-nil", withFrac != nil, true)
    if let d = withFrac {
        // 1779184898.269 derived from epoch math; allow ms slack against fp.
        let delta = abs(d.timeIntervalSince1970 - 1779184898.269)
        expect("iso with frac value within 1ms", delta < 0.001, true)
    }
    // No fractional
    let noFrac = ClaudeCodeUsageReader.parseISODate("2026-05-19T10:01:38Z")
    expect("iso no frac non-nil", noFrac != nil, true)
    if let d = noFrac {
        expect("iso no frac value", Int(d.timeIntervalSince1970), 1_779_184_898)
    }
    // Wrong shape (offset timezone) falls back to nil so caller hits formatter
    expect("iso offset tz returns nil", ClaudeCodeUsageReader.parseISODate("2026-05-19T10:01:38+02:00"), nil)
    expect("iso missing Z returns nil", ClaudeCodeUsageReader.parseISODate("2026-05-19T10:01:38"), nil)
    expect("iso too short returns nil", ClaudeCodeUsageReader.parseISODate("2026-05-19"), nil)
    expect("iso bad separator returns nil", ClaudeCodeUsageReader.parseISODate("2026/05/19T10:01:38Z"), nil)
    expect("iso non-digit returns nil", ClaudeCodeUsageReader.parseISODate("20XX-05-19T10:01:38Z"), nil)
    // Leap day
    let leap = ClaudeCodeUsageReader.parseISODate("2024-02-29T12:00:00Z")
    expect("iso leap day non-nil", leap != nil, true)
}

private func runAssistantMarkerTests() {
    func has(_ s: String) -> Bool {
        var bytes = Array(s.utf8)
        return bytes.withUnsafeMutableBufferPointer { buf in
            ClaudeCodeUsageReader.bufferContainsAssistantMarker(buf.baseAddress!, from: 0, to: buf.count)
        }
    }
    expect("marker present compact", has("{\"type\":\"assistant\",\"x\":1}"), true)
    expect("marker present at start", has("\"type\":\"assistant\""), true)
    expect("marker present at end", has("xxxxxxxxxxxxxxxxxxxx\"type\":\"assistant\""), true)
    expect("marker absent user line", has("{\"type\":\"user\",\"x\":1}"), false)
    expect("marker absent empty", has(""), false)
    expect("marker absent prefix only", has("{\"type\":\"assi"), false)
    // Prefilter tolerates the JSON-whitespace forms an encoder may emit.
    expect("marker present with space", has("\"type\": \"assistant\""), true)
    expect("marker present with tab", has("\"type\":\t\"assistant\""), true)
    expect("marker present padded key", has("\"type\" : \"assistant\""), true)
    // Other-value "type" entries must not match.
    expect("marker absent user spaced", has("\"type\": \"user\""), false)
}

private func runPersistenceTests() {
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory.appendingPathComponent(
        "sissy-self-test-\(UUID().uuidString)"
    )
    try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempDir) }
    let url = tempDir.appendingPathComponent("usage-state.json")

    let snapshot = UsageStateSnapshot(
        schemaVersion: UsageStateSnapshot.currentSchemaVersion,
        savedAt: Date(timeIntervalSince1970: 1_779_184_898),
        claudeDataDirHash: "abc123",
        retainDays: 2,
        files: [
            .init(path: "/tmp/a.jsonl", offset: 1234, mtimeUnix: 1779184800.5)
        ],
        dailyTotals: [
            .init(day: "2026-05-19", tokens: 172_818_771, cost: "115.327")
        ],
        dedupKeysToday: [
            .init(key: "rid:abc", day: "2026-05-19")
        ]
    )

    do {
        try UsageStatePersistence.save(snapshot, to: url)
    } catch {
        expect("save succeeds", false, true)
        return
    }
    expect("snapshot file exists after save", fm.fileExists(atPath: url.path), true)

    switch UsageStatePersistence.load(from: url) {
    case .ok(let loaded):
        expect("roundtrip schema", loaded.schemaVersion, snapshot.schemaVersion)
        expect("roundtrip hash", loaded.claudeDataDirHash, snapshot.claudeDataDirHash)
        expect("roundtrip retain", loaded.retainDays, snapshot.retainDays)
        expect("roundtrip files", loaded.files, snapshot.files)
        expect("roundtrip totals", loaded.dailyTotals, snapshot.dailyTotals)
        expect("roundtrip dedup", loaded.dedupKeysToday, snapshot.dedupKeysToday)
        // Decimal precision survives the String round-trip.
        if let row = loaded.dailyTotals.first,
            let dec = Decimal(string: row.cost)
        {
            expect("decimal roundtrip", dec, Decimal(string: "115.327")!)
        }
    default:
        expect("load returns .ok", false, true)
    }

    // Corrupt JSON → quarantined + .invalid
    let corruptURL = tempDir.appendingPathComponent("usage-state-corrupt.json")
    try? Data("not json".utf8).write(to: corruptURL)
    switch UsageStatePersistence.load(from: corruptURL) {
    case .invalid:
        expect("corrupt -> invalid", true, true)
        // Quarantined file written next to original.
        let dirContents = (try? fm.contentsOfDirectory(atPath: tempDir.path)) ?? []
        let hasQuarantine = dirContents.contains { $0.hasPrefix("usage-state-corrupt.json.corrupt-") }
        expect("corrupt quarantined", hasQuarantine, true)
    default:
        expect("corrupt path returned .invalid", false, true)
    }

    // Missing file → .missing
    let missingURL = tempDir.appendingPathComponent("does-not-exist.json")
    if case .missing = UsageStatePersistence.load(from: missingURL) {
        expect("missing -> .missing", true, true)
    } else {
        expect("missing path returns .missing", false, true)
    }

    // Schema mismatch → .invalid + quarantine
    let mismatchURL = tempDir.appendingPathComponent("usage-state-vN.json")
    let mismatch = UsageStateSnapshot(
        schemaVersion: 99,
        savedAt: Date(),
        claudeDataDirHash: "x",
        retainDays: 2,
        files: [],
        dailyTotals: [],
        dedupKeysToday: []
    )
    try? UsageStatePersistence.save(mismatch, to: mismatchURL)
    if case .invalid = UsageStatePersistence.load(from: mismatchURL) {
        expect("schema mismatch -> invalid", true, true)
    } else {
        expect("schema mismatch returns invalid", false, true)
    }

    // hashDataDir is deterministic and changes with path
    let h1 = UsageStatePersistence.hashDataDir(URL(fileURLWithPath: "/a/b"))
    let h2 = UsageStatePersistence.hashDataDir(URL(fileURLWithPath: "/a/b"))
    let h3 = UsageStatePersistence.hashDataDir(URL(fileURLWithPath: "/a/c"))
    expect("hash stable", h1 == h2, true)
    expect("hash differs by path", h1 != h3, true)
}

private func runMilestoneTests() {
    // First call seeds the bucket from current totals — no fire even when the
    // user is already well past several thresholds. Critical: this is what
    // protects a daemon-restart-mid-day from burst-firing the milestones a
    // heavy session has already crossed.
    var t = MilestoneTracker()
    let day = "2026-05-20"
    let seed = t.check(
        today: DayTotals(totalTokens: 329_000_000, totalCost: Decimal(string: "211.00")!),
        dayKey: day)
    expect("seed no fire", seed, nil)
    expect("seed costBucket", t.costBucket, 8)  // 211 / 25

    // No crossing → no fire even though totals advance a few dollars within
    // the same bucket.
    let inSameBucket = t.check(
        today: DayTotals(totalTokens: 340_000_000, totalCost: Decimal(string: "215.00")!),
        dayKey: day)
    expect("no crossing no fire", inSameBucket, nil)

    // Cost crossing fires immediately, no queue.
    let costCross = t.check(
        today: DayTotals(totalTokens: 350_000_000, totalCost: Decimal(string: "225.00")!),
        dayKey: day)
    expect("cost cross", costCross, "cost:225")
    expect("cost bucket advanced", t.costBucket, 9)

    // Day rollover wipes bucket without firing anything from yesterday's
    // accumulated total.
    var t3 = MilestoneTracker()
    _ = t3.check(
        today: DayTotals(totalTokens: 200_000_000, totalCost: Decimal(string: "100.00")!),
        dayKey: "2026-05-19")
    let nextDay = t3.check(
        today: DayTotals(totalTokens: 0, totalCost: 0),
        dayKey: "2026-05-20")
    expect("day rollover no fire", nextDay, nil)
    expect("rollover resets costBucket", t3.costBucket, 0)
    expect("rollover day key updated", t3.dayKey, "2026-05-20")

    // Custom step value: tracker with $5 step fires more aggressively.
    var tCustom = MilestoneTracker(presetKey: "very_frequent", costStep: 5)
    _ = tCustom.check(
        today: DayTotals(totalTokens: 0, totalCost: 0), dayKey: day)
    let customCross = tCustom.check(
        today: DayTotals(totalTokens: 10_000_000, totalCost: Decimal(string: "5.00")!),
        dayKey: day)
    expect("custom step cost cross", customCross, "cost:5")

    // Preset change via `applyPreset`: silent reseed, no fire on next
    // check even when totals would imply crossings under the new step.
    var tPreset = MilestoneTracker(presetKey: "normal", costStep: 25)
    _ = tPreset.check(
        today: DayTotals(totalTokens: 100_000_000, totalCost: Decimal(string: "50.00")!),
        dayKey: day)
    expect("preset normal bucket", tPreset.costBucket, 2)
    tPreset.applyPreset(presetKey: "frequent", costStep: 10)
    expect("preset change clears dayKey", tPreset.dayKey, nil)
    let postPreset = tPreset.check(
        today: DayTotals(totalTokens: 100_000_000, totalCost: Decimal(string: "50.00")!),
        dayKey: day)
    expect("preset reseed no fire", postPreset, nil)
    expect("preset reseed cost bucket", tPreset.costBucket, 5)  // 50 / 10

    // Ratchet-down: persisted bucket can be larger than what today's
    // totals would imply, e.g. after a snapshot invalidation that
    // recomputes today smaller than what the milestone file last saw.
    // Without snap-down, every crossing in the gap is permanently
    // swallowed because the monotonic-up firing check never passes.
    var t4 = MilestoneTracker()
    t4.dayKey = day
    t4.costBucket = 5  // claims $125 crossed
    let snap = t4.check(
        today: DayTotals(totalTokens: 108_000_000, totalCost: Decimal(string: "73.00")!),
        dayKey: day)
    expect("snap-down no fire", snap, nil)
    expect("snap-down costBucket", t4.costBucket, 2)  // 73 / 25
    let postSnapCross = t4.check(
        today: DayTotals(totalTokens: 108_000_000, totalCost: Decimal(string: "75.00")!),
        dayKey: day)
    expect("snap-down then fire cost", postSnapCross, "cost:75")
    expect("snap-down then bucket advanced", t4.costBucket, 3)

    // Legacy decoder: a snapshot from the old token+cost era still loads.
    // Stale `tokenBucket` is dropped; `costBucket` and `presetKey` carry
    // through. Cost-only checks resume against the loaded bucket.
    let legacyJSON = #"{"costBucket":4,"dayKey":"2026-05-20","presetKey":"normal","tokenBucket":7}"#
    if let legacyData = legacyJSON.data(using: .utf8),
        let decoded = try? JSONDecoder().decode(MilestoneTracker.self, from: legacyData)
    {
        expect("legacy decode preserves costBucket", decoded.costBucket, 4)
        expect("legacy decode preserves dayKey", decoded.dayKey, "2026-05-20")
        expect("legacy decode preserves presetKey", decoded.presetKey, "normal")
    } else {
        expect("legacy tracker decodes", false, true)
    }
}

/// End-to-end check that the chunked reader still tallies a JSONL file with
/// a line that straddles a 64 KB chunk boundary. Regression guard for the
/// streaming refactor — the old `readDataToEndOfFile()` path slurped the
/// whole delta and was trivially correct; the new code has to stitch a
/// carry buffer across chunk reads.
private func runStreamingIngestTests() {
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory.appendingPathComponent(
        "sissy-stream-self-test-\(UUID().uuidString)"
    )
    try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempDir) }

    let jsonl = tempDir.appendingPathComponent("session.jsonl")
    let isoFmt = ISO8601DateFormatter()
    isoFmt.formatOptions = [.withInternetDateTime]
    let nowStr = isoFmt.string(from: Date())

    func line(rid: String, padBytes: Int = 0) -> String {
        let pad =
            padBytes > 0
            ? ",\"pad\":\"\(String(repeating: "x", count: padBytes))\""
            : ""
        // 1M input tokens × $3/Mtok (sonnet) = $3.00 per line.
        return
            "{\"type\":\"assistant\",\"timestamp\":\"\(nowStr)\",\"requestId\":\"\(rid)\"\(pad),\"message\":{\"model\":\"claude-sonnet-4-6\",\"usage\":{\"input_tokens\":1000000,\"output_tokens\":0,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}}"
    }
    // r2 is padded past the 64 KB chunk size so it straddles boundaries; r1
    // and r3 land entirely within their own chunks.
    let payload =
        line(rid: "r1") + "\n"
        + line(rid: "r2", padBytes: 80_000) + "\n"
        + line(rid: "r3") + "\n"
    try? payload.write(to: jsonl, atomically: true, encoding: .utf8)

    let sem = DispatchSemaphore(value: 0)
    let box = TestBox<(tokens: Int, cost: Decimal)>((0, 0))
    Task {
        let reader = ClaudeCodeUsageReader(
            claudeDir: tempDir,
            retainDays: 2,
            pollInterval: .seconds(60),
            persistenceURL: nil
        )
        await reader.start { _, _ in }
        let (today, _) = await reader.current()
        box.value = (today.totalTokens, today.totalCost)
        await reader.stop()
        sem.signal()
    }
    sem.wait()
    expect("stream ingest tokens", box.value.tokens, 3_000_000)
    expect("stream ingest cost", box.value.cost, Decimal(string: "9.00")!)
}

/// End-to-end FSEvents wakeup test. Spins up an `FSWatcher` over a temp
/// directory, appends to a `.jsonl` file inside it, and asserts the
/// callback fires within the FSEvents latency window plus a generous
/// safety margin. macOS FSEvents has a hard ~1 s coalesce floor on most
/// filesystems, so an 8 s timeout gives plenty of headroom on a loaded
/// build agent.
private func runFSWatcherTests() {
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory.appendingPathComponent(
        "sissy-fswatch-self-test-\(UUID().uuidString)"
    )
    try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    // FSEvents only delivers events whose paths can be canonicalized via
    // realpath(3). On macOS `~/T -> /var/folders/...` is a symlink chain
    // (/var → /private/var). URL.resolvingSymlinksInPath doesn't always
    // collapse the chain (returns the original /var path for
    // not-yet-existing children); use NSString resolution which calls
    // realpath under the hood.
    let canonicalPath = (tempDir.path as NSString).resolvingSymlinksInPath
    let resolvedDir = URL(fileURLWithPath: canonicalPath)
    defer { try? fm.removeItem(at: tempDir) }

    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var urls: [URL] = []
    }
    let box = Box()
    let sem = DispatchSemaphore(value: 0)
    let target = resolvedDir.appendingPathComponent("session.jsonl")

    let watcher = FSWatcher(label: "sissy.test.fswatch")
    // ignoreSelf: false because this process is the writer in the test;
    // production keeps the default true since the daemon never writes
    // inside the watched tree.
    let ok = watcher.start(path: resolvedDir, latency: 0.5, ignoreSelf: false) { event in
        let done = box.lock.withLock { () -> Bool in
            box.urls.append(contentsOf: event.urls)
            return box.urls.contains(where: { $0.lastPathComponent == "session.jsonl" })
        }
        if done { sem.signal() }
    }
    expect("FSWatcher start ok", ok, true)

    // FSEvents needs a brief settle window after start before the kernel
    // begins reporting events from the watched path. On loaded build
    // agents 0.3 s isn't always enough; 0.6 s leaves headroom.
    Thread.sleep(forTimeInterval: 0.6)

    // Non-atomic append: atomic writes go through a temp+rename, which
    // emits rename-style events on some FS configurations and complicates
    // the assertion. A plain write produces a create+modify under the
    // expected filename.
    if let fh = try? FileHandle(forWritingTo: target) {
        try? fh.write(contentsOf: Data("{}\n".utf8))
        try? fh.close()
    } else {
        FileManager.default.createFile(atPath: target.path, contents: Data("{}\n".utf8))
    }

    let waited = sem.wait(timeout: .now() + 8.0)
    expect("FSWatcher event delivered", waited, DispatchTimeoutResult.success)
    let observedNames = box.lock.withLock { box.urls.map(\.lastPathComponent) }
    expect("FSWatcher saw target file", observedNames.contains("session.jsonl"), true)
    watcher.stop()

    // Double-stop must be safe (idempotent invalidate).
    watcher.stop()
    expect("FSWatcher double-stop ok", true, true)
}

private func runOpenAIPricingTests() {
    // gpt-5-codex: $1.25/M input, $10/M output, $0.125/M cache_read.
    let exact = OpenAIPricing.price(for: "gpt-5-codex")
    expect(
        "gpt-5-codex exact",
        exact,
        ModelPricing(
            inputPerMTok: 1.25, outputPerMTok: 10, cacheReadPerMTok: 0.125,
            cacheCreationPerMTok: 0))
    // gpt-5.2-codex and gpt-5.5 ship at materially different rates from
    // gpt-5; missing rows used to fall back to gpt-5 pricing and silently
    // under-bill — 1.4× on 5.2, 4× on 5.5.
    expect(
        "gpt-5.2-codex exact",
        OpenAIPricing.price(for: "gpt-5.2-codex"),
        ModelPricing(
            inputPerMTok: 1.75, outputPerMTok: 14, cacheReadPerMTok: 0.175,
            cacheCreationPerMTok: 0))
    expect(
        "gpt-5.5 exact",
        OpenAIPricing.price(for: "gpt-5.5"),
        ModelPricing(
            inputPerMTok: 5.00, outputPerMTok: 30, cacheReadPerMTok: 0.50,
            cacheCreationPerMTok: 0))

    // Longest-prefix family match — `gpt-5-codex-experimental` → `gpt-5-codex`,
    // not `gpt-5`, because `gpt-5-codex` is the longer prefix.
    let prefix = OpenAIPricing.price(for: "gpt-5-codex-experimental")
    expect(
        "gpt-5-codex prefix wins over gpt-5",
        prefix?.inputPerMTok, Decimal(string: "1.25")!)

    // Unknown OpenAI model returns nil so the daemon doesn't silently bill at
    // a wrong rate. Cost path then returns 0 — surfacing the gap, not hiding
    // it.
    expect("unknown openai model", OpenAIPricing.price(for: "claude-opus-4"), nil)

    // Real fixture line: input=14297, cached=9600, output=361, reasoning=0.
    // After token-mapping: uncached=4697, output=361, cacheRead=9600.
    // Cost = (4697*1.25 + 361*10 + 9600*0.125) / 1_000_000
    //     = (5871.25 + 3610 + 1200) / 1_000_000
    //     = 10681.25 / 1_000_000 = 0.010681 (bankers, 6dp).
    let cost = OpenAIPricing.cost(
        model: "gpt-5-codex", input: 4_697, output: 361, cacheRead: 9_600)
    expect("gpt-5-codex sample cost", cost, Decimal(string: "0.010681")!)

    // `output_tokens` is gross — reasoning is a sub-breakdown, NOT additive.
    // Verified on real rollouts: `total_tokens == input_tokens + output_tokens`
    // regardless of reasoning_output_tokens. CodexUsageReader passes
    // `output_tokens` straight through (no `+ reasoning`), matching ccusage.
    let onlyOutput = OpenAIPricing.cost(
        model: "gpt-5", input: 1_000_000, output: 100_000, cacheRead: 0)
    // 1M input * $1.25 + 100k output * $10 = $1.25 + $1.00 = $2.25
    expect("gpt-5 output billed once (no reasoning add-on)", onlyOutput, Decimal(string: "2.25")!)
}

/// End-to-end Codex JSONL ingest. Feeds a fixture with a `turn_context` model
/// declaration followed by two `token_count` events into a fresh reader and
/// verifies the resulting `today` total matches what the field-mapping math
/// implies. Doubles as the regression guard for `last_token_usage` being the
/// per-turn delta (not cumulative) — if that ever flips, the totals here
/// double.
private func runCodexParserTests() {
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory.appendingPathComponent(
        "sissy-codex-self-test-\(UUID().uuidString)"
    )
    try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempDir) }

    // Codex nests rollouts in YYYY/MM/DD subdirs. The reader's enumerator
    // recurses, but using a real-shaped path also guards against the FS
    // walker accidentally regressing to top-level-only.
    let subdir = tempDir.appendingPathComponent("2026/05/25", isDirectory: true)
    try? fm.createDirectory(at: subdir, withIntermediateDirectories: true)
    let jsonl = subdir.appendingPathComponent("rollout-2026-05-25T10-12-05-test.jsonl")

    let isoFmt = ISO8601DateFormatter()
    isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let nowStr = isoFmt.string(from: Date())

    // Two events sharing the same gpt-5-codex turn_context. Field values
    // mirror the real-fixture first two events the plan was designed
    // against.
    let payload = """
        {"type":"session_meta","timestamp":"\(nowStr)","payload":{"id":"test","timestamp":"\(nowStr)","model_provider":"openai"}}
        {"type":"turn_context","timestamp":"\(nowStr)","payload":{"turn_id":"t1","model":"gpt-5-codex"}}
        {"type":"event_msg","timestamp":"\(nowStr)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":14297,"cached_input_tokens":9600,"output_tokens":361,"reasoning_output_tokens":0,"total_tokens":14658},"total_token_usage":{"input_tokens":14297,"cached_input_tokens":9600,"output_tokens":361,"reasoning_output_tokens":0,"total_tokens":14658}}}}
        {"type":"event_msg","timestamp":"\(nowStr)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":28035,"cached_input_tokens":9600,"output_tokens":546,"reasoning_output_tokens":66,"total_tokens":28581},"total_token_usage":{"input_tokens":42332,"cached_input_tokens":19200,"output_tokens":907,"reasoning_output_tokens":66,"total_tokens":43239}}}}
        """ + "\n"
    try? payload.write(to: jsonl, atomically: true, encoding: .utf8)

    let sem = DispatchSemaphore(value: 0)
    let box = TestBox<(tokens: Int, cost: Decimal)>((0, 0))
    Task {
        let reader = CodexUsageReader(
            codexDir: tempDir,
            retainDays: 2,
            pollInterval: .seconds(60),
            persistenceURL: nil
        )
        await reader.start { _, _ in }
        let (today, _) = await reader.current()
        box.value = (today.totalTokens, today.totalCost)
        await reader.stop()
        sem.signal()
    }
    sem.wait()

    // Event 1: uncached=4697, output=361, cacheRead=9600 → 14658 tokens
    // Event 2: uncached=28035-9600=18435, output=546 (reasoning is a
    //   sub-breakdown of output, not additive), cacheRead=9600 → 28581 tokens
    // Sum: 43239 tokens
    expect("codex sum tokens", box.value.tokens, 14_658 + 18_435 + 546 + 9_600)

    // Sum costs are recomputed via OpenAIPricing so any future rate
    // change rolls through both sides of the comparison.
    let event1 = OpenAIPricing.cost(model: "gpt-5-codex", input: 4_697, output: 361, cacheRead: 9_600)
    let event2 = OpenAIPricing.cost(model: "gpt-5-codex", input: 18_435, output: 546, cacheRead: 9_600)
    expect("codex sum cost", box.value.cost, event1 + event2)

    // Dedup belt-and-suspenders: re-running ingest on the same file (no new
    // bytes) must not double-count. Touch mtime via a no-op append of "".
    // The reader's mtime+size short-circuit suppresses re-read anyway, but
    // verify the dedup keys would catch a fault path too.
    let sem2 = DispatchSemaphore(value: 0)
    let replay = TestBox<Int>(0)
    Task {
        // Re-construct a reader pointing at the same tree. With no
        // persistence URL it cold-scans from offset 0 — same result as the
        // first reader because the per-turn `last_token_usage` events sum
        // identically regardless of how many times the reader reboots.
        let reader = CodexUsageReader(
            codexDir: tempDir,
            retainDays: 2,
            pollInterval: .seconds(60),
            persistenceURL: nil
        )
        await reader.start { _, _ in }
        let (today, _) = await reader.current()
        replay.value = today.totalTokens
        await reader.stop()
        sem2.signal()
    }
    sem2.wait()
    expect("codex re-ingest matches first pass", replay.value, box.value.tokens)
}

/// Verifies the Codex reader recovers its per-file model state across a
/// daemon restart. Without the back-scan during `loadAndApplyPersistedState`,
/// an event landing after the persisted offset but on a session that
/// declared a non-default model in an earlier turn_context would mis-price
/// as `gpt-5-codex`.
func runCodexModelBackfillTest() {
    print("=== CodexUsageReader.modelBackfill ===")
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory.appendingPathComponent(
        "sissy-codex-backfill-\(UUID().uuidString)"
    )
    try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempDir) }
    let subdir = tempDir.appendingPathComponent("2026/05/25", isDirectory: true)
    try? fm.createDirectory(at: subdir, withIntermediateDirectories: true)
    let jsonl = subdir.appendingPathComponent("rollout-backfill.jsonl")
    let snapshot = tempDir.appendingPathComponent("usage-state.json")

    let isoFmt = ISO8601DateFormatter()
    isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let ts = isoFmt.string(from: Date())

    // Session declares model = o3 (different pricing from the default).
    let initial = """
        {"type":"session_meta","timestamp":"\(ts)","payload":{"id":"bf","model_provider":"openai"}}
        {"type":"turn_context","timestamp":"\(ts)","payload":{"turn_id":"t1","model":"o3"}}
        {"type":"event_msg","timestamp":"\(ts)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":2000,"cached_input_tokens":0,"output_tokens":1000,"reasoning_output_tokens":0,"total_tokens":3000},"total_token_usage":{"input_tokens":2000,"cached_input_tokens":0,"output_tokens":1000,"reasoning_output_tokens":0,"total_tokens":3000}}}}
        """ + "\n"
    try? initial.write(to: jsonl, atomically: true, encoding: .utf8)

    let sem1 = DispatchSemaphore(value: 0)
    Task {
        let r = CodexUsageReader(
            codexDir: tempDir, retainDays: 2, pollInterval: .seconds(60),
            persistenceURL: snapshot)
        await r.start { _, _ in }
        await r.stop()
        sem1.signal()
    }
    sem1.wait()

    // Append a token_count WITHOUT another turn_context. The reader's
    // restored offset will resume past the original turn_context; without
    // backfill the new event falls back to `gpt-5-codex` pricing.
    let append = """
        {"type":"event_msg","timestamp":"\(ts)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":4000,"cached_input_tokens":0,"output_tokens":2000,"reasoning_output_tokens":0,"total_tokens":6000},"total_token_usage":{"input_tokens":6000,"cached_input_tokens":0,"output_tokens":3000,"reasoning_output_tokens":0,"total_tokens":9000}}}}
        """ + "\n"
    if let fh = try? FileHandle(forWritingTo: jsonl) {
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: Data(append.utf8))
        try? fh.close()
    }

    // Uses `o3` rates ($2 input, $8 output) on purpose: they're distinct
    // from `gpt-5-codex` ($1.25 / $10), so a backfill regression that
    // silently fell back to the default model would change observedCost
    // and trip this assertion.
    let sem2 = DispatchSemaphore(value: 0)
    let observed = TestBox<Decimal>(0)
    Task {
        let r = CodexUsageReader(
            codexDir: tempDir, retainDays: 2, pollInterval: .seconds(60),
            persistenceURL: snapshot)
        await r.start { _, _ in }
        let (today, _) = await r.current()
        observed.value = today.totalCost
        await r.stop()
        sem2.signal()
    }
    sem2.wait()

    // Event 1 (o3, fresh fileModels): 2000 in × $2 + 1000 out × $8 / 1M = 0.012
    // Event 2 (o3, via snapshot backfill): 4000 × $2 + 2000 × $8 / 1M = 0.024
    // Sum: 0.036. Under the regression (fileModels lost → defaultModel
    // = gpt-5-codex at $1.25/$10), event 2 would price as 0.025 and the
    // sum would be 0.037, tripping this expect().
    let expected =
        OpenAIPricing.cost(model: "o3", input: 2000, output: 1000, cacheRead: 0)
        + OpenAIPricing.cost(model: "o3", input: 4000, output: 2000, cacheRead: 0)
    expect("codex model backfill", observed.value, expected)
}
