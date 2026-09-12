import XCTest

@testable import Sissy

/// Which repository a working directory belongs to, against real directories
/// on disk — the whole job is reading what git actually left there, which a
/// stubbed file system could not show.
final class ProjectResolverTests: XCTestCase {
    private var root: URL!
    private var resolver: ProjectResolver!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-projects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        resolver = ProjectResolver()
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
    /// to resolve to, and a dead path is not a project.
    func testAWorktreeDeletedFromBesideItsRepositoryIsNotAProject() throws {
        _ = try makeRepository("sissy")

        XCTAssertNil(resolver.project(for: root.appendingPathComponent("rockfish").path))
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
