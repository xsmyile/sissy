import XCTest

@testable import Sissy

/// Which project a day's spend is attributed to, driven through real trees and
/// the real adapters. The question this answers is "where did the money go",
/// so the unit under test is the whole path from a `cwd` on a log line to a
/// row in the archive — a stubbed resolver would only restate the resolver's
/// own tests.
final class UsageProjectSplitTests: XCTestCase {
    private var base: URL!
    private var logDir: URL!
    private var codexDir: URL!
    private var stateDir: URL!
    private var repos: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-projects-split-\(UUID().uuidString)")
        logDir = base.appendingPathComponent("logs")
        codexDir = base.appendingPathComponent("codex")
        stateDir = base.appendingPathComponent("state")
        repos = base.appendingPathComponent("repos")
        for dir in [logDir, codexDir, stateDir, repos] {
            try FileManager.default.createDirectory(at: dir!, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private static let model = "claude-opus-5"
    private static let codexModel = "gpt-5-codex"
    private static let tokensPerTurn = 1_000

    func testWorkInOneRepositoryIsOneRowWhateverDirectoryItRanIn() async throws {
        let repo = try makeRepository("legion")
        let nested = repo.appendingPathComponent("frontend")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        try writeTurn("a.jsonl", requestId: "r1", cwd: repo.path)
        try writeTurn("b.jsonl", requestId: "r2", cwd: nested.path)
        try await runClaudeTail()

        let day = try archivedToday(ProviderID.claudeCode)
        XCTAssertEqual(day.models.count, 1, "one repository was split across rows")
        XCTAssertEqual(day.models.first?.project, repo.path)
        XCTAssertEqual(day.models.first?.inputTokens, Self.tokensPerTurn * 2)
    }

    func testAWorktreeCountsAgainstTheCheckoutItWasCutFrom() async throws {
        let main = try makeRepository("sissy")
        let worktree = try makeWorktree("grampus", of: main)

        try writeTurn("a.jsonl", requestId: "r1", cwd: main.path)
        try writeTurn("b.jsonl", requestId: "r2", cwd: worktree.path)
        try await runClaudeTail()

        let day = try archivedToday(ProviderID.claudeCode)
        XCTAssertEqual(
            day.models.map(\.project), [main.path],
            "a worktree and its checkout were billed as two projects")
    }

    func testTwoRepositoriesAreTwoRowsThatAddUpToTheDay() async throws {
        let legion = try makeRepository("legion")
        let vedite = try makeRepository("vedite")

        try writeTurn("a.jsonl", requestId: "r1", cwd: legion.path)
        try writeTurn("b.jsonl", requestId: "r2", cwd: vedite.path)
        try writeTurn("c.jsonl", requestId: "r3", cwd: vedite.path)
        try await runClaudeTail()

        let day = try archivedToday(ProviderID.claudeCode)
        let byProject = Dictionary(
            uniqueKeysWithValues: day.models.map { ($0.project, $0.inputTokens) })
        XCTAssertEqual(byProject[legion.path], Self.tokensPerTurn)
        XCTAssertEqual(byProject[vedite.path], Self.tokensPerTurn * 2)
        XCTAssertEqual(
            day.models.reduce(0) { $0 + $1.inputTokens }, Self.tokensPerTurn * 3,
            "the rows stopped adding up to the day")
    }

    func testALineThatNamesNoDirectoryLandsOnARowWithNoProject() async throws {
        try writeTurn("a.jsonl", requestId: "r1", cwd: nil)
        try await runClaudeTail()

        let day = try archivedToday(ProviderID.claudeCode)
        XCTAssertEqual(day.models.map(\.project), [nil])
    }

    /// A directory in no repository is not a project, so its spend is counted
    /// and left unattributed rather than given a row named after a path.
    func testWorkOutsideAnyRepositoryIsCountedButNotNamed() async throws {
        let loose = base.appendingPathComponent("scratch/one-off")
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        try writeTurn("a.jsonl", requestId: "r1", cwd: loose.path)
        try await runClaudeTail()

        let day = try archivedToday(ProviderID.claudeCode)
        XCTAssertEqual(day.models.map(\.project), [nil], "a scratch directory was named a project")
        XCTAssertEqual(
            day.models.first?.inputTokens, Self.tokensPerTurn,
            "the spend went missing along with its name")
    }

    /// The offsets are at EOF after a restart, so nothing re-reads the lines
    /// that named the directory. Without the split in the snapshot a fresh
    /// process shows a day it has already counted as belonging to nobody.
    func testTheSplitSurvivesARelaunchInTheMiddleOfADay() async throws {
        let repo = try makeRepository("legion")
        try writeTurn("a.jsonl", requestId: "r1", cwd: repo.path)
        try await runClaudeTail()

        try writeTurn("b.jsonl", requestId: "r2", cwd: repo.path)
        try await runClaudeTail()

        let day = try archivedToday(ProviderID.claudeCode)
        XCTAssertEqual(day.models.count, 1, "the relaunch opened a second row for one repository")
        XCTAssertEqual(day.models.first?.project, repo.path)
        XCTAssertEqual(day.models.first?.inputTokens, Self.tokensPerTurn * 2)
    }

    /// Codex names the directory once, on the rollout's first line, which a
    /// resumed reader is already past — the same shape that makes it keep a
    /// per-file model map.
    func testCodexTakesTheProjectFromTheRolloutItStartedIn() async throws {
        let repo = try makeRepository("norace")
        try writeRollout("rollout-a.jsonl", cwd: repo.path, turns: 1)
        try await runCodexTail()

        let day = try archivedToday(ProviderID.codex)
        XCTAssertEqual(day.models.map(\.project), [repo.path])
    }

    /// Codex reaches the resolver down its own path, from the rollout's
    /// `session_meta`, so a scratch directory has to go unnamed there too
    /// rather than only on the Claude Code side.
    func testCodexWorkOutsideAnyRepositoryIsCountedButNotNamed() async throws {
        let loose = base.appendingPathComponent("scratch/one-off")
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        try writeRollout("rollout-a.jsonl", cwd: loose.path, turns: 1)
        try await runCodexTail()

        let day = try archivedToday(ProviderID.codex)
        XCTAssertEqual(day.models.map(\.project), [nil], "a scratch directory was named a project")
        XCTAssertEqual(
            day.models.first?.inputTokens, Self.tokensPerTurn,
            "the spend went missing along with its name")
    }

    func testCodexKeepsTheProjectAcrossARelaunch() async throws {
        let repo = try makeRepository("norace")
        try writeRollout("rollout-a.jsonl", cwd: repo.path, turns: 1)
        try await runCodexTail()

        try appendTurn(to: "rollout-a.jsonl")
        try await runCodexTail()

        let day = try archivedToday(ProviderID.codex)
        XCTAssertEqual(day.models.count, 1, "the relaunch lost the rollout's directory")
        XCTAssertEqual(day.models.first?.project, repo.path)
    }

    /// `historyRetentionDays: 0` switches the archive off, which is a promise
    /// about what Sissy writes to disk. The panel's split is read live, and a
    /// disk-retention setting must not quietly take it away as well.
    func testTheSplitIsStillReadableWithTheArchiveSwitchedOff() async throws {
        let legion = try makeRepository("legion")
        let vedite = try makeRepository("vedite")
        try writeTurn("a.jsonl", requestId: "r1", cwd: legion.path)
        try writeTurn("b.jsonl", requestId: "r2", cwd: vedite.path)

        let provider = LocalUsageProvider.claudeCode(
            claudeDir: logDir,
            retainDays: 2,
            pollInterval: .seconds(60),
            persistenceURL: UsageStatePersistence.defaultURL(in: stateDir),
            historyRoot: nil
        )
        await provider.start { _, _ in }
        let split = provider.currentProjects()
        await provider.stop()

        XCTAssertEqual(
            Set(split.map(\.path)), [legion.path, vedite.path],
            "switching the archive off blanked the live split too")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: UsageHistoryStore.directory(in: stateDir).path),
            "the archive wrote a file after being switched off")
    }

    private func runClaudeTail() async throws {
        let provider = LocalUsageProvider.claudeCode(
            claudeDir: logDir,
            retainDays: 2,
            pollInterval: .seconds(60),
            persistenceURL: UsageStatePersistence.defaultURL(in: stateDir),
            historyRoot: stateDir
        )
        await provider.start { _, _ in }
        await provider.stop()
    }

    private func runCodexTail() async throws {
        let provider = LocalUsageProvider.codex(
            codexDir: codexDir,
            retainDays: 2,
            pollInterval: .seconds(60),
            persistenceURL: UsageStatePersistence.forProvider(ProviderID.codex, in: stateDir),
            historyRoot: stateDir
        )
        await provider.start { _, _ in }
        await provider.stop()
    }

    private func archivedToday(_ provider: String) throws -> UsageHistoryDay {
        let day = UsageReaderShared.dayFormatter.string(from: Date())
        return try XCTUnwrap(
            UsageHistoryStore.load(provider: provider, day: day, in: stateDir),
            "the tail archived nothing for today")
    }

    private func writeTurn(_ name: String, requestId: String, cwd: String?) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let cwdField = cwd.map { "\"cwd\":\"\($0)\"," } ?? ""
        let line = """
            {"type":"assistant","timestamp":"\(iso.string(from: Date()))",\
            \(cwdField)"requestId":"\(requestId)",\
            "message":{"id":"m-\(requestId)","model":"\(Self.model)",\
            "usage":{"input_tokens":\(Self.tokensPerTurn),"output_tokens":0,\
            "cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
            """
        try (line + "\n").write(
            to: logDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func writeRollout(_ name: String, cwd: String, turns: Int) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let stamp = iso.string(from: Date())
        var lines = [
            """
            {"type":"session_meta","timestamp":"\(stamp)",\
            "payload":{"id":"s","cwd":"\(cwd)","model_provider":"openai"}}
            """,
            """
            {"type":"turn_context","timestamp":"\(stamp)",\
            "payload":{"turn_id":"t","model":"\(Self.codexModel)"}}
            """,
        ]
        lines.append(contentsOf: (0..<turns).map { _ in Self.tokenCountLine(stamp: stamp) })
        try (lines.joined(separator: "\n") + "\n").write(
            to: codexDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func appendTurn(to name: String) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let url = codexDir.appendingPathComponent(name)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(
            contentsOf: Data((Self.tokenCountLine(stamp: iso.string(from: Date())) + "\n").utf8))
    }

    private static func tokenCountLine(stamp: String) -> String {
        """
        {"type":"event_msg","timestamp":"\(stamp)",\
        "payload":{"type":"token_count","info":{"last_token_usage":\
        {"input_tokens":\(tokensPerTurn),"cached_input_tokens":0,"output_tokens":0,\
        "reasoning_output_tokens":0,"total_tokens":\(tokensPerTurn)}}}}
        """
    }

    private func makeRepository(_ name: String) throws -> URL {
        let repo = repos.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        return repo.standardizedFileURL
    }

    private func makeWorktree(_ name: String, of main: URL) throws -> URL {
        let worktree = repos.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(main.path)/.git/worktrees/\(name)\n"
            .write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        return worktree.standardizedFileURL
    }
}
