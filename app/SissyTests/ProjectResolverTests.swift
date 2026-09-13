import XCTest

@testable import Sissy

/// Which repository a working directory belongs to, against real directories
/// on disk — the whole job is reading what git actually left there, which a
/// stubbed file system could not show.
final class ProjectResolverTests: XCTestCase {
    private var root: URL!
    private var ledger: ProjectLedger!
    private var resolver: ProjectResolver!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-projects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ledger = ProjectLedger()
        resolver = ProjectResolver(ledger: ledger)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testARepositoryRootIsItsOwnProject() throws {
        let repo = try makeRepository("legion")

        XCTAssertEqual(resolver.project(for: repo.path), repo.path)
    }

    func testADirectoryInsideARepositoryBelongsToTheRepository() throws {
        let repo = try makeRepository("legion")
        let nested = repo.appendingPathComponent("frontend/src")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        XCTAssertEqual(resolver.project(for: nested.path), repo.path)
    }

    func testAWorktreeBelongsToTheCheckoutItWasCutFrom() throws {
        let main = try makeRepository("sissy")
        let worktree = try makeWorktree("grampus", of: main)

        XCTAssertEqual(
            resolver.project(for: worktree.path), main.path,
            "a worktree and its main checkout are the same work")
    }

    func testAWorktreeWithARelativePointerResolvesTheSameWay() throws {
        let main = try makeRepository("sissy")
        let worktree = root.appendingPathComponent("cormorant")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: ../sissy/.git/worktrees/cormorant\n"
            .write(
                to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        XCTAssertEqual(resolver.project(for: worktree.path), main.path)
    }

    /// A submodule's `.git` file names `.git/modules/<name>`, not a worktree.
    /// It is its own repository, so it is its own project.
    func testASubmoduleIsItsOwnProject() throws {
        let parent = try makeRepository("host")
        let submodule = parent.appendingPathComponent("vendor/lib")
        try FileManager.default.createDirectory(at: submodule, withIntermediateDirectories: true)
        try "gitdir: ../../.git/modules/lib\n"
            .write(
                to: submodule.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        XCTAssertEqual(resolver.project(for: submodule.path), submodule.path)
    }

    /// A CLI makes one of these for a single conversation. It is not a project
    /// and must not be given the name of one.
    func testADirectoryInNoRepositoryIsNotAProject() throws {
        let loose = root.appendingPathComponent("scratch/notes")
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)

        XCTAssertNil(resolver.project(for: loose.path))
    }

    /// The walk never stats the starting directory, so a worktree kept inside
    /// its own repository still counts against it after being deleted.
    func testAWorktreeDeletedFromInsideItsRepositoryStillResolves() throws {
        let repo = try makeRepository("norace")

        XCTAssertEqual(
            resolver.project(for: repo.appendingPathComponent(".git-worktrees/gone").path),
            repo.path)
    }

    /// One kept beside the repository rather than inside it has nothing left
    /// to resolve to, and a dead path this resolver never saw alive is not a
    /// project.
    func testAWorktreeDeletedBesideItsRepositoryAndNeverSeenAliveIsNotAProject() throws {
        _ = try makeRepository("sissy")

        XCTAssertNil(resolver.project(for: root.appendingPathComponent("rockfish").path))
    }

    /// The one a run did read a `.git` entry from keeps the answer that entry
    /// gave. Attribution is a fact about the work, not about whether Sissy
    /// happened to read the line before the worktree was thrown away.
    func testAWorktreeSeenAliveStillNamesItsRepositoryOnceDeleted() throws {
        let main = try makeRepository("sissy")
        let worktree = try makeWorktree("grampus", of: main)
        XCTAssertEqual(resolver.project(for: worktree.path), main.path)

        let nextRun = try relaunch(after: worktree)

        XCTAssertEqual(nextRun.project(for: worktree.path), main.path)
    }

    /// A worktree is worked in from its subdirectories as much as from its
    /// root, and they are gone with it.
    func testADirectoryUnderAGoneWorktreeResolvesThroughIt() throws {
        let main = try makeRepository("sissy")
        let worktree = try makeWorktree("grampus", of: main)
        XCTAssertEqual(resolver.project(for: worktree.path), main.path)

        let nextRun = try relaunch(after: worktree)

        XCTAssertEqual(
            nextRun.project(for: worktree.appendingPathComponent("app").path), main.path)
    }

    /// Gone is a fact about the path. A directory still on disk that names no
    /// repository any more is answered by the disk, whatever it used to be.
    func testADirectoryStillOnDiskIsAnsweredByTheDiskRatherThanByWhatItWas() throws {
        let repo = try makeRepository("legion")
        XCTAssertEqual(resolver.project(for: repo.path), repo.path)
        let remembered = ledger.all()
        try FileManager.default.removeItem(at: repo.appendingPathComponent(".git"))

        let nextRun = relaunch(adopting: remembered)

        XCTAssertNil(nextRun.project(for: repo.path))
    }

    /// Two gone checkouts can both contain the directory. The closer one is
    /// the one the work was in.
    func testTheDeepestGoneCheckoutIsTheOneThatAnswers() throws {
        let outer = try makeRepository("alpha")
        let other = try makeRepository("beta")
        let inner = outer.appendingPathComponent("worktrees/x")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try "gitdir: \(other.path)/.git/worktrees/x\n"
            .write(to: inner.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(resolver.project(for: outer.path), outer.path)
        XCTAssertEqual(resolver.project(for: inner.path), other.path)

        let nextRun = try relaunch(after: outer)

        XCTAssertEqual(nextRun.project(for: inner.appendingPathComponent("app").path), other.path)
    }

    /// What is carried between runs is bounded, so a year of worktrees cannot
    /// grow the snapshot without end.
    func testWhatIsCarriedBetweenRunsIsBounded() {
        let many = (1...(ProjectLedger.maxCheckouts + 10)).map {
            ProjectCheckout(directory: "/Users/d/gone/\($0)", project: "/Users/d/dev/sissy")
        }

        ledger.adopt(many)

        XCTAssertEqual(ledger.all().count, ProjectLedger.maxCheckouts)
    }

    func testAResolvedDirectoryIsNotWalkedTwice() throws {
        let repo = try makeRepository("legion")
        let nested = repo.appendingPathComponent("frontend")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertEqual(resolver.project(for: nested.path), repo.path)

        try FileManager.default.removeItem(at: repo.appendingPathComponent(".git"))

        XCTAssertEqual(
            resolver.project(for: nested.path), repo.path,
            "the answer was re-derived from a tree that had moved under it")
    }

    /// What the next launch sees: a resolver with no cache of its own, seeded
    /// with what this one wrote into the snapshot, after `gone` has been
    /// deleted the way a worktree is.
    private func relaunch(after gone: URL) throws -> ProjectResolver {
        let remembered = ledger.all()
        try FileManager.default.removeItem(at: gone)
        return relaunch(adopting: remembered)
    }

    private func relaunch(adopting remembered: [ProjectCheckout]) -> ProjectResolver {
        let next = ProjectLedger()
        next.adopt(remembered)
        return ProjectResolver(ledger: next)
    }

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
            .write(
                to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        return worktree.standardizedFileURL
    }
}
