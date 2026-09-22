import XCTest

@testable import Sissy

/// Which processes on this Mac are an agent.
///
/// Driven through synthetic kernel rows rather than the real process table:
/// what is running while the suite runs is not something a test may assert on,
/// and the classification is the whole of what can go wrong.
final class AgentProcessClassificationTests: XCTestCase {
    private func process(_ path: String, pid: pid_t = 1) -> AgentProcessReader.KernelProcess {
        AgentProcessReader.KernelProcess(
            pid: pid, parent: 1, executablePath: path, startedAt: Date())
    }

    /// Claude Code's native build installs one executable per version and
    /// names it after the version, so the kernel's process name is `2.1.277`
    /// and only the path says what it is.
    func testTheNativeClaudeBuildIsFoundByItsPath() {
        let home = NSHomeDirectory()
        XCTAssertEqual(
            AgentProcessReader.classify(
                process(home + "/.local/share/claude/versions/2.1.277")),
            ProviderID.claudeCode)
    }

    func testAnExecutableNamedAfterTheCLICounts() {
        XCTAssertEqual(
            AgentProcessReader.classify(process("/opt/homebrew/bin/codex")), ProviderID.codex)
        XCTAssertEqual(
            AgentProcessReader.classify(process("/usr/local/bin/claude")),
            ProviderID.claudeCode)
    }

    /// The false positive the first cut of this shipped: a shell whose command
    /// line happens to mention a path under `~/.claude`.
    func testAShellThatMerelyMentionsTheCLIIsNotAnAgent() {
        XCTAssertNil(AgentProcessReader.classify(process("/opt/homebrew/bin/zsh")))
        XCTAssertNil(AgentProcessReader.classify(process("/usr/bin/git")))
        XCTAssertNil(AgentProcessReader.classify(process("")))
    }

    /// A reading of the real table, asserted on its invariants rather than on
    /// its contents: whatever is running, a tree cannot hold less than the
    /// process at its root and every row has to name a provider the panel can
    /// draw.
    /// Two worktrees of one checkout are one project, exactly as they are one
    /// project row, and a directory no `.git` was ever read from is named by
    /// nothing rather than by its path.
    func testAttributionNamesTheRepositoryAndRefusesToInventOne() {
        var reading = AgentProcessReading(
            observedAt: Date(),
            agents: [
                AgentProcess(
                    pid: 1, provider: ProviderID.claudeCode, footprint: 1, treeFootprint: 1,
                    startedAt: Date(), version: nil, directory: "/w/sissy/dace", project: nil),
                AgentProcess(
                    pid: 2, provider: ProviderID.claudeCode, footprint: 1, treeFootprint: 1,
                    startedAt: Date(), version: nil, directory: "/w/sissy/pickerel",
                    project: nil),
                AgentProcess(
                    pid: 3, provider: ProviderID.codex, footprint: 1, treeFootprint: 1,
                    startedAt: Date(), version: nil, directory: "/tmp/scratch", project: nil),
            ])
        reading.attributeProjects { $0.hasPrefix("/w/sissy") ? "/repos/sissy" : nil }
        XCTAssertEqual(reading.agents.map(\.project), ["/repos/sissy", "/repos/sissy", nil])
    }

    func testTheRealReadingIsInternallyConsistent() {
        let reading = AgentProcessReader.read()
        for agent in reading.agents {
            XCTAssertGreaterThanOrEqual(
                agent.treeFootprint, agent.footprint,
                "a process tree held less than the process at its root")
            XCTAssertTrue(
                [ProviderID.claudeCode, ProviderID.codex].contains(agent.provider),
                "an agent was classified as \(agent.provider), which no row draws")
            if let directory = agent.directory {
                XCTAssertTrue(
                    directory.hasPrefix("/"),
                    "a working directory came back as something other than a path")
            }
        }
        XCTAssertEqual(reading.footprint, reading.agents.reduce(0) { $0 + $1.footprint })
    }
}

/// A reading holding one agent of the given size, or none at zero.
private func reading(_ bytes: UInt64, at when: Date = Date()) -> AgentProcessReading {
    AgentProcessReading(
        observedAt: when,
        agents: bytes == 0
            ? []
            : [
                AgentProcess(
                    pid: 1, provider: ProviderID.claudeCode, footprint: bytes,
                    treeFootprint: bytes * 2, startedAt: when, version: nil,
                    directory: nil, project: nil)
            ])
}

/// The series behind the sparkline.
final class AgentProcessMonitorTests: XCTestCase {
    func testNoSweepYetIsNotAReadingOfNothing() async {
        let monitor = AgentProcessMonitor { _ in reading(0) }
        XCTAssertNil(monitor.currentMemory(), "a monitor that has not swept claimed a reading")
    }

    func testASweepPublishesTheReadingAndItsFirstSample() async {
        let monitor = AgentProcessMonitor { _ in reading(1024) }
        await monitor.sampleOnce {}
        let published = monitor.currentMemory()
        XCTAssertEqual(published?.current.footprint, 1024)
        XCTAssertEqual(published?.samples, [1024])
    }

    func testTheSeriesKeepsItsOrderOldestFirst() async {
        let counter = Counter()
        let monitor = AgentProcessMonitor { _ in reading(counter.next()) }
        for _ in 0..<3 { await monitor.sampleOnce {} }
        XCTAssertEqual(monitor.currentMemory()?.samples, [1, 2, 3])
    }

    /// The peak is what a single quiet moment must not undo.
    func testThePeakSurvivesADipInTheCurrentReading() async {
        let values: [UInt64] = [10, 900, 20]
        let counter = Counter(values)
        let monitor = AgentProcessMonitor { _ in reading(counter.next()) }
        for _ in values.indices { await monitor.sampleOnce {} }
        XCTAssertEqual(monitor.currentMemory()?.current.footprint, 20)
        XCTAssertEqual(monitor.currentMemory()?.peak, 900)
    }

    func testTheSeriesIsBounded() async {
        let monitor = AgentProcessMonitor { _ in reading(1) }
        for _ in 0..<(AgentProcessMonitor.retainedSamples + 20) { await monitor.sampleOnce {} }
        XCTAssertEqual(monitor.currentMemory()?.samples.count, AgentProcessMonitor.retainedSamples)
    }

    /// Two empty readings say the same thing, and rebuilding the frame for the
    /// second is work nobody asked for.
    func testAQuietMacCostsNoFrameAfterTheFirst() async {
        let monitor = AgentProcessMonitor { _ in reading(0) }
        let frames = Counter()
        await monitor.sampleOnce { frames.bump() }
        await monitor.sampleOnce { frames.bump() }
        XCTAssertEqual(frames.value, 1)
    }

    func testAnAgentAppearingIsWorthAFrame() async {
        let counter = Counter([0, 512])
        let monitor = AgentProcessMonitor { _ in reading(counter.next()) }
        let frames = Counter()
        await monitor.sampleOnce { frames.bump() }
        await monitor.sampleOnce { frames.bump() }
        XCTAssertEqual(frames.value, 2)
    }

    /// Nothing the monitor holds outlives it: a stopped monitor that kept its
    /// series would hand the next frame an hour of readings taken before the
    /// engine it belongs to was torn down.
    func testStoppingDropsTheSeries() async {
        let monitor = AgentProcessMonitor { _ in reading(1024) }
        await monitor.sampleOnce {}
        await monitor.stop()
        XCTAssertNil(monitor.currentMemory())
    }

    /// A process's counters run from its birth, so an agent already running
    /// at the first sweep brings none of its past in: the sums start when
    /// Sissy does, and only what each sweep adds is counted.
    func testTheSumsCountOnlyWhatEachSweepAdds() async {
        let started = Date(timeIntervalSince1970: 1_000)
        let cpu = Counter([100, 130, 175])
        let monitor = AgentProcessMonitor { now in
            let seconds = cpu.next()
            return AgentProcessReading(
                observedAt: now,
                agents: [
                    AgentProcess(
                        pid: 7, provider: ProviderID.claudeCode, footprint: 1, treeFootprint: 1,
                        startedAt: started, version: nil, directory: nil,
                        cpuTime: TimeInterval(seconds), energy: seconds * 1_000)
                ])
        }
        await monitor.sampleOnce {}
        XCTAssertEqual(monitor.currentMemory()?.cpuTime, 0)
        XCTAssertNil(monitor.currentMemory()?.current.agents.first?.cpuLoad)
        await monitor.sampleOnce {}
        await monitor.sampleOnce {}
        XCTAssertEqual(monitor.currentMemory()?.cpuTime, 75)
        XCTAssertEqual(monitor.currentMemory()?.energy, 75_000)
        XCTAssertNotNil(monitor.currentMemory()?.current.agents.first?.cpuLoad)
    }

    /// An agent that started after the sweep before was entirely inside the
    /// stretch being counted, so all of it counts.
    func testAnAgentStartedSinceTheLastSweepCountsWhole() async {
        let sweeps = Counter()
        let monitor = AgentProcessMonitor { now in
            guard sweeps.next() > 1 else { return AgentProcessReading(observedAt: now, agents: []) }
            return AgentProcessReading(
                observedAt: now,
                agents: [
                    AgentProcess(
                        pid: 9, provider: ProviderID.codex, footprint: 1, treeFootprint: 1,
                        startedAt: Date(), version: nil, directory: nil, cpuTime: 12,
                        energy: 500)
                ])
        }
        await monitor.sampleOnce {}
        await monitor.sampleOnce {}
        XCTAssertEqual(monitor.currentMemory()?.cpuTime, 12)
        XCTAssertEqual(monitor.currentMemory()?.energy, 500)
    }

    /// A pid the kernel hands to a new process is a new agent, not the old
    /// one's counters going backwards.
    func testAReusedPidDoesNotInheritItsPredecessor() async {
        let sweeps = Counter()
        let monitor = AgentProcessMonitor { now in
            let sweep = sweeps.next()
            return AgentProcessReading(
                observedAt: now,
                agents: [
                    AgentProcess(
                        pid: 4, provider: ProviderID.claudeCode, footprint: 1, treeFootprint: 1,
                        startedAt: sweep == 1 ? Date(timeIntervalSince1970: 1) : Date(),
                        version: nil, directory: nil, cpuTime: sweep == 1 ? 500 : 3)
                ])
        }
        await monitor.sampleOnce {}
        await monitor.sampleOnce {}
        XCTAssertEqual(monitor.currentMemory()?.cpuTime, 3)
        XCTAssertNil(monitor.currentMemory()?.current.agents.first?.cpuLoad)
    }

    /// The kernel's CPU times are mach ticks, and the raw uptime clock is the
    /// same ticks, so converting it must land on the nanosecond clock.
    func testMachTicksConvertToSeconds() {
        let ticks = mach_absolute_time()
        let uptime = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
        XCTAssertEqual(AgentProcessReader.seconds(machTicks: ticks), uptime, accuracy: 0.05)
    }

    /// The header says a recount is running while it runs, and dates the
    /// count once it has landed.
    func testTheHeaderSaysCountingUntilTheCountLands() {
        let now = Date()
        XCTAssertEqual(
            UsageFormat.agentsReading(observedAt: now, refreshing: true, now: now), "counting…")
        XCTAssertEqual(
            UsageFormat.agentsReading(
                observedAt: now.addingTimeInterval(-30), refreshing: false, now: now),
            "counted 30s ago")
        XCTAssertNil(UsageFormat.agentsReading(observedAt: nil, refreshing: false, now: now))
    }
}

/// A counter the injected reader can advance from a `@Sendable` closure.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]
    private var index = 0
    private(set) var value = 0

    init(_ values: [UInt64] = []) { self.values = values }

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        index += 1
        guard !values.isEmpty else { return UInt64(index) }
        return values[min(index - 1, values.count - 1)]
    }

    func bump() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }
}
