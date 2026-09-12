import Foundation

/// Resolves a working directory to the project the work belongs to.
///
/// A project is a **repository**, not a directory. `legion/frontend` is not
/// its own project, and a worktree is not a different project from the
/// checkout it was cut from — two rows reading `grampus` and `sissy` for one
/// repository is a wrong answer rather than an untidy one. The walk goes up
/// from the working directory to the first `.git`: a directory means the
/// repository root is right there, a *file* means a worktree, and its
/// `gitdir:` line names `<main>/.git/worktrees/<name>`, which puts the work on
/// `<main>`.
///
/// **A walk that names no repository answers nil.** Sissy does not invent a
/// project out of a path it cannot verify: a scratch directory a CLI made for
/// one conversation is not a project, and neither is a worktree that has since
/// been deleted — its money belonged to the checkout it was cut from, and
/// calling it a project of its own is a wrong answer wearing a real name.
/// Unattributed usage still counts in every total; it is only denied a row.
///
/// The walk does not need the starting directory to exist, so a worktree kept
/// inside its own repository still resolves after deletion. One kept beside
/// it does not — measured across a real history, 2 219M tokens of deleted
/// directories still resolve and 2 827M have nothing left to resolve to.
///
/// Results are cached per working directory: a real day names a hundred or so
/// distinct ones across thousands of lines, and the walk costs a `stat` per
/// level.
///
/// The cache holds for the life of the process and is never invalidated, so a
/// directory `git init`-ed or turned into a worktree after Sissy first
/// resolved it keeps the answer it had until the next launch. That costs a row
/// its label, never a total its tokens, and re-walking every line to catch it
/// would cost the walk this cache exists to avoid.
///
/// A directory that no longer exists cannot be resolved and becomes its own
/// project. The tail resolves as it reads, so live counting sees the directory
/// while it is still there; a cold scan re-deriving a past day may not, and a
/// deleted worktree then reads as a project of its own rather than folding
/// back into its checkout. Measured on a real tree: replaying a past day found
/// four such directories, all worktrees that had since been removed.
///
/// Only ever touched from inside a provider's actor, which is what lets it
/// hold a plain mutable cache — the same arrangement `SourceAdapter` has.
final class ProjectResolver {
    /// What a worktree's `.git` file points at, and the only shape that says
    /// where the main checkout is.
    private static let worktreeMarker = "/.git/worktrees/"
    private static let gitdirPrefix = "gitdir:"
    private static let gitEntryName = ".git"

    private let fileManager: FileManager
    private var cache: [String: String?] = [:]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func project(for workingDirectory: String) -> String? {
        if let hit = cache[workingDirectory] { return hit }
        let resolved = resolve(workingDirectory)
        cache[workingDirectory] = resolved
        return resolved
    }

    private func resolve(_ workingDirectory: String) -> String? {
        var directory = URL(fileURLWithPath: workingDirectory).standardizedFileURL
        while true {
            let entry = directory.appendingPathComponent(Self.gitEntryName)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return directory.path }
                return mainCheckout(ofWorktreePointer: entry) ?? directory.path
            }
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            if parent.path == directory.path { return nil }
            directory = parent
        }
    }

    /// The checkout a worktree was cut from, or nil for a `.git` file that
    /// points somewhere else — a submodule names `.git/modules/<name>`, and a
    /// submodule is its own repository, so falling back to the directory the
    /// pointer sits in is the right answer rather than a missing one.
    private func mainCheckout(ofWorktreePointer pointer: URL) -> String? {
        guard let text = try? String(contentsOf: pointer, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(Self.gitdirPrefix) else { continue }
            let target = String(trimmed.dropFirst(Self.gitdirPrefix.count))
                .trimmingCharacters(in: .whitespaces)
            guard let marker = target.range(of: Self.worktreeMarker) else { return nil }
            let root = String(target[target.startIndex..<marker.lowerBound])
            if root.hasPrefix("/") { return URL(fileURLWithPath: root).standardizedFileURL.path }
            return
                pointer
                .deletingLastPathComponent()
                .appendingPathComponent(root)
                .standardizedFileURL
                .path
        }
        return nil
    }
}
