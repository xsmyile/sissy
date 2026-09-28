import Darwin
import Foundation

/// The tool that writes a `CleanupTarget`, which must not be at work while
/// the cache is emptied under it.
///
/// **Nothing guards these caches but the tool's own discipline**, so a removal
/// racing a build or an install would hand the tool a tree it half wrote and
/// half lost. uv is the one that says when it is at work: measured 2026-09-28
/// with uv 0.12.19, a running `uv` holds a shared `flock` on `.lock` in its
/// cache root, and an exclusive attempt without waiting fails at once with
/// errno 35. So its cleanup takes that lock and holds it, and a `uv`
/// started meanwhile waits for it. Xcode and npm keep no such lock, so their
/// caches are refused while one of their processes runs, read from the same
/// process table the Sessions tab reads and without spawning anything.
enum CleanupTool: String, Sendable, Equatable {
    case xcode
    case npm
    case uv

    var name: String {
        switch self {
        case .xcode: "Xcode"
        case .npm: "npm"
        case .uv: "uv"
        }
    }

    /// The executables that are this tool at work.
    ///
    /// Xcode's builds run in `SWBBuildService`, Swift Build's service, beside
    /// `xcodebuild` or the app, measured 2026-09-28 during an `xcodebuild`
    /// with Xcode 27; `XCBBuildService` is the name before Swift Build.
    var executables: Set<String> {
        switch self {
        case .xcode: ["Xcode", "xcodebuild", "SWBBuildService", "XCBBuildService"]
        case .npm: ["npm", "npx"]
        case .uv: ["uv", "uvx"]
        }
    }
}

extension CleanupTarget {
    var tool: CleanupTool {
        switch self {
        case .derivedData, .deviceSupport: .xcode
        case .npm: .npm
        case .uv: .uv
        }
    }
}

/// Which `CleanupTool`s this user is running, out of one pass over the
/// process table.
enum CleanupToolScan {
    /// The first word npm retitles its process with.
    ///
    /// npm runs under `node`, so the executable does not name it; it sets its
    /// title to its own command line, which lands in `argv[0]`: measured
    /// 2026-09-28, `npm install typescript@5` and `npm exec
    /// chrome-devtools-mcp@1.9.0` for the MCP servers `npx` starts.
    static let npmTitles: Set<String> = ["npm", "npx"]

    static func running() -> Set<CleanupTool> {
        let processes = AgentProcessReader.snapshot()
        let parents = Set(processes.map(\.parent))
        return Set(
            processes.compactMap {
                tool(of: $0, hasChildren: parents.contains($0.pid)) {
                    AgentProcessReader.firstArgument(of: $0)
                }
            })
    }

    /// The tool a process is, if any.
    ///
    /// An `npm exec` with a child is left out: that is `npx` running the
    /// package it installed, which reads the cache no more once the package
    /// starts, and the MCP servers an agent keeps open are exactly that, all
    /// day, so counting them would refuse the npm cache for as long as an
    /// agent runs.
    static func tool(
        of process: AgentProcessReader.KernelProcess, hasChildren: Bool,
        title: (pid_t) -> String?
    ) -> CleanupTool? {
        let name = (process.executablePath as NSString).lastPathComponent
        for tool in [CleanupTool.xcode, .npm, .uv] where tool.executables.contains(name) {
            return tool
        }
        guard AgentProcessReader.interpreters.contains(name), let title = title(process.pid) else {
            return nil
        }
        let words = title.split(separator: " ", maxSplits: 2).map(String.init)
        guard let first = words.first, npmTitles.contains(first) else { return nil }
        let wrapsAPackage = words.count > 1 && words[1] == "exec" && hasChildren
        return wrapsAPackage ? nil : .npm
    }
}

/// uv's own lock on its cache, held for as long as a cleanup runs.
struct CleanupToolLock {
    static let fileName = ".lock"

    private let descriptor: Int32

    enum Attempt {
        case held(CleanupToolLock)
        /// uv holds it: a `uv` is at work.
        case busy
        /// There is no lock file, so the lock says nothing either way.
        case absent
    }

    /// Takes the lock in the directory `root` is open on, without waiting,
    /// and never creating or following a link to the file.
    static func take(in root: Int32) -> Attempt {
        let descriptor = openat(root, fileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return .absent }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return .busy
        }
        return .held(Self(descriptor: descriptor))
    }

    func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
