import Foundation

/// Repositories and linked worktrees laid out on disk the way `git` leaves
/// them, without running it.
enum GitFixture {
    /// A directory holding an empty `.git` directory, which is all a
    /// repository has to be for Sissy to recognise one.
    static func repository(_ name: String, in root: URL) throws -> URL {
        let repo = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        return repo.standardizedFileURL
    }

    /// Both halves of what `git worktree add` leaves behind: the pointer in
    /// the worktree and the entry in the repository's admin directory naming
    /// it back. The second is what lets a worktree be recognised without ever
    /// having been worked in.
    static func worktree(_ name: String, of main: URL, in root: URL) throws -> URL {
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
