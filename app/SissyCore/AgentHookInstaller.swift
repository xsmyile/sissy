import Foundation

/// One CLI's hook configuration file, and the name a user would recognise it by.
struct AgentHookTarget: Equatable, Sendable {
    let name: String
    let url: URL
}

/// What one install or removal did, per target.
enum AgentHookOutcome: Equatable, Sendable {
    /// The entry was already exactly right, so nothing was written.
    case unchanged
    case written
    case removed
    /// The file exists and is not JSON this build can put back. It is left
    /// untouched, which is the only safe answer: repairing another program's
    /// configuration is not Sissy's to attempt.
    case unreadable
    case failed(String)
}

/// Puts Sissy's SessionStart entry into the CLIs' own hook configuration, and
/// takes it back out.
///
/// This is the one thing Sissy does that reaches outside its own directory, and
/// every rule here follows from that.
///
/// **The command string is executed by two other programs on every session
/// start**, so the path inside it is escaped for `sh` rather than trusted, and
/// the result is handed to `sh -n` before it is written anywhere. The home it is
/// built from comes from `getpwuid`, not `NSHomeDirectory()`, which was measured
/// to follow `CFFIXED_USER_HOME` — a value any process that already has the
/// user's privileges can set for every app launched afterwards, which would let
/// a transient foothold launder itself into a line Sissy writes, signed, into
/// two config files.
///
/// **A file that does not parse is left alone.** Never repaired, never
/// overwritten. Sissy's line is not worth a byte of someone else's settings.
///
/// **The window between reading and writing is checked, not assumed.** Claude
/// Code rewrites `settings.json` itself and hot-reloads it, and its schema holds
/// `permissions.allow` — a lost update here could revert another tool's security
/// setting. The file is re-stat'd immediately before the rename and the write is
/// abandoned if anything moved; the next launch re-affirms.
///
/// What it cannot do is survive the user dragging Sissy to the Trash without
/// switching this off first. What stays behind is a guarded line that forks
/// `/bin/sh`, finds nothing at the path it names, and drains its input. That is
/// stated in the switch's own copy, because it is the part a user cannot undo
/// from inside Sissy.
struct AgentHookInstaller {
    /// Marks the entry as Sissy's across a path that changes — a moved install,
    /// a renamed home — so an entry can always be found again to update or
    /// remove, which exact-string matching would lose.
    static let marker = "# sissy-session-hook"
    static let scriptName = "session-start.sh"
    static let hooksDirectoryName = "hooks"
    static let backupsDirectoryName = "hook-backups"
    /// Longer than a `git rev-parse` needs by any margin, and short enough that
    /// a repository on a sleeping volume does not hold a session open.
    static let timeoutSeconds = 10
    private static let event = "SessionStart"
    private static let hooksKey = "hooks"
    private static let commandKey = "command"
    private static let typeKey = "type"
    private static let timeoutKey = "timeout"

    /// The account's own home, which is the only one that describes this user.
    static var userHome: URL? {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
            return nil
        }
        return URL(fileURLWithPath: String(cString: directory)).standardizedFileURL
    }

    static func targets(home: URL) -> [AgentHookTarget] {
        [
            AgentHookTarget(
                name: "Claude Code", url: home.appendingPathComponent(".claude/settings.json")),
            AgentHookTarget(name: "Codex", url: home.appendingPathComponent(".codex/hooks.json")),
        ]
    }

    let stateDirectory: URL
    let targets: [AgentHookTarget]
    private let fileManager: FileManager

    init(stateDirectory: URL, targets: [AgentHookTarget], fileManager: FileManager = .default) {
        self.stateDirectory = stateDirectory
        self.targets = targets
        self.fileManager = fileManager
    }

    var scriptURL: URL {
        stateDirectory
            .appendingPathComponent(Self.hooksDirectoryName)
            .appendingPathComponent(Self.scriptName)
    }

    var inboxURL: URL { ProjectLedger.inboxURL(in: stateDirectory) }

    private var backupsURL: URL {
        stateDirectory.appendingPathComponent(Self.backupsDirectoryName)
    }

    /// Lays down the script and the inbox, then claims one entry in each
    /// target. Idempotent: an entry that is already right is left alone, so an
    /// ordinary launch writes nothing at all.
    func install(bundledScript: URL) -> [AgentHookTarget: AgentHookOutcome] {
        do {
            try placeScript(from: bundledScript)
            try createDirectory(inboxURL)
        } catch {
            sissyLog("sissy: agent hooks: could not lay down the script: \(error)")
            return targets.reduce(into: [:]) { $0[$1] = .failed("\(error)") }
        }
        guard let command = shellCommand() else {
            sissyLog(
                "sissy: agent hooks: refusing to install — "
                    + "the hook path does not survive being quoted for a shell")
            return targets.reduce(into: [:]) { $0[$1] = .failed("unquotable path") }
        }
        let entry: [String: Any] = [
            Self.hooksKey: [
                [Self.typeKey: "command", Self.commandKey: command, Self.timeoutKey: Self.timeoutSeconds]
            ]
        ]
        return targets.reduce(into: [:]) { report, target in
            report[target] = edit(target) { groups in
                var kept = groups.filter { !Self.isSissys($0) }
                kept.append(entry)
                return kept
            }
        }
    }

    /// Takes the entry out of both files and removes everything the switch put
    /// on disk. The inbox goes too: it has already been folded into the ledger,
    /// and a directory whose only writer has just been unregistered is not data
    /// any more.
    func remove() -> [AgentHookTarget: AgentHookOutcome] {
        var report: [AgentHookTarget: AgentHookOutcome] = [:]
        for target in targets {
            report[target] = edit(target) { groups in groups.filter { !Self.isSissys($0) } }
        }
        for url in [scriptURL.deletingLastPathComponent(), backupsURL, inboxURL] {
            try? fileManager.removeItem(at: url)
        }
        return report
    }

    /// Whether both targets currently carry the entry this build would write.
    func isInstalled() -> Bool {
        guard let command = shellCommand() else { return false }
        return targets.allSatisfy { target in
            guard let groups = try? read(target.url)?.groups else { return false }
            return groups.contains { group in
                Self.commands(in: group).contains(command)
            }
        }
    }

    /// The line the CLIs run.
    ///
    /// `|| :` on the `then` branch is load-bearing: without it the status of a
    /// script that could not write — a full disk, a repository on a volume that
    /// is asleep — becomes a hook error shown to the user at every session
    /// start. The `else` branch drains stdin, because a hook that reads nothing
    /// can leave the caller waiting on a pipe.
    func shellCommand() -> String? {
        guard let quoted = Self.quoted(scriptURL.path) else { return nil }
        let command = """
            \(Self.marker)
            if [ -x \(quoted) ]; then /bin/sh \(quoted) || :; \
            else { cat >/dev/null 2>&1 || :; }; fi
            """
        return Self.isParsable(command) ? command : nil
    }

    /// A path as one `sh` word. Inside single quotes only the quote itself has
    /// any meaning, so closing, escaping and reopening is the whole of it — but
    /// a path is not required to be sane, and a newline in one would split the
    /// line the marker identifies.
    static func quoted(_ path: String) -> String? {
        guard !path.contains("\n"), !path.contains("\0") else { return nil }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Whether `sh` can parse what is about to be written into someone else's
    /// configuration. The quoting above is what makes this true; this is what
    /// proves it, and it runs only when a write is actually due.
    static func isParsable(_ command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        input.fileHandleForWriting.write(Data(command.utf8))
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func isSissys(_ group: [String: Any]) -> Bool {
        commands(in: group).contains { $0.contains(marker) }
    }

    private static func commands(in group: [String: Any]) -> [String] {
        (group[hooksKey] as? [[String: Any]] ?? []).compactMap { $0[commandKey] as? String }
    }

    private func placeScript(from bundled: URL) throws {
        try createDirectory(scriptURL.deletingLastPathComponent())
        let wanted = try Data(contentsOf: bundled)
        if let current = try? Data(contentsOf: scriptURL), current == wanted,
            (try? fileManager.attributesOfItem(atPath: scriptURL.path)[.posixPermissions]
                as? NSNumber)??.int16Value == 0o700
        {
            return
        }
        // Compared and rewritten on every launch rather than copied once: an
        // executable at a path two other programs are told to run is worth
        // owning outright, not leaving to whatever wrote it last.
        try? fileManager.removeItem(at: scriptURL)
        try wanted.write(to: scriptURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
    }

    private func createDirectory(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    private func read(_ url: URL) throws -> (root: [String: Any], groups: [[String: Any]])? {
        let resolved = url.resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: resolved.path) else { return ([:], []) }
        let data = try Data(contentsOf: resolved)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let hooks = root[Self.hooksKey] as? [String: Any] ?? [:]
        return (root, hooks[Self.event] as? [[String: Any]] ?? [])
    }

    private func edit(
        _ target: AgentHookTarget, _ transform: ([[String: Any]]) -> [[String: Any]]
    ) -> AgentHookOutcome {
        let resolved = target.url.resolvingSymlinksInPath()
        do {
            guard let (root, groups) = try read(target.url) else {
                sissyLog(
                    "sissy: agent hooks: \(target.name)'s configuration is not JSON this build "
                        + "can rewrite — left untouched")
                return .unreadable
            }
            let wanted = transform(groups)
            let existed = fileManager.fileExists(atPath: resolved.path)
            if Self.sameCommands(groups, wanted) && existed { return .unchanged }
            if wanted.isEmpty && !existed { return .unchanged }

            var hooks = root[Self.hooksKey] as? [String: Any] ?? [:]
            hooks[Self.event] = wanted.isEmpty ? nil : wanted
            var updated = root
            updated[Self.hooksKey] = hooks.isEmpty ? nil : hooks
            if existed { try backUp(resolved, of: target) }
            try write(updated, to: resolved, expecting: existed ? try identity(of: resolved) : nil)
            return wanted.contains(where: Self.isSissys) ? .written : .removed
        } catch {
            sissyLog("sissy: agent hooks: could not update \(target.name)'s configuration: \(error)")
            return .failed("\(error)")
        }
    }

    private static func sameCommands(_ lhs: [[String: Any]], _ rhs: [[String: Any]]) -> Bool {
        lhs.flatMap(commands(in:)) == rhs.flatMap(commands(in:))
    }

    /// Under Sissy's own directory, not beside the file it copies. A spare copy
    /// of someone's settings left in their own configuration folder is litter
    /// another tool may glob, and it outlives Sissy by definition.
    private func backUp(_ url: URL, of target: AgentHookTarget) throws {
        try createDirectory(backupsURL)
        let copy = backupsURL.appendingPathComponent(
            "\(url.deletingPathExtension().lastPathComponent)-\(target.name).json")
        guard !fileManager.fileExists(atPath: copy.path) else { return }
        try fileManager.copyItem(at: url, to: copy)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
    }

    private struct Identity: Equatable {
        let inode: UInt64
        let size: Int64
        let modified: Double
    }

    private func identity(of url: URL) throws -> Identity {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return Identity(
            inode: info.st_ino, size: info.st_size,
            modified: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
    }

    private func write(_ object: [String: Any], to url: URL, expecting: Identity?) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let mode =
            try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions]
            as? NSNumber
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).sissy-\(UUID().uuidString)")
        try data.write(to: staging, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: mode ?? NSNumber(value: 0o600)], ofItemAtPath: staging.path)
        if let expecting, (try? identity(of: url)) != expecting {
            try? fileManager.removeItem(at: staging)
            throw CocoaError(.fileWriteFileExists)
        }
        guard rename(staging.path, url.path) == 0 else {
            try? fileManager.removeItem(at: staging)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

extension AgentHookTarget: Hashable {}
