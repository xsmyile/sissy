import Foundation

/// A directory that was a checkout of a repository, and the repository it
/// belonged to.
///
/// `directory` is where the `.git` entry was read: a worktree for a worktree,
/// the repository itself for a repository. `project` is the answer that entry
/// gave — the main checkout in the first case, the directory in the second.
struct ProjectCheckout: Codable, Equatable, Sendable {
    let directory: String
    let project: String
}

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
/// inside its own repository still resolves after deletion. One kept beside it
/// has nothing left to walk up to, and that is what `ProjectCheckout` is for:
/// a directory the resolver has *already read a `.git` entry from* keeps the
/// answer that entry gave once it is gone. That is remembering an answer, not
/// inventing one — the distinction the paragraph above draws — and it is what
/// makes attribution a property of the work rather than of when Sissy happened
/// to read the line. Measured on a real day: the same tree read live attributes
/// 99.7% of it, read cold after the worktrees were deleted, 34%.
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
/// One resolver serves a whole provider — its tail and the rows it reads back
/// off disk both — because two of them would answer the same path differently
/// as soon as one of them had seen a checkout the other had not.
///
/// Only ever touched from inside a provider's actor, which is what lets it
/// hold a plain mutable cache — the same arrangement `SourceAdapter` has.
final class ProjectResolver {
    /// What a worktree's `.git` file points at, and the only shape that says
    /// where the main checkout is.
    private static let worktreeMarker = "/.git/worktrees/"
    private static let gitdirPrefix = "gitdir:"
    private static let gitEntryName = ".git"
    private static let originSection = "[remote \"origin\"]"
    private static let urlKey = "url"

    /// How many gone checkouts are worth carrying. A real history names a few
    /// hundred over a year of worktrees; past that the oldest are dropped, and
    /// what they cost is a row's label on a directory nothing has worked in
    /// for that long.
    static let maxRememberedCheckouts = 512

    private let fileManager: FileManager
    private var cache: [String: String?] = [:]
    private var owners: [String: String?] = [:]
    /// Most recently confirmed first, which is also the order the cap drops
    /// from: a checkout still being worked in is re-confirmed on every launch.
    private var checkouts: [ProjectCheckout] = []

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func project(for workingDirectory: String) -> String? {
        if let hit = cache[workingDirectory] { return hit }
        let resolved = resolve(workingDirectory)
        cache[workingDirectory] = resolved
        return resolved
    }

    /// Seeds what an earlier run read off disk. Additive and behind whatever
    /// this run has already walked to: a `.git` entry read a moment ago is a
    /// fresher answer about the same directory than one read last week.
    func adopt(_ remembered: [ProjectCheckout]) {
        let known = Set(checkouts.map(\.directory))
        checkouts.append(contentsOf: remembered.filter { !known.contains($0.directory) })
        capCheckouts()
    }

    func rememberedCheckouts() -> [ProjectCheckout] { checkouts }

    /// The account a repository belongs to on the forge it is pushed to —
    /// `radonforge` for `radonforge/website` — read from its `origin` remote.
    ///
    /// It exists because a repository's own name is not unique: `website`
    /// under two different accounts is two projects rendering one label, and
    /// the path that tells them apart is in a tooltip nobody hovers. The owner
    /// is the shortest thing that separates them.
    ///
    /// Nil whenever the answer would be invented. A repository with no
    /// `origin`, one whose `origin` is a path on this Mac rather than a forge,
    /// and a checkout that has since been deleted all answer nothing, and the
    /// row keeps the name it has today. Read fresh rather than persisted: a
    /// remote can be renamed or removed, and what a path means is today's
    /// answer.
    ///
    /// A forge that nests groups — `gitlab.com/group/sub/repo` — answers
    /// `sub`, which is the account the repository sits directly under rather
    /// than the whole hierarchy. That is the label the user types.
    func repositoryOwner(for project: String) -> String? {
        if let hit = owners[project] { return hit }
        let resolved = readRepositoryOwner(project)
        owners[project] = resolved
        return resolved
    }

    private func resolve(_ workingDirectory: String) -> String? {
        let start = URL(fileURLWithPath: workingDirectory).standardizedFileURL
        var directory = start
        while true {
            let entry = directory.appendingPathComponent(Self.gitEntryName)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory) {
                let project =
                    isDirectory.boolValue
                    ? directory.path
                    : mainCheckout(ofWorktreePointer: entry) ?? directory.path
                remember(ProjectCheckout(directory: directory.path, project: project))
                // The main checkout a worktree pointer names is a reading too,
                // and it is the key a persisted row is looked up under: without
                // it a repository only ever worked in through its worktrees
                // would lose its rows the day it was deleted.
                if project != directory.path {
                    remember(ProjectCheckout(directory: project, project: project))
                }
                return project
            }
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            if parent.path == directory.path { break }
            directory = parent
        }
        return rememberedProject(under: start.path)
    }

    /// The repository a directory belonged to when it was last read, for a
    /// directory that is no longer there.
    ///
    /// Only for one that is **gone**. A directory still on disk that names no
    /// repository is answered by the disk, because what a path means is
    /// today's answer; a deletion is not a change of meaning, it is the end of
    /// the only thing that could have changed it.
    ///
    /// Deepest match wins, so a worktree that sat inside another checkout is
    /// answered by itself rather than by what contained it. A shallower one is
    /// never consulted behind a deeper match that survives: if that directory
    /// is still there and the walk still failed, its `.git` entry is gone too,
    /// and it is today's answer that says so.
    private func rememberedProject(under workingDirectory: String) -> String? {
        let match =
            checkouts
            .filter { workingDirectory.isInside($0.directory) }
            .max { $0.directory.count < $1.directory.count }
        guard let match, !fileManager.fileExists(atPath: match.directory) else { return nil }
        remember(match)
        return match.project
    }

    private func remember(_ checkout: ProjectCheckout) {
        if checkouts.first == checkout { return }
        checkouts.removeAll { $0.directory == checkout.directory }
        checkouts.insert(checkout, at: 0)
        capCheckouts()
    }

    private func capCheckouts() {
        guard checkouts.count > Self.maxRememberedCheckouts else { return }
        checkouts.removeLast(checkouts.count - Self.maxRememberedCheckouts)
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

    /// The `url` of the `origin` remote, or nil when the repository has no
    /// `.git/config` on disk — which is also the answer for a checkout that
    /// has been deleted since its rows were counted.
    private func originURL(ofRepository project: String) -> String? {
        let config = URL(fileURLWithPath: project)
            .appendingPathComponent(Self.gitEntryName)
            .appendingPathComponent("config")
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return nil }
        var inOrigin = false
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inOrigin = trimmed == Self.originSection
                continue
            }
            guard inOrigin, let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[trimmed.startIndex..<separator].trimmingCharacters(in: .whitespaces)
            guard key == Self.urlKey else { continue }
            let value = trimmed[trimmed.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private func readRepositoryOwner(_ project: String) -> String? {
        guard let url = originURL(ofRepository: project) else { return nil }
        return Self.owner(ofRemoteURL: url)
    }

    /// The segment before the repository name in a remote that names a forge.
    ///
    /// Both shapes git writes are accepted: an SCP-like `git@host:owner/repo`
    /// and a URL `scheme://[user@]host/owner/repo`. Anything naming a path on
    /// this Mac answers nil rather than the enclosing folder — a bare path
    /// with no scheme and no `host:`, and equally a `file://` URL, whose host
    /// is empty and whose first segment is a directory rather than an account.
    static func owner(ofRemoteURL remote: String) -> String? {
        let trimmed = remote.trimmingCharacters(in: .whitespaces)
        let path: String
        if let scheme = trimmed.range(of: "://") {
            let afterScheme = trimmed[scheme.upperBound...]
            guard let slash = afterScheme.firstIndex(of: "/"), slash != afterScheme.startIndex
            else { return nil }
            path = String(afterScheme[afterScheme.index(after: slash)...])
        } else if let colon = trimmed.firstIndex(of: ":") {
            let host = trimmed[trimmed.startIndex..<colon]
            guard !host.isEmpty, !host.contains("/") else { return nil }
            path = String(trimmed[trimmed.index(after: colon)...])
        } else {
            return nil
        }
        let segments =
            path
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard segments.count >= 2 else { return nil }
        return segments[segments.count - 2]
    }
}

extension String {
    /// Whether this path is `directory` or sits under it, by path component —
    /// `/a/bc` is not inside `/a/b`.
    fileprivate func isInside(_ directory: String) -> Bool {
        self == directory || hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
    }
}
