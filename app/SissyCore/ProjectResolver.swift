import Foundation

/// A repository's `origin`, in the parts a row can show.
///
/// The owner is why this is read at all — a repository's own name is not
/// unique — and the rest is what the panel's project card adds to it: the
/// forge the work is pushed to, and the way there.
struct ProjectRemote: Sendable, Equatable {
    /// The forge's host, with no user and no port: `github.com`.
    let host: String
    /// The account the repository sits directly under. A forge that nests
    /// groups answers the innermost one, which is the label the user types.
    let owner: String
    /// The repository's own name, without the `.git` a clone writes.
    let repository: String
    /// The page for the repository, when the remote names one rather than
    /// implying it. An `ssh` remote carrying a port names a transport
    /// endpoint and not a web host — `ssh.github.com` on 443 serves no page —
    /// so that one answers nil and the card shows the repository without a
    /// way out to it.
    let page: URL?
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
/// has nothing left to walk up to, and that is what `ProjectLedger` is for: a
/// directory a `.git` entry has *already been read from* keeps the answer that
/// entry gave once it is gone. That is remembering an answer, not inventing
/// one — the distinction the paragraph above draws — and it is what makes
/// attribution a property of the work rather than of when Sissy happened to
/// read the line.
///
/// Landing on a repository is also what tells the ledger to read git's own
/// worktree list for it, so the sibling worktrees are answered for before they
/// are deleted rather than looked up after.
///
/// Paths are standardised lexically, never through `standardizedFileURL`,
/// which strips a leading `/private` **only while the directory still exists**:
/// measured, `/private/tmp/x` answers `/tmp/x` while `x` is there and
/// `/private/tmp/x` once it is deleted. A checkout under `/tmp` or `$TMPDIR`
/// would therefore be keyed one way while it was alive and another once it was
/// gone, which is the one transition the ledger exists to survive — and it is
/// the same normalisation the session hook uses, so a directory has one key
/// whichever of the two read it. Both CLIs report a physical working directory
/// (`getcwd`), so there is nothing left for symlink resolution to add.
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
/// The cache and the owner lookups are this resolver's own; what it has read
/// about checkouts is the ledger's, and shared, because two memories answer
/// the same deleted path differently as soon as one of them has seen it alive.
///
/// An instance is only ever touched from inside one actor — a provider's for
/// the tail's, the engine's for the one an export builds and drops — which is
/// what lets it hold plain mutable caches, the same arrangement `SourceAdapter`
/// has. What is shared between those actors is the ledger, which carries its
/// own lock; a resolver is never handed from one to another.
final class ProjectResolver {
    /// What a worktree's `.git` file points at, and the only shape that says
    /// where the main checkout is.
    private static let worktreeMarker = "/.git/worktrees/"
    private static let gitdirPrefix = "gitdir:"
    private static let gitEntryName = ".git"
    private static let originSection = "[remote \"origin\"]"
    private static let urlKey = "url"
    private static let schemeSeparator = "://"
    private static let gitSuffix = ".git"
    private static let webScheme = "https"
    private static let webSchemes: Set<String> = ["http", "https"]

    private let fileManager: FileManager
    let ledger: ProjectLedger
    private var cache: [String: String?] = [:]
    private var remotes: [String: ProjectRemote?] = [:]

    init(ledger: ProjectLedger = ProjectLedger(), fileManager: FileManager = .default) {
        self.ledger = ledger
        self.fileManager = fileManager
    }

    func project(for workingDirectory: String) -> String? {
        if let hit = cache[workingDirectory] { return hit }
        let resolved = resolve(workingDirectory)
        cache[workingDirectory] = resolved
        return resolved
    }

    /// The forge a repository is pushed to, read from its `origin` remote.
    ///
    /// The owner is why it is read: a repository's own name is not unique —
    /// `website` under two different accounts is two projects rendering one
    /// label, and the path that tells them apart is in a tooltip nobody
    /// hovers. The host and the page are what the project card adds, so the
    /// row that names a repository is also the way to it.
    ///
    /// Nil whenever the answer would be invented. A repository with no
    /// `origin`, one whose `origin` is a path on this Mac rather than a forge,
    /// and a checkout that has since been deleted all answer nothing, and the
    /// row keeps the name it has today. Read fresh rather than persisted: a
    /// remote can be renamed or removed, and what a path means is today's
    /// answer.
    ///
    /// A forge that nests groups — `gitlab.com/group/sub/repo` — answers
    /// `sub` for the owner, which is the account the repository sits directly
    /// under rather than the whole hierarchy. That is the label the user
    /// types; the page keeps the hierarchy, which is what the forge needs.
    func repositoryRemote(for project: String) -> ProjectRemote? {
        if let hit = remotes[project] { return hit }
        let resolved = readRepositoryRemote(project)
        remotes[project] = resolved
        return resolved
    }

    private func resolve(_ workingDirectory: String) -> String? {
        let start = URL(fileURLWithPath: workingDirectory).standardized
        var directory = start
        while true {
            let entry = directory.appendingPathComponent(Self.gitEntryName)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory) {
                let project =
                    isDirectory.boolValue
                    ? directory.path
                    : mainCheckout(ofWorktreePointer: entry) ?? directory.path
                ledger.remember(ProjectCheckout(directory: directory.path, project: project))
                // The main checkout a worktree pointer names is a reading too,
                // and it is the key a persisted row is looked up under: without
                // it a repository only ever worked in through its worktrees
                // would lose its rows the day it was deleted.
                if project != directory.path {
                    ledger.remember(ProjectCheckout(directory: project, project: project))
                }
                ledger.harvestWorktrees(of: project)
                return project
            }
            let parent = directory.deletingLastPathComponent().standardized
            if parent.path == directory.path { break }
            directory = parent
        }
        return ledger.project(under: start.path)
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
            if root.hasPrefix("/") { return URL(fileURLWithPath: root).standardized.path }
            return
                pointer
                .deletingLastPathComponent()
                .appendingPathComponent(root)
                .standardized
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

    private func readRepositoryRemote(_ project: String) -> ProjectRemote? {
        guard let url = originURL(ofRepository: project) else { return nil }
        return Self.remote(ofRemoteURL: url)
    }

    /// A remote that names a forge, parsed.
    ///
    /// Both shapes git writes are accepted: an SCP-like `git@host:owner/repo`
    /// and a URL `scheme://[user@]host[:port]/owner/repo`. Anything naming a
    /// path on this Mac answers nil rather than the enclosing folder — a bare
    /// path with no scheme and no `host:`, and equally a `file://` URL, whose
    /// host is empty and whose first segment is a directory rather than an
    /// account.
    ///
    /// The page is the remote itself when the remote is already one a browser
    /// can open, port and all, and `https://<host>/<path>` when it is not.
    /// That second one is a substitution rather than a reading, so it is only
    /// made where the host is the whole address: an `ssh` URL naming a port is
    /// pointing at a transport, and composing a page from it invents a link
    /// that answers nothing.
    static func remote(ofRemoteURL remote: String) -> ProjectRemote? {
        let trimmed = remote.trimmingCharacters(in: .whitespaces)
        let scheme: String?
        let authority: Substring
        let path: String
        if let separator = trimmed.range(of: Self.schemeSeparator) {
            let afterScheme = trimmed[separator.upperBound...]
            guard let slash = afterScheme.firstIndex(of: "/"), slash != afterScheme.startIndex
            else { return nil }
            scheme = String(trimmed[trimmed.startIndex..<separator.lowerBound]).lowercased()
            authority = afterScheme[afterScheme.startIndex..<slash]
            path = String(afterScheme[afterScheme.index(after: slash)...])
        } else if let colon = trimmed.firstIndex(of: ":") {
            let head = trimmed[trimmed.startIndex..<colon]
            guard !head.isEmpty, !head.contains("/") else { return nil }
            scheme = nil
            authority = head
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
        let endpoint = authority.split(separator: "@").last.map(String.init) ?? ""
        let hostAndPort = endpoint.split(separator: ":", omittingEmptySubsequences: false)
        guard let host = hostAndPort.first.map(String.init), !host.isEmpty else { return nil }
        let port = hostAndPort.count > 1 ? String(hostAndPort[1]) : nil
        let name = segments[segments.count - 1]
        let repository =
            name.hasSuffix(Self.gitSuffix) ? String(name.dropLast(Self.gitSuffix.count)) : name
        let trail = (segments.dropLast() + [repository]).joined(separator: "/")
        return ProjectRemote(
            host: host,
            owner: segments[segments.count - 2],
            repository: repository,
            page: page(scheme: scheme, host: host, port: port, trail: trail)
        )
    }

    private static func page(scheme: String?, host: String, port: String?, trail: String) -> URL? {
        if let scheme, Self.webSchemes.contains(scheme) {
            let endpoint = port.map { "\(host):\($0)" } ?? host
            return URL(string: "\(scheme)://\(endpoint)/\(trail)")
        }
        guard port == nil else { return nil }
        return URL(string: "\(Self.webScheme)://\(host)/\(trail)")
    }
}
