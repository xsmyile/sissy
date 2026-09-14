import XCTest

@testable import Sissy

/// The hook script, run as the CLIs run it, against repositories git actually
/// made. Its whole job is to reproduce what `ProjectResolver` would have
/// answered, from a process that starts and ends before Sissy ever sees the
/// directory — so a stubbed git would test nothing.
final class SessionHookScriptTests: XCTestCase {
    private var root: URL!
    private var hooks: URL!
    private var inbox: URL!
    private var script: URL!

    override func setUpWithError() throws {
        script = try XCTUnwrap(
            Bundle.main.url(forResource: "session-start", withExtension: "sh"),
            "the hook script has to ship inside the app bundle")
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Physical, the way `pwd -P` and git both answer: the temporary
        // directory sits under /var, which is a symlink, and Foundation's own
        // standardisation does not reliably resolve it.
        root = URL(fileURLWithPath: Self.physicalPath(of: base))
        hooks = root.appendingPathComponent("state/hooks")
        inbox = ProjectLedger.inboxURL(in: root.appendingPathComponent("state"))
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: script, to: hooks.appendingPathComponent("session-start.sh"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testARepositoryAnswersItself() throws {
        let repository = try makeRepository("sissy")

        try run(in: repository.path)

        XCTAssertEqual(recorded(), [ProjectCheckout(directory: repository.path, project: repository.path)])
    }

    /// The case the whole feature exists for: the money belongs to the checkout
    /// the worktree was cut from, not to the worktree.
    func testAWorktreeAnswersTheCheckoutItWasCutFrom() throws {
        let repository = try makeRepository("sissy")
        let worktree = try makeWorktree("grampus", of: repository)

        try run(in: worktree.path)

        XCTAssertEqual(recorded(), [ProjectCheckout(directory: worktree.path, project: repository.path)])
    }

    /// A session starts wherever the user was, which is rarely the root. The
    /// pair has to name the checkout either way, or the ledger's deepest-match
    /// lookup answers for a subdirectory instead of the checkout.
    func testASubdirectoryAnswersForItsCheckout() throws {
        let repository = try makeRepository("sissy")
        let worktree = try makeWorktree("grampus", of: repository)
        let nested = worktree.appendingPathComponent("app/SissyCore")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        try run(in: nested.path)

        XCTAssertEqual(recorded(), [ProjectCheckout(directory: worktree.path, project: repository.path)])
    }

    /// The pair outlives the directory it describes. Everything else is detail.
    func testThePairSurvivesTheWorktreeItNames() throws {
        let repository = try makeRepository("sissy")
        let worktree = try makeWorktree("grampus", of: repository)
        try run(in: worktree.path)

        try FileManager.default.removeItem(at: worktree)

        let ledger = ProjectLedger(
            url: ProjectLedger.defaultURL(in: root.appendingPathComponent("state")))
        ledger.ingestInbox()
        XCTAssertEqual(ledger.project(under: worktree.path), repository.path)
    }

    func testADirectoryThatIsNoRepositoryIsNotRecorded() throws {
        let plain = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        try run(in: plain.path)

        XCTAssertEqual(recorded(), [])
    }

    /// `core.worktree` lets a repository name any path on the machine as its
    /// own checkout. A walk cannot be lied to that way — it only ever lands on
    /// an ancestor of where it started — so neither may this.
    func testARepositoryClaimingAnUnrelatedWorktreeIsRefused() throws {
        let repository = try makeRepository("hostile")
        git(["config", "core.worktree", "/Users/somebody/Clients/Confidential"], in: repository)

        try run(in: repository.path)

        XCTAssertEqual(recorded(), [])
    }

    /// Measured before this guard existed: an inherited `GIT_DIR` beats `-C`
    /// and the script recorded a repository the session was never in.
    func testAnInheritedGitDirDoesNotDecideTheAnswer() throws {
        let repository = try makeRepository("sissy")
        let other = try makeRepository("elsewhere")

        try run(
            in: repository.path,
            environment: [
                "GIT_DIR": other.appendingPathComponent(".git").path,
                "GIT_WORK_TREE": other.path,
            ])

        XCTAssertEqual(recorded(), [ProjectCheckout(directory: repository.path, project: repository.path)])
    }

    /// Sissy's data being gone is what makes the script inert. It must not put
    /// the directory back.
    func testNothingIsWrittenWithoutAnInbox() throws {
        let repository = try makeRepository("sissy")
        try FileManager.default.removeItem(at: inbox)

        XCTAssertEqual(try run(in: repository.path).status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.path))
    }

    /// A SessionStart hook's stdout is injected into the agent's context and a
    /// non-zero exit is shown to the user as a hook error.
    func testTheScriptIsSilentAndAlwaysSucceeds() throws {
        let repository = try makeRepository("sissy")

        let quiet = try run(in: repository.path)
        let noRepository = try run(in: "/")
        let missing = try run(in: root.appendingPathComponent("never").path)

        for outcome in [quiet, noRepository, missing] {
            XCTAssertEqual(outcome.status, 0)
            XCTAssertTrue(outcome.output.isEmpty)
        }
    }

    /// The payload is the only thing the script is told, and `cwd` is the only
    /// field it reads. A working directory it cannot decode has to fall back to
    /// the process's own rather than guess at a half-decoded path.
    func testAnUndecodableWorkingDirectoryIsNotGuessedAt() throws {
        let repository = try makeRepository("sissy")

        try run(payload: #"{"cwd":"/Users/davide\/dev/sissy"}"#, from: repository.path)

        XCTAssertEqual(recorded(), [ProjectCheckout(directory: repository.path, project: repository.path)])
    }

    private func recorded() -> [ProjectCheckout] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: inbox, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return
            entries
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .compactMap(ProjectLedger.checkout(from:))
            .sorted { $0.directory < $1.directory }
    }

    @discardableResult
    private func run(
        in directory: String, environment: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        try run(
            payload: #"{"session_id":"s","cwd":"\#(directory)","hook_event_name":"SessionStart"}"#,
            from: directory, environment: environment)
    }

    /// The hook is launched from a directory that exists, because that is what
    /// a CLI does — a working directory that has gone is something the payload
    /// says, not somewhere a process can be started. Launch failures are
    /// thrown rather than swallowed: a `Process` that never ran leaves the
    /// pipe's write end open in this process, and reading it to EOF then waits
    /// forever.
    @discardableResult
    private func run(
        payload: String, from directory: String, environment: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [hooks.appendingPathComponent("session-start.sh").path]
        process.currentDirectoryURL = URL(
            fileURLWithPath: FileManager.default.fileExists(atPath: directory)
                ? directory
                : root.path)
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in
            new
        }
        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(payload.utf8))
        try? input.fileHandleForWriting.close()
        let captured = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: captured, as: UTF8.self))
    }

    /// Foundation's own standardisation is not used anywhere in here: it strips
    /// a `/private` prefix only when the path still exists, so a worktree that
    /// has just been deleted would normalise differently from the same path a
    /// moment earlier. `root` is physical already, so nothing needs to.
    private static func physicalPath(of url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func makeRepository(_ name: String) throws -> URL {
        let repository = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        git(["init", "--quiet", "."], in: repository)
        git(
            [
                "-c", "user.email=t@example.invalid", "-c", "user.name=t", "commit", "--quiet",
                "--allow-empty", "-m", "init",
            ], in: repository)
        return repository
    }

    private func makeWorktree(_ name: String, of repository: URL) throws -> URL {
        let worktree = root.appendingPathComponent(name)
        git(["worktree", "add", "--quiet", "--detach", worktree.path], in: repository)
        return worktree
    }

    private func git(_ arguments: [String], in directory: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}
