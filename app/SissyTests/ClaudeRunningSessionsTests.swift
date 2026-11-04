import XCTest

@testable import Sissy

/// `CLAUDE_CONFIG_DIR` out of `KERN_PROCARGS2` bytes, which are foreign input.
final class ProcessEnvironmentTests: XCTestCase {
    private static let name = AccountDefaults.claudeConfigDirEnvVar

    private func bytes(
        argc: Int32? = nil, executable: String = "/usr/bin/claude", padding: Int = 3,
        arguments: [String] = ["claude"], environment: [String] = [], trailer: [String] = []
    ) -> [UInt8] {
        var out = withUnsafeBytes(of: argc ?? Int32(arguments.count)) { Array($0) }
        out += Array(executable.utf8) + [0] + [UInt8](repeating: 0, count: padding)
        for entry in arguments + environment { out += Array(entry.utf8) + [0] }
        out.append(0)
        for entry in trailer { out += Array(entry.utf8) + [0] }
        return out
    }

    private func lookup(_ bytes: [UInt8]) -> ProcessEnvironment.Lookup {
        ProcessEnvironment.lookup(Self.name, in: bytes)
    }

    func testTheVariableIsFoundAmongTheOthers() {
        let found = lookup(
            bytes(environment: ["PATH=/bin", "\(Self.name)=/tmp/work", "HOME=/Users/a"]))
        XCTAssertEqual(found, .value("/tmp/work"))
    }

    func testAProcessWithoutItAnswersAbsent() {
        XCTAssertEqual(lookup(bytes(environment: ["PATH=/bin"])), .absent)
    }

    func testAnEmptyValueIsNoValue() {
        XCTAssertEqual(lookup(bytes(environment: ["\(Self.name)="])), .absent)
    }

    /// A prompt on the command line can spell anything, and is not the
    /// environment.
    func testAnArgumentSpellingTheVariableIsNotIt() {
        let found = lookup(
            bytes(arguments: ["claude", "\(Self.name)=/tmp/argument"], environment: ["PATH=/bin"]))
        XCTAssertEqual(found, .absent)
    }

    func testALongerNameSharingThePrefixIsNotIt() {
        XCTAssertEqual(lookup(bytes(environment: ["\(Self.name)_OLD=/tmp/x"])), .absent)
    }

    func testTheFirstEntryWinsAsGetenvReadsIt() {
        let found = lookup(
            bytes(environment: ["\(Self.name)=/tmp/first", "\(Self.name)=/tmp/second"]))
        XCTAssertEqual(found, .value("/tmp/first"))
    }

    /// The kernel's own strings follow the empty entry that ends the environment.
    func testWhatFollowsTheEnvironmentIsNotRead() {
        let found = lookup(bytes(environment: ["PATH=/bin"], trailer: ["\(Self.name)=/tmp/apple"]))
        XCTAssertEqual(found, .absent)
    }

    func testAProcessWithNoArgumentsStillReads() {
        let found = lookup(bytes(arguments: [], environment: ["\(Self.name)=/tmp/work"]))
        XCTAssertEqual(found, .value("/tmp/work"))
    }

    func testBytesEndingAfterTheArgumentsAreUnreadable() {
        var raw = withUnsafeBytes(of: Int32(1)) { Array($0) }
        raw += Array("/bin/x".utf8) + [0, 0, 0] + Array("/bin/x".utf8) + [0]
        XCTAssertEqual(lookup(raw), .unreadable)
    }

    func testAnEmptyEnvironmentIsAbsent() {
        XCTAssertEqual(lookup(bytes(environment: [])), .absent)
    }

    func testTooFewBytesAreUnreadable() {
        XCTAssertEqual(lookup([]), .unreadable)
        XCTAssertEqual(lookup([1, 0, 0, 0]), .unreadable)
    }

    func testAnExecutablePathThatNeverEndsIsUnreadable() {
        XCTAssertEqual(lookup([1, 0, 0, 0] + Array("/usr/bin/claude".utf8)), .unreadable)
    }

    func testANegativeCountIsUnreadable() {
        XCTAssertEqual(lookup(bytes(argc: -1)), .unreadable)
    }

    func testACountBeyondTheBufferIsUnreadable() {
        XCTAssertEqual(lookup(bytes(argc: Int32.max)), .unreadable)
    }

    func testAnEnvironmentCutOffMidEntryIsUnreadable() {
        let cut = bytes(environment: ["\(Self.name)=/tmp/work"]).dropLast(3)
        XCTAssertEqual(lookup(Array(cut)), .unreadable)
    }

    func testAValueLongerThanAPathIsUnreadable() {
        let long = String(repeating: "a", count: ProcessEnvironment.maximumValueBytes + 1)
        XCTAssertEqual(lookup(bytes(environment: ["\(Self.name)=\(long)"])), .unreadable)
    }

    func testAValueThatIsNotUTF8IsUnreadable() {
        var raw = withUnsafeBytes(of: Int32(0)) { Array($0) }
        raw += Array("/bin/x".utf8) + [0]
        raw += Array("\(Self.name)=".utf8) + [0xFF, 0xFE, 0, 0]
        XCTAssertEqual(lookup(raw), .unreadable)
    }

    /// The kernel's real answer for a real child, read by pid.
    func testARealChildsVariableIsReadByPid() throws {
        let child = try spawn(environment: [Self.name: "/tmp/sissy-real-child", "OTHER": "x"])
        defer { child.terminate() }
        var buffer: [UInt8] = []
        let found = AgentProcessReader.claudeConfigDir(of: child.processIdentifier, buffer: &buffer)
        XCTAssertEqual(found, .value("/tmp/sissy-real-child"))
    }

    func testARealChildWithoutItAnswersAbsent() throws {
        let child = try spawn(environment: ["OTHER": "x"])
        defer { child.terminate() }
        var buffer: [UInt8] = []
        XCTAssertEqual(
            AgentProcessReader.claudeConfigDir(of: child.processIdentifier, buffer: &buffer), .absent)
    }

    func testAProcessThatHasExitedIsUnreadable() throws {
        let child = try spawn(environment: [:])
        let pid = child.processIdentifier
        child.terminate()
        child.waitUntilExit()
        var buffer: [UInt8] = []
        XCTAssertEqual(AgentProcessReader.claudeConfigDir(of: pid, buffer: &buffer), .unreadable)
    }

    /// A child of its own compiling, because the kernel can withhold the
    /// environment of a platform binary like `/bin/sleep`.
    private static let childExecutable = Result { () throws -> URL in
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("procargs-child-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("child.c")
        try Data("#include <unistd.h>\nint main(void) { pause(); return 0; }\n".utf8).write(to: source)
        let binary = directory.appendingPathComponent("child")
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compile.arguments = ["-o", binary.path, source.path]
        try compile.run()
        compile.waitUntilExit()
        XCTAssertEqual(compile.terminationStatus, 0)
        return binary
    }

    private func spawn(environment: [String: String]) throws -> Process {
        let process = Process()
        process.executableURL = try Self.childExecutable.get()
        process.environment = environment
        try process.run()
        return process
    }

    /// `/bin/sleep` with the variable set. Whether the kernel hands over a
    /// platform binary's environment depends on the Mac, so either answer can
    /// come back, but a withheld one must never read as a process without the
    /// variable: that would count it on the default home.
    func testAPlatformBinarysEnvironmentIsNeverReadAsAbsent() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.environment = [Self.name: "/tmp/withheld"]
        try process.run()
        defer { process.terminate() }
        var buffer: [UInt8] = []
        XCTAssertNotEqual(
            AgentProcessReader.claudeConfigDir(of: process.processIdentifier, buffer: &buffer),
            .absent)
    }
}

/// Which home a value names, and which file answers for it.
final class ClaudeProcessHomeTests: XCTestCase {
    private let userHome = URL(fileURLWithPath: "/Users/someone")

    private func home(_ lookup: ProcessEnvironment.Lookup) -> ClaudeProcessHome? {
        ClaudeProcessHome(variable: lookup, userHome: userHome)
    }

    func testNoVariableIsTheDefaultHome() {
        XCTAssertEqual(home(.absent), .standard)
    }

    func testAnUnreadableEnvironmentIsNoHome() {
        XCTAssertNil(home(.unreadable))
    }

    func testARelativePathIsNoHome() {
        XCTAssertNil(home(.value("relative/dir")))
    }

    func testAPathIsThatHomeWhateverItsTrailingSlash() {
        XCTAssertEqual(home(.value("/tmp/work/")), .named("/tmp/work"))
    }

    func testNamingTheDefaultDirectoryIsTheDefaultHome() {
        XCTAssertEqual(home(.value("/Users/someone/.claude")), .standard)
    }

    func testTheDefaultHomesFileSitsBesideItsDirectory() {
        XCTAssertEqual(
            ClaudeProcessHome.standard.configFile(userHome: userHome).path,
            "/Users/someone/.claude.json")
    }

    func testANamedHomesFileSitsInsideIt() {
        XCTAssertEqual(
            ClaudeProcessHome.named("/tmp/sissy-no-such-home").configFile(userHome: userHome).path,
            "/tmp/sissy-no-such-home/.claude.json")
    }

    func testAMigratedHomesFileWins() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let migrated = directory.appendingPathComponent(".config.json")
        try Data("{}".utf8).write(to: migrated)
        XCTAssertEqual(
            ClaudeProcessHome.named(directory.path).configFile(userHome: userHome).lastPathComponent,
            migrated.lastPathComponent)
    }
}

/// Counting sessions per account, over real files in a scratch home.
final class ClaudeRunningSessionsTests: XCTestCase {
    private var root: URL!
    private var running: ClaudeRunningSessions!

    private static let accountA = "aaaaaaaa-0000-0000-0000-000000000000"
    private static let accountB = "bbbbbbbb-0000-0000-0000-000000000000"
    private static let fetchedAtMs = 1_790_000_000_000.0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("running-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        running = ClaudeRunningSessions(userHome: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func agents(_ homes: [ClaudeProcessHome?]) -> [AgentProcess] {
        homes.enumerated().map { index, home in
            AgentProcess(
                pid: pid_t(1000 + index), provider: ProviderID.claudeCode, footprint: 0,
                treeFootprint: 0, startedAt: Date(timeIntervalSince1970: 0), version: nil,
                directory: nil, claudeHome: home)
        }
    }

    private func config(
        owner: String?, plan: String = "claude_team", stamp: String? = nil,
        percent: Double = 42, fetchedAtMs: Double = fetchedAtMs
    ) -> [String: Any] {
        var root: [String: Any] = [:]
        if let owner {
            root["oauthAccount"] = [
                "accountUuid": owner, "emailAddress": "someone@example.com",
                "organizationType": plan, "displayName": "Some One",
            ]
        }
        if let stamp {
            root["cachedUsageUtilization"] = [
                "accountUuid": stamp,
                "fetchedAtMs": fetchedAtMs,
                "utilization": ["five_hour": ["utilization": percent]],
            ]
        }
        return root
    }

    private func named(_ name: String, _ body: [String: Any]) throws -> ClaudeProcessHome {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: body)
            .write(to: directory.appendingPathComponent(".claude.json"))
        return .named(directory.path)
    }

    func testTwoHomesOnOneAccountSum() throws {
        let first = try named("first", config(owner: Self.accountA))
        let second = try named("second", config(owner: Self.accountA))

        running.update(agents([first, first, first, second, second]))

        XCTAssertEqual(running.current().accounts[Self.accountA]?.sessions, 5)
        XCTAssertEqual(running.current().accounts.count, 1)
    }

    func testTwoHomesOnTwoAccountsCountApart() throws {
        let first = try named("first", config(owner: Self.accountA))
        let second = try named("second", config(owner: Self.accountB))

        running.update(agents([first, second, second]))

        XCTAssertEqual(running.current().accounts[Self.accountA]?.sessions, 1)
        XCTAssertEqual(running.current().accounts[Self.accountB]?.sessions, 2)
    }

    func testADefaultHomeProcessReadsTheFileBesideItsDirectory() throws {
        try JSONSerialization.data(withJSONObject: config(owner: Self.accountA))
            .write(to: root.appendingPathComponent(".claude.json"))

        running.update(agents([.standard, .standard]))

        XCTAssertEqual(running.current().accounts[Self.accountA]?.sessions, 2)
        XCTAssertEqual(running.current().homes, [.standard])
    }

    func testAHomeWhoseFileNamesNobodyAddsNoOne() throws {
        let nobody = try named("nobody", config(owner: nil))

        running.update(agents([nobody]))

        XCTAssertTrue(running.current().accounts.isEmpty)
        XCTAssertEqual(running.current().homes, [nobody])
    }

    func testAHomeWithNoFileAddsNoOne() {
        running.update(agents([.named(root.appendingPathComponent("missing").path)]))
        XCTAssertTrue(running.current().accounts.isEmpty)
    }

    /// A plan Sissy cannot word does not take the session off its account.
    func testAnUnwordablePlanStillCounts() throws {
        let home = try named("odd", config(owner: Self.accountA, plan: "claude_max 5x"))

        running.update(agents([home]))

        XCTAssertEqual(running.current().accounts[Self.accountA]?.sessions, 1)
        XCTAssertNil(running.current().accounts[Self.accountA]?.plan)
    }

    func testAProcessWithNoReadableHomeIsNotCounted() throws {
        let home = try named("first", config(owner: Self.accountA))

        running.update(agents([home, nil]))

        XCTAssertEqual(running.current().accounts[Self.accountA]?.sessions, 1)
    }

    func testTheRowIsNamedFromTheFile() throws {
        let home = try named("first", config(owner: Self.accountA))

        running.update(agents([home]))

        let found = try XCTUnwrap(running.current().accounts[Self.accountA])
        XCTAssertEqual(found.account?.name, "Some One")
        XCTAssertEqual(found.plan, "team")
    }

    func testAStampedReplyGivesGaugesDatedByTheVendor() throws {
        let home = try named("first", config(owner: Self.accountA, stamp: Self.accountA))

        running.update(agents([home]))

        let found = try XCTUnwrap(running.current().accounts[Self.accountA])
        XCTAssertEqual(found.windows.map(\.usedPercent), [42])
        XCTAssertEqual(found.observedAt?.timeIntervalSince1970, Self.fetchedAtMs / 1000)
    }

    func testAReplyStampedForAnotherAccountGivesNothing() throws {
        let home = try named("first", config(owner: Self.accountA, stamp: Self.accountB))

        running.update(agents([home]))

        let found = try XCTUnwrap(running.current().accounts[Self.accountA])
        XCTAssertTrue(found.windows.isEmpty)
        XCTAssertNil(found.observedAt)
    }

    func testAnUnstampedReplyGivesNothing() throws {
        var body = config(owner: Self.accountA, stamp: Self.accountA)
        var cache = try XCTUnwrap(body["cachedUsageUtilization"] as? [String: Any])
        cache.removeValue(forKey: "accountUuid")
        body["cachedUsageUtilization"] = cache
        let home = try named("first", body)

        running.update(agents([home]))

        XCTAssertEqual(running.current().accounts[Self.accountA]?.windows, [])
    }

    func testTheFreshestOfTwoHomesReadingsStands() throws {
        let older = try named(
            "a-older", config(owner: Self.accountA, stamp: Self.accountA, percent: 10, fetchedAtMs: 1_000_000)
        )
        let newer = try named(
            "b-newer", config(owner: Self.accountA, stamp: Self.accountA, percent: 90))
        let stale = try named(
            "c-stale", config(owner: Self.accountA, stamp: Self.accountA, percent: 20, fetchedAtMs: 2_000_000)
        )

        running.update(agents([older, newer, stale]))

        let found = try XCTUnwrap(running.current().accounts[Self.accountA])
        XCTAssertEqual(found.windows.map(\.usedPercent), [90])
        XCTAssertEqual(found.sessions, 3)
    }

    /// The path came from another process, and opening a FIFO would hang.
    func testAConfigThatIsNotARegularFileIsNotOpened() throws {
        let directory = root.appendingPathComponent("fifo", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(directory.appendingPathComponent(".claude.json").path, 0o600), 0)

        running.update(agents([.named(directory.path)]))

        XCTAssertTrue(running.current().accounts.isEmpty)
    }

    func testALinkedConfigIsFollowed() throws {
        let real = root.appendingPathComponent("real.json")
        try JSONSerialization.data(withJSONObject: config(owner: Self.accountA)).write(to: real)
        let directory = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent(".claude.json"), withDestinationURL: real)

        running.update(agents([.named(directory.path)]))

        XCTAssertEqual(running.current().accounts[Self.accountA]?.sessions, 1)
    }

    func testASessionThatExitedLeavesTheCount() throws {
        let home = try named("first", config(owner: Self.accountA))
        running.update(agents([home, home]))

        running.update(agents([]))

        XCTAssertTrue(running.current().accounts.isEmpty)
        XCTAssertTrue(running.current().homes.isEmpty)
    }

    func testTheInertOneCountsNothing() throws {
        let home = try named("first", config(owner: Self.accountA))
        ClaudeRunningSessions.inert.update(agents([home]))
        XCTAssertEqual(ClaudeRunningSessions.inert.current(), ClaudeRunningSessions.Reading())
    }

    func testTheMonitorHandsItsAgentsOver() async throws {
        let home = try named("first", config(owner: Self.accountA))
        let swept = agents([home])
        let monitor = AgentProcessMonitor(
            sweep: { now, _ in
                AgentProcessSweep(agents: AgentProcessReading(observedAt: now, agents: swept), apps: nil)
            },
            runningSessions: running)

        await monitor.sampleOnce {}
        XCTAssertEqual(running.current().accounts[Self.accountA]?.sessions, 1)

        await monitor.stop()
        XCTAssertTrue(running.current().accounts.isEmpty)
    }
}

/// What the counts do to the account rows.
final class ClaudeRunningRowsTests: XCTestCase {
    private func row(_ id: String, signedIn: Bool = false) -> AccountSignals {
        AccountSignals(
            id: id, reading: ProviderSignals(), account: nil, plan: nil, planTier: nil,
            isSignedIn: signedIn)
    }

    private func found(
        _ id: String, sessions: Int, windows: [UsageWindow] = []
    ) -> ClaudeRunningSessions.Account {
        ClaudeRunningSessions.Account(
            id: id, sessions: sessions,
            account: ProviderAccount(email: nil, name: "Named \(id)", organization: nil, seat: nil),
            plan: "team", windows: windows, observedAt: windows.isEmpty ? nil : Date())
    }

    func testAnAccountWithARowTakesTheCountAndKeepsItsReading() {
        let merged = ClaudeCodeSignals.withRunning(
            [row("signed", signedIn: true)], ["signed": found("signed", sessions: 8)])

        XCTAssertEqual(merged.map(\.id), ["signed"])
        XCTAssertEqual(merged[0].runningSessions, 8)
        XCTAssertFalse(merged[0].isOnlyRunning)
        XCTAssertNil(merged[0].account)
    }

    func testAnAccountWithNoRowGetsOneAfterTheSignedInOne() {
        let merged = ClaudeCodeSignals.withRunning(
            [row("zz", signedIn: true)], ["aa": found("aa", sessions: 2)])

        XCTAssertEqual(merged.map(\.id), ["zz", "aa"])
        XCTAssertEqual(merged[1].runningSessions, 2)
        XCTAssertEqual(merged[1].account?.name, "Named aa")
        XCTAssertEqual(merged[1].plan, "team")
        XCTAssertFalse(merged[1].isSignedIn)
        XCTAssertTrue(merged[1].isOnlyRunning)
    }

    func testNothingRunningLeavesTheRowsAsTheyWere() {
        let rows = [row("signed", signedIn: true)]
        XCTAssertEqual(ClaudeCodeSignals.withRunning(rows, [:]), rows)
    }

    func testARowWhoseSessionsEndedDropsItsCount() {
        var counted = row("signed", signedIn: true)
        counted.runningSessions = 3
        let merged = ClaudeCodeSignals.withRunning(
            [counted], ["other": found("other", sessions: 1)])
        XCTAssertEqual(merged.first { $0.id == "signed" }?.runningSessions, 0)
    }

    private func entries(_ readings: [AccountSignals]) -> [UsagePanelSnapshot.AccountEntry] {
        UsagePanelSnapshot.accountEntries(
            readings: readings, known: ClaudeAccountRegistry.Snapshot(),
            provider: ProviderID.claudeCode, reading: .used, now: Date())
    }

    func testAnEntryCarriesItsCount() {
        let rows = ClaudeCodeSignals.withRunning(
            [row("signed", signedIn: true)],
            ["signed": found("signed", sessions: 8), "other": found("other", sessions: 1)])

        XCTAssertEqual(entries(rows).first { $0.id == "signed" }?.runningSessions, 8)
        XCTAssertEqual(entries(rows).first { $0.id == "other" }?.runningSessions, 1)
    }

    /// A row with nothing behind it invites a link rather than claiming a
    /// source, and one with a cached reply shows it.
    func testARunningOnlyRowIsReadableOnlyWithGauges() throws {
        let window = try XCTUnwrap(UsageWindow(minutes: 300, usedPercent: 10, resetsAt: nil))
        let rows = ClaudeCodeSignals.withRunning(
            [row("signed", signedIn: true)],
            [
                "bare": found("bare", sessions: 1),
                "cached": found("cached", sessions: 1, windows: [window]),
            ])

        XCTAssertEqual(entries(rows).first { $0.id == "bare" }?.isReadable, false)
        XCTAssertEqual(entries(rows).first { $0.id == "cached" }?.isReadable, true)
    }

    func testTheMenuLabelSaysInUseOnlyWithSessions() {
        XCTAssertEqual(ClaudeAccountCopy.menuLabel("Acme", sessions: 0), "Acme")
        XCTAssertEqual(ClaudeAccountCopy.menuLabel("Acme", sessions: 1), "Acme · in use · 1 session")
        XCTAssertEqual(ClaudeAccountCopy.menuLabel("Acme", sessions: 8), "Acme · in use · 8 sessions")
    }

    func testTheCaptionIsAbsentWithoutSessions() {
        XCTAssertNil(ClaudeAccountCopy.inUseCaption(sessions: 0))
        XCTAssertEqual(ClaudeAccountCopy.inUseCaption(sessions: 1), "In use · 1 session")
        XCTAssertEqual(ClaudeAccountCopy.inUseCaption(sessions: 3), "In use · 3 sessions")
    }

    // MARK: The row itself

    private func window(percent: Double = 61) throws -> UsageWindow {
        try XCTUnwrap(
            UsageWindow(
                minutes: 300, usedPercent: percent, resetsAt: Date().addingTimeInterval(7200)))
    }

    private func runningOnly(
        _ id: String = "sole", sessions: Int = 2, windows: [UsageWindow] = [], credits: ProviderCredits? = nil
    ) -> AccountSignals {
        AccountSignals(
            id: id,
            account: ProviderAccount(email: "\(id)@example.com", name: "Named \(id)"),
            plan: "team", planTier: nil, windows: windows, credits: credits,
            limitsObservedAt: windows.isEmpty ? nil : Date().addingTimeInterval(-3600),
            runningSessions: sessions, isOnlyRunning: true)
    }

    private func snapshot(
        signals: ProviderSignals, known: ClaudeAccountRegistry.Snapshot = .init()
    ) -> UsagePanelSnapshot {
        let slice = ProviderSlice(id: ProviderID.claudeCode, tokens: 0, cost: 0, signals: signals)
        return UsagePanelSnapshot.make(
            frame: FrameData(
                tokens: 0, cost: 0, burn: nil, providers: [slice], keepAwake: .off, history: [:],
                projects: []),
            claudeAccounts: known)
    }

    private func signals(_ accounts: [AccountSignals]) -> ProviderSignals {
        var signals = ProviderSignals()
        signals.accounts = accounts
        return signals
    }

    /// A user running Claude Code only under `CLAUDE_CONFIG_DIR`: the metered
    /// home names nobody, so everything the row shows is that one account's.
    func testASoleRunningAccountReachesTheRow() throws {
        let made = snapshot(signals: signals([runningOnly(windows: [try window()])]))
        let row = made.providers[0]

        XCTAssertTrue(row.accounts.isEmpty)
        XCTAssertEqual(row.account?.name, "Named sole")
        XCTAssertNotNil(row.plan)
        XCTAssertEqual(row.windows.map(\.percent), [61])
        XCTAssertNotNil(row.windowsCaption)
        XCTAssertEqual(row.runningSessions, 2)
        XCTAssertEqual(ClaudeAccountCopy.inUseCaption(sessions: row.runningSessions), "In use · 2 sessions")
        XCTAssertEqual(made.gaugeRows.first?.windows.map(\.percent), [61])
    }

    /// With nothing cached it still has its name and count, and whatever the
    /// metered home has to say about limits still stands.
    func testASoleRunningAccountWithNoGaugesKeepsItsNameAndTheNotice() {
        var reading = signals([runningOnly()])
        reading.limitsState = .signedOut

        let row = snapshot(signals: reading).providers[0]

        XCTAssertEqual(row.account?.name, "Named sole")
        XCTAssertEqual(row.runningSessions, 2)
        XCTAssertTrue(row.windows.isEmpty)
        XCTAssertNil(row.windowsCaption)
        XCTAssertNotNil(row.notice)
    }

    /// Gauges under `No stored Claude login` would contradict each other, and
    /// that sentence is about the metered home.
    func testASoleRunningAccountsGaugesReplaceTheMeteredHomesNotice() throws {
        var reading = signals([runningOnly(windows: [try window()])])
        reading.limitsState = .signedOut

        XCTAssertNil(snapshot(signals: reading).providers[0].notice)
    }

    func testAnIndexEntryForTheSameAccountStillReachesTheRow() throws {
        let known = ClaudeAccountRegistry.Snapshot(
            accounts: [
                ClaudeAccountIdentity(
                    uuid: "sole", email: nil, organization: nil, organizationType: nil,
                    rateLimitTier: nil)
            ],
            activeUUID: nil)

        let row = snapshot(signals: signals([runningOnly()]), known: known).providers[0]

        XCTAssertTrue(row.accounts.isEmpty)
        XCTAssertEqual(row.account?.name, "Named sole")
    }

    /// A second known account draws the picker, which reads the entries.
    func testAnotherKnownAccountLeavesTheRowToThePicker() {
        let known = ClaudeAccountRegistry.Snapshot(
            accounts: [
                ClaudeAccountIdentity(
                    uuid: "other", email: nil, organization: nil, organizationType: nil,
                    rateLimitTier: nil)
            ],
            activeUUID: nil)

        let row = snapshot(signals: signals([runningOnly()]), known: known).providers[0]

        XCTAssertEqual(row.accounts.count, 2)
        XCTAssertNil(row.account)
    }

    /// One account the metered home is signed in as reads its own live fields.
    func testASignedInAccountStillReadsTheSlice() throws {
        var reading = signals([
            AccountSignals(
                id: "signed", account: nil, plan: nil, planTier: nil, isSignedIn: true,
                runningSessions: 3)
        ])
        reading.windows = [try window(percent: 20)]
        reading.limitsObservedAt = Date()

        let row = snapshot(signals: reading).providers[0]

        XCTAssertEqual(row.windows.map(\.percent), [20])
        XCTAssertEqual(row.runningSessions, 3)
    }

    // MARK: The pace

    /// The control beside the two below: this window earns a pace off a live
    /// reader, so its absence there is the cached reply's doing.
    func testALiveReadingOfTheSameWindowDrawsAPace() throws {
        var reading = signals([])
        reading.windows = [try window()]
        reading.limitsObservedAt = Date()

        XCTAssertNotNil(snapshot(signals: reading).providers[0].windows.first?.pace)
    }

    func testASoleRunningAccountsGaugesDrawNoPace() throws {
        let row = snapshot(signals: signals([runningOnly(windows: [try window()])])).providers[0]
        let drawn = try XCTUnwrap(row.windows.first)

        XCTAssertNil(drawn.pace)
        XCTAssertEqual(drawn.percent, 61)
        XCTAssertNotNil(drawn.resetsAt)
        XCTAssertNotNil(row.windowsCaption)
    }

    func testARunningOnlyEntrysGaugesDrawNoPaceBesideAPacedOne() throws {
        let signed = AccountSignals(
            id: "signed", reading: ProviderSignals(windows: [try window()], limitsObservedAt: Date()),
            account: nil, plan: nil, planTier: nil, isSignedIn: true)

        let found = entries([signed, runningOnly(windows: [try window()])])

        XCTAssertNotNil(found.first { $0.id == "signed" }?.windows.first?.pace)
        let cached = try XCTUnwrap(found.first { $0.id == "sole" })
        XCTAssertNil(cached.windows.first?.pace)
        XCTAssertEqual(cached.windows.first?.percent, 61)
        XCTAssertNotNil(cached.windowsCaption)
    }
}
