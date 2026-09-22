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
    /// The directory the process is working in, which is what answers "2 GB of
    /// what". Nil where the kernel would not say.
    ///
    /// The raw directory rather than a repository: resolving one is the
    /// `ProjectResolver`'s job and this type is a reading of the kernel. The
    /// monitor resolves it before the frame carries it, so a worktree counts
    /// against the checkout it was cut from exactly as a project row does.
    let directory: String?
    /// The repository that directory belongs to, once resolved. Nil for a
    /// directory no `.git` was ever read from — a CLI's own scratch area is
    /// not a project, and naming it after its path would be inventing one.
    var project: String?
    /// CPU the process itself has used since it started, in seconds.
    var cpuTime: TimeInterval = 0
    /// Energy the kernel has billed to the process since it started, in
    /// nanojoules.
    var energy: UInt64 = 0
    /// How many cores' worth of CPU the process used since the sweep before,
    /// which the monitor sets. Nil on the sweep that first sees it: one
    /// reading of a counter is a total, not a rate.
    var cpuLoad: Double?

    /// Who a process is across sweeps: its pid, and the start time that tells
    /// it apart from a later process the kernel hands the same pid to.
    struct Key: Hashable, Sendable {
        let pid: pid_t
        let startedAt: Date
    }

    var key: Key { Key(pid: pid, startedAt: startedAt) }
}

/// One agent at one sweep, as the per-agent series keeps it.
struct AgentSample: Sendable, Equatable {
    let footprint: UInt64
    let cpuLoad: Double?
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
    var agents: [AgentProcess]

    var footprint: UInt64 { agents.reduce(0) { $0 + $1.footprint } }
    var treeFootprint: UInt64 { agents.reduce(0) { $0 + $1.treeFootprint } }

    /// Nothing running, which is a reading and not an absence — the sweep ran
    /// and found no agent. The absence is having no reading at all, which the
    /// frame carries as `nil`.
    static let idle = Self(observedAt: .distantPast, agents: [])

    /// Names each agent's repository, leaving the directory where it was.
    ///
    /// Two agents in two worktrees of one repository resolve to the same name,
    /// which is the point: that is one project, exactly as it is one row on
    /// the Overview.
    mutating func attributeProjects(by resolve: (String) -> String?) {
        for index in agents.indices {
            agents[index].project = agents[index].directory.flatMap(resolve)
        }
    }
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
            let counters = usage(process.pid)
            let own = counters?.ri_phys_footprint ?? 0
            footprints[process.pid] = own
            agents.append(
                AgentProcess(
                    pid: process.pid,
                    provider: provider,
                    footprint: own,
                    treeFootprint: treeFootprint(
                        of: process.pid, childrenOf: childrenOf, cache: &footprints),
                    startedAt: process.startedAt,
                    version: version(of: process),
                    directory: workingDirectory(of: process.pid),
                    cpuTime: counters.map { seconds(machTicks: $0.ri_user_time + $0.ri_system_time) } ?? 0,
                    energy: counters?.ri_energy_nj ?? 0))
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

    /// Where a process is working.
    ///
    /// `PROC_PIDVNODEPATHINFO` answers for a process of this user with no
    /// permission and no prompt, exactly as the rest of this reader does —
    /// measured 2026-09-18, seven agents, zero refusals. Asked only for a
    /// process already classified as an agent: it is a syscall each, where
    /// everything above is one `sysctl` for the whole table.
    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let read = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, Int32(size))
        }
        guard read == Int32(size) else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        return path.isEmpty ? nil : path
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
        let bytes = usage(pid)?.ri_phys_footprint ?? 0
        cache[pid] = bytes
        return bytes
    }

    /// Everything the kernel accounts to one process, nil where it refused.
    ///
    /// The sixth revision rather than the fourth the footprint alone needs,
    /// because it is the first to carry `ri_energy_nj`, and it costs the same
    /// one syscall. It asks for no permission for a process of this user,
    /// measured 2026-09-22 across eight agents.
    private static func usage(_ pid: pid_t) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        return status == 0 ? info : nil
    }

    /// The kernel's CPU times in seconds.
    ///
    /// They are mach ticks, not nanoseconds, whatever the header's silence
    /// suggests: measured 2026-09-22 on Apple silicon, a timebase of 125/3,
    /// the raw figure read as nanoseconds said 1.50 s for a process `ps` put
    /// at 62.32 s, and converted through the timebase it said 62.32 s.
    static func seconds(machTicks ticks: UInt64) -> TimeInterval {
        Double(ticks) * timebaseRatio / nanosecondsPerSecond
    }

    private static let nanosecondsPerSecond: Double = 1_000_000_000

    private static let timebaseRatio: Double = {
        var base = mach_timebase_info_data_t()
        guard mach_timebase_info(&base) == KERN_SUCCESS, base.denom > 0 else { return 1 }
        return Double(base.numer) / Double(base.denom)
    }()

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
    /// How many processes the table is allowed to grow by between the call
    /// that sizes it and the call that fills it.
    ///
    /// The pair is not atomic: a process started in between makes the second
    /// `sysctl` answer `ENOMEM`, and the sweep would report a Mac with no
    /// agents on it — which is a reading, so it publishes, dents the series
    /// with a zero and blanks the row for a tick. Slack costs a few kilobytes
    /// and makes that need a burst rather than a single `fork`.
    private static let processTableSlack = 64
    /// How many times a sweep re-sizes and tries again before giving up. One:
    /// a table churning faster than that will churn again, and the sweep is
    /// due back in 15 s.
    private static let snapshotRetries = 1
    /// Buffer `proc_pidpath` wants, which its own header spells
    /// `PROC_PIDPATHINFO_MAXSIZE` — a macro, so Swift does not import it.
    /// `MAXPATHLEN` alone is the documented *minimum*, and a path longer than
    /// it makes the call fail, which would drop an agent from the reading
    /// rather than truncate its name.
    private static let executablePathBufferSize = 4 * Int(MAXPATHLEN)

    private static func snapshot() -> [KernelProcess] {
        guard let buffer = processTable() else { return [] }
        let uid = getuid()
        var pathBuffer = [CChar](repeating: 0, count: executablePathBufferSize)
        var out: [KernelProcess] = []
        for entry in buffer {
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

    /// The kernel's process table, sized and then read.
    ///
    /// Nil where it could not be read at all, which is different from an empty
    /// table and is why the caller does not treat it as a reading.
    private static func processTable() -> [kinfo_proc]? {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        for _ in 0...snapshotRetries {
            var size = 0
            guard sysctl(&name, 4, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            let stride = MemoryLayout<kinfo_proc>.stride
            var buffer = [kinfo_proc](
                repeating: kinfo_proc(), count: size / stride + processTableSlack)
            var read = buffer.count * stride
            guard sysctl(&name, 4, &buffer, &read, nil, 0) == 0 else { continue }
            return Array(buffer[0..<(read / stride)])
        }
        return nil
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
