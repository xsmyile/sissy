import Foundation

/// Asks git itself who would sign a commit in a repository.
///
/// Git resolves identity across system, XDG, global, repository and worktree
/// configuration, through `include` and `includeIf`, and `includeIf gitdir:`
/// matches the **git directory** rather than the checkout. Measured
/// 2026-09-17: a worktree at `~/orca/workspaces/legion/penguin` sits outside
/// every configured root and still commits under the work identity, because
/// its git dir is `~/mdev/legion/.git/worktrees/<name>`. Reimplementing that
/// precedence would be a second engine to keep in step with git's, so every
/// reading here is git's own answer to a question git was asked.
///
/// **Three calls, and each is load-bearing.** `rev-parse` is what says the
/// path is a repository at all: measured, `git config` and `git var` both
/// answer out of the global configuration with no repository in sight, so
/// without it a checkout that has been deleted reports the machine's default
/// identity as though it were its own. `config --get-regexp` names the file a
/// correction has to be made in, which `var` does not carry, **and it is what
/// decides whether there is an identity here at all**. And `var` is the
/// authority on what that identity resolves to, through every `include` and
/// `includeIf` in the chain.
///
/// **`var` is not asked whether an identity exists, because it invents one.**
/// With no `user.email` set anywhere git falls back to the gecos field and the
/// machine's hostname, and whether it then refuses that guess depends on the
/// hostname: measured 2026-09-17, a Mac whose hostname yields no domain exits
/// 128 with `unable to auto-detect email address`, while a CI runner whose
/// hostname ends `.local` was served
/// `Anka <runner@…-F66C054AC5DC.local>` with status 0. A reading taken from
/// that is an address nobody owns, and it would join its forge's electorate
/// and could become what that forge expects. So the configuration is asked
/// first: no `user.email` in the chain is `.unset`, whatever `var` would have
/// answered, and `var` is spent only where there is something for it to
/// resolve.
///
/// **Nothing here runs repository content.** `rev-parse`, `config` and `var`
/// execute no hooks, take no locks and write nothing, which is what lets this
/// read a repository without changing its state.
///
/// **The environment is replaced rather than inherited.** `GIT_DIR` beats
/// `git -C` and would answer for a repository this reader was never pointed
/// at — the same trap `session-start.sh` strips the environment for — and
/// `GIT_AUTHOR_EMAIL` would substitute itself for the reading. Setting
/// `Process.environment` at all is what drops them, and `LC_ALL` is pinned so
/// a message that reaches a user is the message git's own documentation names.
enum GitIdentityReader {
    /// Longer than three `git config` reads need by any margin, and short
    /// enough that a repository on a sleeping volume does not hold a sweep.
    static let timeoutSeconds: TimeInterval = 10
    /// What a child gets to exit in after `SIGTERM` before it is killed.
    ///
    /// Terminating is a request, and a process wedged on a network mount or a
    /// disk that has stopped answering does not get to read it — while this
    /// caller is inside a blocking `readDataToEndOfFile`, so a child that
    /// never dies takes the sweep loop with it for the life of the app, and
    /// the panel's own refresh with it.
    static let killGraceSeconds: TimeInterval = 2

    /// Where a real `git` is, in the order a Mac is likely to have one.
    ///
    /// `/usr/bin/git` is deliberately last and deliberately conditional: it is
    /// a Command Line Tools shim, and on a Mac without them it opens the
    /// system's *Install developer tools* dialog. A module that nobody asked
    /// to run must not put a dialog on screen, so the shim is used only once
    /// `xcode-select -p` has said there is something behind it.
    private static let toolCandidates = [
        "/opt/homebrew/bin/git", "/usr/local/bin/git", "/opt/local/bin/git",
    ]
    private static let systemTool = "/usr/bin/git"
    private static let xcodeSelect = "/usr/bin/xcode-select"
    private static let searchPath = "/usr/bin:/bin"
    private static let gitEntryName = ".git"
    private static let originPrefix = "file:"

    /// The git this Mac should be read with, or nil where using one would cost
    /// the user a dialog they did not ask for.
    static func locate(fileManager: FileManager = .default) -> URL? {
        for candidate in toolCandidates where fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        guard fileManager.isExecutableFile(atPath: systemTool),
            run(URL(fileURLWithPath: xcodeSelect), ["-p"], in: nil, environment: [:]).status == 0
        else { return nil }
        return URL(fileURLWithPath: systemTool)
    }

    /// One repository's reading, with no verdict on it: what a forge expects is
    /// a property of every repository on it, which one reading cannot see.
    ///
    /// A directory that is no longer there answers nil rather than a failure.
    /// A deleted checkout is not a repository that went wrong, and a row
    /// saying so for every worktree a user has ever removed would bury the one
    /// row this feature exists to show.
    static func read(
        repository: String, remote: ProjectRemote?, git: URL, home: URL,
        fileManager: FileManager = .default
    ) -> GitIdentityScan? {
        let directory = URL(fileURLWithPath: repository)
        guard fileManager.fileExists(atPath: directory.appendingPathComponent(gitEntryName).path)
        else { return nil }
        let environment = environment(home: home)
        let invoke = { (arguments: [String]) in
            run(git, ["-C", repository] + arguments, in: repository, environment: environment)
        }
        let ambient = ambientSources(home: home, repository: repository)
        let proof = invoke(["rev-parse", "--absolute-git-dir"])
        guard proof.status == 0 else {
            return GitIdentityScan(
                identity: identity(
                    repository, remote: remote, reading: .unreadable(proof.failure), origin: nil),
                sources: ambient)
        }
        let origins = invoke([
            "config", "--show-origin", "--show-scope", "--get-regexp", userKeyPattern,
        ])
        guard origins.status == 0 || origins.status == noMatchStatus else {
            return GitIdentityScan(
                identity: identity(
                    repository, remote: remote, reading: .unreadable(origins.failure), origin: nil),
                sources: ambient)
        }
        let settings = entries(in: origins.output, repository: repository)
        let sources = ambient + settings.map(\.origin.file).filter { !ambient.contains($0) }
        let origin = winningOrigin(in: settings)
        let local = localKeys(in: settings)
        guard settings.contains(where: { $0.key == emailKey }) else {
            return GitIdentityScan(
                identity: identity(
                    repository, remote: remote, reading: .unset, origin: origin, localKeys: local),
                sources: sources)
        }
        let ident = invoke(["var", "GIT_AUTHOR_IDENT"])
        guard ident.status == 0, let author = author(of: ident.output) else {
            return GitIdentityScan(
                identity: identity(
                    repository, remote: remote, reading: .unreadable(ident.failure), origin: origin,
                    localKeys: local),
                sources: sources)
        }
        return GitIdentityScan(
            identity: identity(
                repository, remote: remote, reading: .author(author), origin: origin,
                localKeys: local),
            sources: sources)
    }

    /// The files a reading could come out of even when it did not come out of
    /// any of them yet.
    ///
    /// `--show-origin` names only the files that actually carried a `user.*`
    /// key, so a repository with no identity of its own lists neither its own
    /// config nor the global one — and a `user.email` appearing in either is
    /// exactly the change the stamps have to catch. An absent file stamps as
    /// absent, so its creation counts.
    private static func ambientSources(home: URL, repository: String) -> [String] {
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0).appendingPathComponent("git/config").path
        }
        return [
            repository + "/.git/config",
            home.appendingPathComponent(".gitconfig").path,
            xdg ?? home.appendingPathComponent(".config/git/config").path,
        ]
    }

    /// When each of a reading's files was last written, with an absent one
    /// stamped `distantPast` so that creating it reads as a change.
    static func stamps(of files: [String], fileManager: FileManager = .default) -> [String: Date] {
        var stamps: [String: Date] = [:]
        for file in files {
            let attributes = try? fileManager.attributesOfItem(atPath: file)
            stamps[file] = (attributes?[.modificationDate] as? Date) ?? .distantPast
        }
        return stamps
    }

    /// The command that takes a repository's own override back out, for the
    /// clipboard.
    ///
    /// Sissy does not run it. Writing another program's configuration needs a
    /// preview, a backup, a refusal of stale writes and an undo, and none of
    /// that is worth building for an edit the user can read in one line and
    /// already has a terminal open for. It unsets rather than rewrites,
    /// because the value that should win is the one the configuration already
    /// resolves to once the override is gone.
    ///
    /// One `--unset` per key the repository actually sets, and only those:
    /// git exits 5 on a key that is absent, so a fixed pair chained with `&&`
    /// stopped before the second key whenever the first was not there — which
    /// is exactly the repository whose only override is `user.name`.
    ///
    /// Nil for a path `sh` quoting cannot make safe. The alternative is the
    /// raw path in a command the user is invited to paste into a shell, which
    /// is an injection through a directory name — so a repository that cannot
    /// be named safely is offered no command at all. Nil too where there is
    /// no key to unset.
    static func unsetCommand(repository: String, keys: [String]) -> String? {
        guard !keys.isEmpty, let quoted = AgentHookInstaller.quoted(repository) else {
            return nil
        }
        return keys.map { "git -C \(quoted) config --unset \($0)" }.joined(separator: " && ")
    }

    private static let userKeyPattern = "^user\\.(name|email)$"
    private static let emailKey = "user.email"
    /// What `--get-regexp` exits with when nothing matched, which is the only
    /// non-zero status that means the configuration was read and holds no
    /// identity. Anything else is a configuration that could not be read at
    /// all — measured 2026-09-17, a malformed file exits 128 with `bad config
    /// line 1 in file …` — and reporting that as "no identity resolves here"
    /// would tell the user git will refuse their commit when the truth is
    /// that a file needs repairing.
    private static let noMatchStatus: Int32 = 1

    private static func identity(
        _ repository: String, remote: ProjectRemote?, reading: GitIdentityReading,
        origin: GitConfigOrigin?, localKeys: [String] = []
    ) -> RepositoryIdentity {
        RepositoryIdentity(
            repository: repository, reading: reading, origin: origin, remote: remote,
            verdict: .unjudged, localKeys: localKeys)
    }

    /// The `user.*` keys set in the repository's own file, once each and in
    /// the order git parsed them.
    private static func localKeys(in settings: [GitSetting]) -> [String] {
        var keys: [String] = []
        for setting in settings
        where setting.origin.scope == localScope && !keys.contains(setting.key) {
            keys.append(setting.key)
        }
        return keys
    }

    private static let localScope = "local"

    /// The most local of the files that set a `user.*` key, which is the one a
    /// correction has to name.
    ///
    /// Not `user.email`'s alone. A verdict is formed on the name **and** the
    /// address, so a repository whose only override is `user.name` is wrong
    /// for a reason `user.email`'s origin cannot see — it reported the global
    /// file, and the row offered no correction against a local override that
    /// was really there.
    private static func winningOrigin(in settings: [GitSetting]) -> GitConfigOrigin? {
        settings.max { rank(of: $0.origin.scope) < rank(of: $1.origin.scope) }?.origin
    }

    /// Git's own precedence over the scopes it names, so "most local" is a
    /// comparison rather than a string test. An unknown scope sorts below
    /// every known one rather than above: a scope this build has not met
    /// cannot be shown to outrank the repository's own file.
    private static func rank(of scope: String) -> Int {
        switch scope {
        case "system": return 1
        case "global": return 2
        case "local": return 3
        case "worktree": return 4
        case "command": return 5
        default: return 0
        }
    }

    /// Every `user.*` git resolved, in the order it parsed them.
    ///
    /// `<scope>\t<origin>\t<key> <value>`, measured. A local origin is
    /// relative to the working directory, so it is resolved against the
    /// repository — a row reading `.git/config` names no file anyone can open.
    /// The files are the include chain that actually fed this repository, an
    /// `includeIf` profile among them, which is what a round re-stats.
    private static func entries(in output: String, repository: String) -> [GitSetting] {
        var settings: [GitSetting] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, let space = fields[2].firstIndex(of: " ") else { continue }
            var file = String(fields[1])
            if file.hasPrefix(originPrefix) { file.removeFirst(originPrefix.count) }
            guard !file.isEmpty else { continue }
            let resolved =
                file.hasPrefix("/")
                ? file
                : URL(fileURLWithPath: repository).appendingPathComponent(file).path
            settings.append(
                GitSetting(
                    key: String(fields[2][fields[2].startIndex..<space]),
                    origin: GitConfigOrigin(scope: String(fields[0]), file: resolved)))
        }
        return settings
    }

    /// `Name <email> 1789667099 +0200`, measured. The stamp is trailing and
    /// fixed-shape, and the name is whatever precedes the address — which may
    /// itself hold spaces and angle brackets are what bound it.
    private static func author(of output: String) -> GitAuthor? {
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = line.lastIndex(of: "<"), let close = line[open...].firstIndex(of: ">")
        else { return nil }
        let name = String(line[line.startIndex..<open]).trimmingCharacters(in: .whitespaces)
        let email = String(line[line.index(after: open)..<close])
        guard !name.isEmpty, !email.isEmpty else { return nil }
        return GitAuthor(name: name, email: email)
    }

    private static func text(_ data: Data) -> String {
        String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) ?? ""
    }

    private static func environment(home: URL) -> [String: String] {
        var environment = [
            "HOME": home.path,
            "PATH": searchPath,
            "LC_ALL": "C",
            "GIT_TERMINAL_PROMPT": "0",
        ]
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            environment["XDG_CONFIG_HOME"] = xdg
        }
        return environment
    }

    /// One bounded invocation.
    ///
    /// Both pipes are drained, and standard error on a queue of its own: a
    /// pipe nobody reads blocks the child once the kernel buffer fills, and
    /// reading them in sequence is the same deadlock with a longer fuse.
    ///
    /// UTF-8 first and Latin-1 behind it. A committer's name is free text in
    /// a file git never validated, and every byte is a Latin-1 character — so
    /// a name that is not UTF-8 comes back mangled rather than costing the row
    /// its whole reading, which is what a nil would do.
    private static func run(
        _ tool: URL, _ arguments: [String], in directory: String?, environment: [String: String]
    ) -> GitOutput {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.environment = environment
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let out = Pipe()
        let errors = Pipe()
        process.standardOutput = out
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return GitOutput(status: -1, output: "", failure: "\(error)")
        }
        let collected = LockedValue(Data())
        let draining = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: draining) {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            collected.update { $0 = data }
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        let executioner = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        let queue = DispatchQueue.global(qos: .utility)
        queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: watchdog)
        queue.asyncAfter(deadline: .now() + timeoutSeconds + killGraceSeconds, execute: executioner)
        let output = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        draining.wait()
        watchdog.cancel()
        executioner.cancel()
        return GitOutput(
            status: process.terminationStatus,
            output: Self.text(output),
            failure: Self.text(collected.load()))
    }
}

/// One repository's reading and the files it depends on.
///
/// The files are what makes a sweep free at rest. Every invocation costs a
/// process, and a process costs about 67 ms on a Mac measured 2026-09-17 —
/// `/usr/bin/true` costs the same, so it is the spawn rather than git — which
/// put a 23-repository sweep at 5.82 s of a core every round. A reading can
/// only change when a file that fed it does, so a round that finds every
/// stamp where it left it spends stats instead of processes.
struct GitIdentityScan: Sendable {
    let identity: RepositoryIdentity
    let sources: [String]
}

/// One `user.*` git resolved and where it came from.
private struct GitSetting {
    let key: String
    let origin: GitConfigOrigin
}

/// One git invocation's result, with the message kept because a failure the
/// user is shown has to say what git said.
private struct GitOutput {
    let status: Int32
    let output: String
    let failure: String

    init(status: Int32, output: String, failure: String) {
        self.status = status
        self.output = output
        self.failure = failure.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
