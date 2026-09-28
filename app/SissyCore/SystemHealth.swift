import Darwin
import Foundation

/// How hard the Mac is being pushed, in the kernel's own three steps.
///
/// The raw values are the kernel's, `kern.memorystatus_vm_pressure_level`
/// answering 1, 2 or 4, so the order they sort in is the order they escalate
/// in. The same three steps grade the disk, which is the one reading Sissy
/// grades itself: everything else on `MacHealthReading` is a number and never
/// a colour.
enum MacHealthLevel: Int, Sendable, Comparable, CaseIterable {
    case normal = 1
    case warn = 2
    case critical = 4

    /// The level the kernel reports, or nil for a value this build does not
    /// know: a fourth step would be a new reading rather than one of these
    /// three, and guessing which it is closest to would put a colour on a
    /// number nobody measured.
    init?(kernelPressure raw: Int32) {
        self.init(rawValue: Int(raw))
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// How many multiples of physical memory the home volume has to have free
    /// before it stops being a warning.
    ///
    /// In multiples of RAM rather than a percentage of the disk, because what
    /// eats the last of a disk on a struggling Mac is swap, and swap grows
    /// towards the size of RAM rather than towards the size of the volume.
    /// Measured 2026-09-27 on a Mac that froze with 24 GB of RAM: swap stood at
    /// 10 GB and 23 GB of the disk was free, where a 15% rule on its 460 GB
    /// volume would have warned at 69 GB free on the healthy days before it.
    static let diskWarnMultiple: UInt64 = 2
    /// Below this many multiples of RAM free, the disk may not hold the swap
    /// the kernel would want next.
    static let diskCriticalMultiple: UInt64 = 1

    /// The disk's level, from what is free on it against physical memory.
    static func disk(free: Int64, physicalMemory: UInt64) -> Self {
        let free = UInt64(max(free, 0))
        if free < physicalMemory * diskCriticalMultiple { return .critical }
        if free < physicalMemory * diskWarnMultiple { return .warn }
        return .normal
    }
}

/// Swap in use and swap the kernel has allocated, in bytes, from
/// `vm.swapusage`.
struct MacSwapUsage: Sendable, Equatable {
    let used: UInt64
    let total: UInt64

    init(used: UInt64, total: UInt64) {
        self.used = used
        self.total = total
    }

    init(_ usage: xsw_usage) {
        self.init(used: usage.xsu_used, total: usage.xsu_total)
    }
}

/// The run-queue averages `getloadavg` answers, over one, five and fifteen
/// minutes.
struct MacLoadAverage: Sendable, Equatable {
    let one: Double
    let five: Double
    let fifteen: Double
}

/// One app and everything it runs, with what they hold together.
struct MacAppFootprint: Sendable, Equatable, Identifiable {
    var id: String { path }
    /// The bundle's name without `.app`, or the executable's name for a
    /// process that lives in no bundle.
    let name: String
    /// What the processes were grouped by: the bundle's path, or the
    /// executable's for a process outside one.
    let path: String
    /// Physical footprint summed across the group, in bytes.
    let footprint: UInt64
}

/// The apps holding the most memory on this Mac besides the agents, as one
/// sweep of the process table found them.
struct MacHeaviestApps: Sendable, Equatable {
    /// When the sweep ran, which is the agent sweep's own moment and not the
    /// health sample that carries it.
    let observedAt: Date
    let apps: [MacAppFootprint]
}

/// What the Mac itself is answering right now, beside what the agents on it
/// are holding.
///
/// **The colour is the kernel's.** `pressure` is the kernel's own judgement
/// and the only other level is the disk's, graded against RAM on
/// `DiskReading`; swap, load and uptime are carried as numbers and graded by
/// nothing. Measured 2026-09-27 on the Mac that froze, load stood near 41 on
/// 12 cores and uptime at 10 days: both are real, and neither has a threshold
/// that is not a guess.
struct MacHealthReading: Sendable, Equatable {
    /// Sissy's clock at the sample, which is what every kernel figure below is
    /// dated by.
    let observedAt: Date
    /// The kernel's memory pressure, nil where the sysctl would not answer.
    let pressure: MacHealthLevel?
    /// The share of memory the kernel counts as free, `kern.memorystatus_level`.
    let freeMemoryPercent: Int?
    let swap: MacSwapUsage?
    let loadAverage: MacLoadAverage?
    let activeCores: Int
    /// Seconds since the Mac booted.
    let uptime: TimeInterval
    /// Nil until the agent sweep has run once with this module on.
    var heaviest: MacHeaviestApps?
}

/// Reads the Mac's own figures out of the kernel.
///
/// **Nothing here needs a permission**, on the terms `AgentProcessReader`
/// already holds to: every sysctl below answers an unprivileged process.
enum SystemHealthReader {
    /// Everything but the heaviest apps, which the agent sweep measures.
    /// Measured 2026-09-27, these sysctls together cost 3 µs.
    static func read(now: Date = Date()) -> MacHealthReading {
        let info = ProcessInfo.processInfo
        return MacHealthReading(
            observedAt: now,
            pressure: sysctlValue("kern.memorystatus_vm_pressure_level", as: Int32.self)
                .flatMap(MacHealthLevel.init(kernelPressure:)),
            freeMemoryPercent: sysctlValue("kern.memorystatus_level", as: Int32.self).map(Int.init),
            swap: sysctlValue("vm.swapusage", as: xsw_usage.self).map(MacSwapUsage.init),
            loadAverage: loadAverage(),
            activeCores: info.activeProcessorCount,
            uptime: info.systemUptime)
    }

    /// Swap in use, which the Disk tab reads beside the memory's own sample.
    static func swap() -> MacSwapUsage? {
        sysctlValue("vm.swapusage", as: xsw_usage.self).map(MacSwapUsage.init)
    }

    private static func loadAverage() -> MacLoadAverage? {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, Int32(loads.count)) == Int32(loads.count) else { return nil }
        return MacLoadAverage(one: loads[0], five: loads[1], fifteen: loads[2])
    }

    private static func sysctlValue<Value>(_ name: String, as _: Value.Type) -> Value? {
        let pointer = UnsafeMutablePointer<Value>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        var size = MemoryLayout<Value>.size
        guard sysctlbyname(name, pointer, &size, nil, 0) == 0, size == MemoryLayout<Value>.size
        else { return nil }
        return pointer.pointee
    }
}

/// Groups processes into the apps a user would recognise them as.
enum MacAppGrouping {
    /// How many apps a reading keeps.
    static let heaviestLimit = 3

    /// What a process counts towards: the path up to and including its first
    /// `.app` component, so a helper nested inside a bundle counts towards the
    /// bundle, or the executable itself for a process outside one.
    ///
    /// A scan of the UTF-8 bytes rather than a split into components or a
    /// Foundation search: measured 2026-09-27 across 1,248 paths, the split
    /// took 4.1 ms and `range(of:)` 3.3 ms, more than reading the process table
    /// costs, where the scan takes 1.0 ms.
    static func group(executablePath: String) -> (path: String, name: String) {
        guard let slash = bundleEnd(in: executablePath) else {
            return (executablePath, String(lastComponent(of: executablePath[...])))
        }
        let bundle = executablePath[..<slash]
        return (String(bundle), String(lastComponent(of: bundle).dropLast(appSuffix.count)))
    }

    private static func lastComponent(of path: Substring) -> Substring {
        path[(path.utf8.lastIndex(of: UInt8(ascii: "/")).map(path.index(after:)) ?? path.startIndex)...]
    }

    /// Where the first component ending in `.app` ends, which is the index of
    /// the slash after it.
    private static func bundleEnd(in path: String) -> String.Index? {
        let bytes = path.utf8
        var matched = 0
        var index = bytes.startIndex
        while index != bytes.endIndex {
            let byte = bytes[index]
            if byte == bundleMarker[matched] {
                matched += 1
            } else {
                matched = byte == bundleMarker[0] ? 1 : 0
            }
            if matched == bundleMarker.count { return index }
            index = bytes.index(after: index)
        }
        return nil
    }

    /// The heaviest apps among these processes, dearest first and by name
    /// between two that hold the same, so a tie does not trade places between
    /// sweeps. A process with no path is left out: it cannot be named.
    ///
    /// Summed by executable first, since a browser's dozens of helpers share
    /// a handful of paths and each path then needs grouping once.
    static func heaviest(
        _ processes: [(executablePath: String, footprint: UInt64)], limit: Int = heaviestLimit
    ) -> [MacAppFootprint] {
        var byExecutable: [String: UInt64] = [:]
        for process in processes where !process.executablePath.isEmpty {
            byExecutable[process.executablePath, default: 0] += process.footprint
        }
        var totals: [String: (name: String, footprint: UInt64)] = [:]
        for (path, footprint) in byExecutable {
            let owner = group(executablePath: path)
            totals[owner.path, default: (owner.name, 0)].footprint += footprint
        }
        let apps = totals.map {
            MacAppFootprint(name: $0.value.name, path: $0.key, footprint: $0.value.footprint)
        }
        return Array(
            apps.sorted {
                $0.footprint == $1.footprint ? $0.name < $1.name : $0.footprint > $1.footprint
            }
            .prefix(limit))
    }

    private static let appSuffix = ".app"
    private static let bundleMarker = Array((appSuffix + "/").utf8)
}
