import XCTest

@testable import Sissy

/// What Sissy remembers about checkouts, against real directories on disk —
/// the whole job is reading what git actually left there, which a stubbed file
/// system could not show.
final class ProjectLedgerTests: XCTestCase {
    private var root: URL!
    private var stateDir: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-ledger-\(UUID().uuidString)")
        stateDir = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The point of the file: a checkout read on one run answers on the next,
    /// with nothing but the ledger carried between them.
    func testACheckoutReadOnOneRunAnswersOnTheNext() throws {
        let main = try makeRepository("sissy")
        let worktree = try makeWorktree("grampus", of: main)
        let first = ProjectLedger(url: url)
        XCTAssertEqual(ProjectResolver(ledger: first).project(for: worktree.path), main.path)
        first.saveIfDirty()

        try FileManager.default.removeItem(at: worktree)

        let second = ProjectResolver(ledger: ProjectLedger(url: url))
        XCTAssertEqual(second.project(for: worktree.path), main.path)
    }

    /// One ledger, every provider. Codex's own resolver never reads a `.git`
    /// entry of its own — the directories its rollouts name are scratch — so
    /// every checkout it can recognise was read by another provider's.
    func testACheckoutOneProvidersResolverReadIsAnsweredForByAnothers() throws {
        let main = try makeRepository("sissy")
        let worktree = try makeWorktree("grampus", of: main)
        let shared = ProjectLedger()
        XCTAssertEqual(ProjectResolver(ledger: shared).project(for: worktree.path), main.path)

        try FileManager.default.removeItem(at: worktree)

        XCTAssertEqual(ProjectResolver(ledger: shared).project(for: worktree.path), main.path)
    }

    /// It knows nothing about a repository until something resolves against
    /// it, and then it knows every worktree git lists for it.
    func testResolvingARepositoryRecordsTheWorktreesGitListsForIt() throws {
        let main = try makeRepository("sissy")
        _ = try makeWorktree("grampus", of: main)
        _ = try makeWorktree("rockfish", of: main)
        let ledger = ProjectLedger()

        _ = ProjectResolver(ledger: ledger).project(for: main.path)

        XCTAssertEqual(
            Set(ledger.all().map(\.directory)),
            [
                main.path,
                root.appendingPathComponent("grampus").standardizedFileURL.path,
                root.appendingPathComponent("rockfish").standardizedFileURL.path,
            ])
    }

    /// A repository's worktree list is taken on trust for a window, so the
    /// tail's own cadence cannot turn into a directory read per line.
    func testARepositorysWorktreeListIsNotReReadWithinTheWindow() throws {
        let main = try makeRepository("sissy")
        let ledger = ProjectLedger()
        let now = Date()
        ledger.harvestWorktrees(of: main.path, now: now)

        _ = try makeWorktree("grampus", of: main)
        ledger.harvestWorktrees(of: main.path, now: now.addingTimeInterval(1))

        XCTAssertEqual(ledger.all().map(\.directory), [])
    }

    /// Gone is a fact about the path: a directory still on disk is answered by
    /// the disk, whatever the ledger remembers about it.
    func testADirectoryStillOnDiskIsNotAnsweredFor() throws {
        let main = try makeRepository("sissy")
        let worktree = try makeWorktree("grampus", of: main)
        let ledger = ProjectLedger()
        _ = ProjectResolver(ledger: ledger).project(for: worktree.path)

        XCTAssertNil(ledger.project(under: worktree.path))
    }

    /// A file a newer build wrote knows more than this one can express, so it
    /// is left where it is rather than replaced with a narrower reading.
    func testAFileFromANewerSchemaIsLeftAloneRatherThanOverwritten() throws {
        let ahead = """
            {"schemaVersion":\(ProjectLedger.currentSchemaVersion + 1),\
            "updatedAt":"2026-09-13T00:00:00Z","checkouts":[]}
            """
        try ahead.write(to: url, atomically: true, encoding: .utf8)

        let ledger = ProjectLedger(url: url)
        ledger.remember(ProjectCheckout(directory: "/a/b", project: "/a"))
        ledger.saveIfDirty()

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), ahead)
        XCTAssertEqual(
            ledger.all(), [ProjectCheckout(directory: "/a/b", project: "/a")],
            "the run still learns, it just does not write")
    }

    /// Every write is atomic, so a file that will not decode is an artifact
    /// rather than a record. It is kept for forensics and the run starts over.
    func testAFileThatDoesNotDecodeIsQuarantined() throws {
        try "not json".write(to: url, atomically: true, encoding: .utf8)

        let ledger = ProjectLedger(url: url)

        XCTAssertEqual(ledger.all(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let quarantined = try FileManager.default
            .contentsOfDirectory(atPath: stateDir.path)
            .filter { $0.contains(".corrupt-") }
        XCTAssertEqual(quarantined.count, 1)
    }

    /// What is carried between runs is bounded, so years of worktrees cannot
    /// grow the file without end.
    func testWhatIsCarriedBetweenRunsIsBounded() {
        let ledger = ProjectLedger()

        ledger.adopt(
            (1...(ProjectLedger.maxCheckouts + 10)).map {
                ProjectCheckout(directory: "/Users/d/gone/\($0)", project: "/Users/d/dev/sissy")
            })

        XCTAssertEqual(ledger.all().count, ProjectLedger.maxCheckouts)
    }

    private var url: URL { ProjectLedger.defaultURL(in: stateDir) }

    private func makeRepository(_ name: String) throws -> URL {
        let repo = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        return repo.standardizedFileURL
    }

    private func makeWorktree(_ name: String, of main: URL) throws -> URL {
        let worktree = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(main.path)/.git/worktrees/\(name)\n"
            .write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        let admin = main.appendingPathComponent(".git/worktrees/\(name)")
        try FileManager.default.createDirectory(at: admin, withIntermediateDirectories: true)
        try "\(worktree.standardizedFileURL.path)/.git\n"
            .write(to: admin.appendingPathComponent("gitdir"), atomically: true, encoding: .utf8)
        return worktree.standardizedFileURL
    }
}
