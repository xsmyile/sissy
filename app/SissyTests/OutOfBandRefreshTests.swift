import XCTest

@testable import Sissy

/// What the tail re-reads besides the log, and when.
///
/// The files an adapter reads out of band — the plan, the account, the credits
/// — go stale on their own clock, with no line in any JSONL to announce it.
/// The wake that notices has to be the one a turn actually raises: FSEvents is
/// the primary path and the poll is a safety net that runs once a minute, so a
/// re-read hung off the poll alone is a frame carrying this turn's tokens next
/// to the previous minute's plan.
final class OutOfBandRefreshTests: XCTestCase {
    private var logDir: URL!
    private var stateDir: URL!
    private var profileURL: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-out-of-band-\(UUID().uuidString)")
        logDir = base.appendingPathComponent("logs")
        stateDir = base.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        profileURL = base.appendingPathComponent("claude.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: logDir.deletingLastPathComponent())
    }

    /// A turn arrives on FSEvents, and the CLI's config file has named a plan
    /// since the tail last looked. The frame that turn produces has to carry
    /// it.
    ///
    /// The config file is deliberately absent at boot, which is what a fresh
    /// install looks like and also what makes the assertion land inside a test
    /// rather than sixty seconds after one: the adapter's re-read floor
    /// applies only once it has parsed the file at least once, so a source
    /// that has never had an answer is free to take the first one that shows
    /// up.
    func testATurnArrivingOnFSEventsRereadsTheFilesTheAdapterKeepsOutsideTheLog() async throws {
        let emits = EmitRecorder()
        let provider = LocalUsageProvider.claudeCode(
            claudeDir: logDir,
            retainDays: 2,
            pollInterval: .seconds(60),
            persistenceURL: UsageStatePersistence.defaultURL(in: stateDir),
            historyRoot: nil,
            profile: ClaudeProfileSource(url: profileURL)
        )
        await provider.start { _ in emits.record() }
        defer { Task { await provider.stop() } }

        XCTAssertNil(
            provider.currentSignals().plan,
            "the tail named a plan before anything had written one")

        try Data(#"{"oauthAccount":{"organizationType":"claude_pro"}}"#.utf8)
            .write(to: profileURL)

        let arrival = emits.expectation(forCount: emits.count + 1)
        try placeTurnFromAnotherProcess("a.jsonl")
        await fulfillment(of: [arrival], timeout: 10)

        XCTAssertEqual(
            provider.currentSignals().plan, "pro",
            "the frame the turn produced still carried the plan from before it")
    }

    /// Places a turn in the watched tree from a child process.
    ///
    /// The tail arms its FSEvents stream with `IgnoreSelf`, so a file this
    /// process writes itself raises no event at all and the watcher path — the
    /// one under test — stays unreachable.
    private func placeTurnFromAnotherProcess(_ name: String) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let line = """
            {"type":"assistant","timestamp":"\(iso.string(from: Date()))",\
            "requestId":"r1","message":{"model":"claude-sonnet-4-6",\
            "usage":{"input_tokens":1000,"output_tokens":0,\
            "cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
            """
        let staging = logDir.deletingLastPathComponent().appendingPathComponent("staging-\(name)")
        try (line + "\n").write(to: staging, atomically: true, encoding: .utf8)
        let copy = Process()
        copy.executableURL = URL(fileURLWithPath: "/bin/cp")
        copy.arguments = [staging.path, logDir.appendingPathComponent(name).path]
        try copy.run()
        copy.waitUntilExit()
        XCTAssertEqual(copy.terminationStatus, 0, "the turn was never placed")
    }
}

/// Counts the tail's emits and lets a test wait for the next one.
private final class EmitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var emitted = 0
    private var pending: [(count: Int, expectation: XCTestExpectation)] = []

    func record() {
        lock.lock()
        emitted += 1
        let ready = pending.filter { $0.count <= emitted }
        pending.removeAll { $0.count <= emitted }
        lock.unlock()
        ready.forEach { $0.expectation.fulfill() }
    }

    func expectation(forCount count: Int) -> XCTestExpectation {
        let waiting = XCTestExpectation(description: "emit \(count)")
        lock.lock()
        if emitted >= count {
            lock.unlock()
            waiting.fulfill()
            return waiting
        }
        pending.append((count, waiting))
        lock.unlock()
        return waiting
    }

    var count: Int { lock.withLock { emitted } }
}
