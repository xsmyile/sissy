import Darwin
import Foundation

/// One agent process, as the kernel answers for it.
struct AgentProcess: Sendable, Equatable, Identifiable {
    var id: pid_t { pid }
    let pid: pid_t
    /// Which CLI this is, in the same vocabulary the provider rows use.
    let provider: String
    /// What the process itself holds, in bytes: the vendor's own measure of
    /// memory, which is the figure Activity Monitor shows.
    let footprint: UInt64
    /// What it holds together with everything it started — a build, a dev
    /// server, a language server — which is the larger and more alarming of
    /// the two readings, and a different question.
    let treeFootprint: UInt64
    /// When the process started, which is the only duration available here: a
    /// process says nothing about which of its minutes were spent working.
    let startedAt: Date
    /// The CLI's version where the install shape names it, which for Claude
    /// Code's native build is the executable's own name.
    let version: String?
}

/// What the agents on this Mac are holding right now.
///
/// **Two totals rather than one, because they differ by more than the number
/// itself.** Measured 2026-09-18 with eight agents running, the processes
/// themselves held 1.94 GB and the trees under them 4.88 GB. The first is what
/// the user can hand back by closing a session; the second is what the agents
/// have actually put on the Mac. Reporting either alone answers half.
struct AgentProcessReading: Sendable, Equatable {
    /// Sissy's own clock, never a stamp read off a process: this is the moment
    /// the sweep ran, and it is what the panel ages the reading from.
    let observedAt: Date
    let agents: [AgentProcess]

    var footprint: UInt64 { agents.reduce(0) { $0 + $1.footprint } }
    var treeFootprint: UInt64 { agents.reduce(0) { $0 + $1.treeFootprint } }

    /// Nothing running, which is a reading and not an absence — the sweep ran
    /// and found no agent. The absence is having no reading at all, which the
    /// frame carries as `nil`.
    static let idle = Self(observedAt: .distantPast, agents: [])
}

/// Reads the agent processes belonging to this user out of the kernel.
///
/// **Nothing here needs a permission.** `KERN_PROC_ALL`, `proc_pidpath` and
/// `proc_pid_rusage` all answer for a process running as the same user with no
/// entitlement, no TCC prompt and no hardened-runtime exception — measured
/// 2026-09-18 across 665 processes, zero refusals. Which is also the bound on
/// what this can see: another user's agents are none of Sissy's business and
/// the kernel agrees.
///
/// **The identity is the executable's path, not its name.** Claude Code's
/// native build runs from `~/.local/share/claude/versions/<version>`, so the
/// process name the kernel reports *is* the version string — measured, six
/// live sessions all answered `p_comm` of `2.1.276` or `2.1.277`. A matcher
/// keyed on the name finds none of them; one keyed on the path finds all of
/// them and gets the version for free.
enum AgentProcessReader {
    /// Where Claude Code's native build installs each version.
    static let claudeVersionsPath = "/.local/share/claude/versions/"
    /// Executable names that are the CLI itself rather than a host running it.
    static let executableNames: [String: String] = [
        "claude": ProviderID.claudeCode,
        "codex": ProviderID.codex,
    ]
    /// Interpreters an npm-style install runs the CLI under, where the
    /// executable path names the host and only `argv[0]` names the CLI.
    ///
    /// Read for these alone rather than for every process: `KERN_PROCARGS2` on
    /// all 665 processes costs 19.3 ms against the 1.2 ms this sweep otherwise
    /// takes, for a shape that a handful of processes can have.
    static let interpreters: Set<String> = ["node", "bun", "deno"]

    /// Everything this user is running that is an agent, with what each holds.
    static func read(now: Date = Date()) -> AgentProcessReading {
        let processes = snapshot()
        var childrenOf: [pid_t: [pid_t]] = [:]
        for process in processes { childrenOf[process.parent, default: []].append(process.pid) }
        var footprints: [pid_t: UInt64] = [:]
        var agents: [AgentProcess] = []
        for process in processes {
            guard let provider = classify(process) else { continue }
            let own = footprint(process.pid, cache: &footprints)
            agents.append(
                AgentProcess(
                    pid: process.pid,
                    provider: provider,
                    footprint: own,
                    treeFootprint: treeFootprint(
                        of: process.pid, childrenOf: childrenOf, cache: &footprints),
                    startedAt: process.startedAt,
                    version: version(of: process)))
        }
        return AgentProcessReading(
            observedAt: now, agents: agents.sorted { $0.footprint > $1.footprint })
    }

    /// Which CLI a process is, or nil for everything else on the Mac.
    static func classify(_ process: KernelProcess) -> String? {
        guard !process.executablePath.isEmpty else { return nil }
        if process.executablePath.contains(claudeVersionsPath) { return ProviderID.claudeCode }
        let name = (process.executablePath as NSString).lastPathComponent
        if let provider = executableNames[name] { return provider }
        guard interpreters.contains(name), let argv0 = firstArgument(of: process.pid) else {
            return nil
        }
        return executableNames[(argv0 as NSString).lastPathComponent]
    }

    /// The version an install shape happens to name, which is Claude Code's
    /// native build alone: it installs one executable per version and names it
    /// after the version.
    private static func version(of process: KernelProcess) -> String? {
        guard process.executablePath.contains(claudeVersionsPath) else { return nil }
        return (process.executablePath as NSString).lastPathComponent
    }

    /// One process and everything it started, counted once each.
    ///
    /// A `Set` of what has been visited rather than a plain walk, because a
    /// process whose parent has exited is reparented to `launchd` and a cycle
    /// in the table — which the kernel does not promise not to hand back —
    /// would otherwise not terminate.
    private static func treeFootprint(
        of root: pid_t, childrenOf: [pid_t: [pid_t]], cache: inout [pid_t: UInt64]
    ) -> UInt64 {
        var total: UInt64 = 0
        var seen: Set<pid_t> = [root]
        var queue: [pid_t] = [root]
        while let pid = queue.popLast() {
            total += footprint(pid, cache: &cache)
            for child in childrenOf[pid] ?? [] where seen.insert(child).inserted {
                queue.append(child)
            }
        }
        return total
    }

    /// The phys-footprint the kernel charges a process, cached within a sweep
    /// because an agent's tree overlaps its siblings' whenever two agents were
    /// started from the same shell.
    private static func footprint(_ pid: pid_t, cache: inout [pid_t: UInt64]) -> UInt64 {
        if let known = cache[pid] { return known }
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        let bytes = status == 0 ? info.ri_phys_footprint : 0
        cache[pid] = bytes
        return bytes
    }

    /// What the kernel says about one process, before anything is made of it.
    struct KernelProcess: Sendable, Equatable {
        let pid: pid_t
        let parent: pid_t
        let executablePath: String
        let startedAt: Date
    }

    /// Every process running as this user.
    ///
    /// The uid filter is not a nicety: `proc_pidpath` answers nothing for
    /// another user's process, so without it every root daemon costs a failed
    /// syscall per sweep to learn the same thing.
    private static func snapshot() -> [KernelProcess] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&name, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [kinfo_proc](
            repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        var read = size
        guard sysctl(&name, 4, &buffer, &read, nil, 0) == 0 else { return [] }
        let uid = getuid()
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var out: [KernelProcess] = []
        for entry in buffer[0..<(read / MemoryLayout<kinfo_proc>.stride)] {
            let pid = entry.kp_proc.p_pid
            guard pid > 0, entry.kp_eproc.e_ucred.cr_uid == uid else { continue }
            let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let started = entry.kp_proc.p_un.__p_starttime
            out.append(
                KernelProcess(
                    pid: pid,
                    parent: entry.kp_eproc.e_ppid,
                    executablePath: length > 0 ? String(cString: pathBuffer) : "",
                    startedAt: Date(
                        timeIntervalSince1970: Double(started.tv_sec)
                            + Double(started.tv_usec) / 1_000_000)))
        }
        return out
    }

    /// `argv[0]` of a process, which is the only place an interpreted install
    /// names the CLI it is running.
    ///
    /// The buffer holds `argc`, then the executable path, then the arguments,
    /// each NUL-terminated. Only the first argument is read: it is what the
    /// CLI sets its own name to, and the rest is a command line that may carry
    /// a prompt.
    private static func firstArgument(of pid: pid_t) -> String? {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&name, 3, nil, &size, nil, 0) == 0,
            size > MemoryLayout<Int32>.size
        else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var argument: [CChar] = []
        while index < size, buffer[index] != 0 {
            argument.append(buffer[index])
            index += 1
        }
        guard !argument.isEmpty else { return nil }
        return String(cString: argument + [0])
    }
}
