import XCTest

@testable import Sissy

/// What the Overview's agent line and the stats page behind it say.
final class AgentStatsSnapshotTests: XCTestCase {
    private func memory(
        _ agents: [AgentProcess], samples: [UInt64] = [], since: Date = Date()
    ) -> AgentMemoryReading {
        AgentMemoryReading(
            current: AgentProcessReading(observedAt: since, agents: agents),
            samples: samples,
            interval: 15,
            since: since)
    }

    private func agent(_ provider: String, bytes: UInt64, pid: pid_t = 1) -> AgentProcess {
        AgentProcess(
            pid: pid, provider: provider, footprint: bytes, treeFootprint: bytes * 2,
            startedAt: Date(), version: nil)
    }

    private func frame(
        providers: [ProviderSlice] = [],
        history: [UsagePeriod: UsageHistoryRollup] = [:],
        memory: AgentMemoryReading? = nil
    ) -> FrameData {
        FrameData(
            tokens: 0, cost: 0, burn: nil, providers: providers, keepAwake: .off,
            history: history, agentMemory: memory)
    }

    /// The row is the only way to the page, so it has to say something before
    /// the first sweep lands rather than disappear until one does.
    func testTheRowSpeaksBeforeTheFirstSweep() {
        let snapshot = UsagePanelSnapshot.make(frame: frame())
        XCTAssertNil(snapshot.agents.live)
        XCTAssertEqual(snapshot.agents.summary, "no reading yet")
    }

    /// A sweep that found nothing is a measurement, and reads differently from
    /// never having measured.
    func testAQuietMacReadsAsMeasuredRatherThanUnmeasured() {
        let snapshot = UsagePanelSnapshot.make(frame: frame(memory: memory([])))
        XCTAssertNotNil(snapshot.agents.live)
        XCTAssertEqual(snapshot.agents.summary, "no agents running")
    }

    func testTheRowNamesTheCountAndWhatItHolds() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(
                memory: memory([
                    agent(ProviderID.claudeCode, bytes: 1_000_000_000, pid: 1),
                    agent(ProviderID.codex, bytes: 940_000_000, pid: 2),
                ])))
        XCTAssertEqual(snapshot.agents.summary, "2 agents · 1.94 GB")
    }

    /// One sample is not a line, and a sparkline drawn through it would be a
    /// claim about a stretch that has not been measured yet.
    func testOneSampleDrawsNoSparkline() {
        let single = UsagePanelSnapshot.make(
            frame: frame(memory: memory([agent(ProviderID.codex, bytes: 512)], samples: [512])))
        XCTAssertEqual(single.agents.live?.samples, [])
        let pair = UsagePanelSnapshot.make(
            frame: frame(
                memory: memory([agent(ProviderID.codex, bytes: 512)], samples: [512, 600])))
        XCTAssertEqual(pair.agents.live?.samples, [512, 600])
    }

    /// Today comes off the slices, never the archive: the archive's copy of
    /// today is written behind the tail's flush, so a count read from it would
    /// lag the cost beside it.
    func testTodayIsCountedFromTheSlices() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(
                providers: [
                    ProviderSlice(
                        id: ProviderID.claudeCode, tokens: 10, cost: 1,
                        agents: AgentCounts(sessions: 41, agents: 10)),
                    ProviderSlice(
                        id: ProviderID.codex, tokens: 5, cost: 1,
                        agents: AgentCounts(sessions: 16, agents: 8)),
                ]),
            period: .today)
        XCTAssertEqual(snapshot.agents.counted, AgentCounts(sessions: 57, agents: 18))
    }

    func testAWiderWindowIsCountedFromTheArchive() {
        let history: [UsagePeriod: UsageHistoryRollup] = [
            .sevenDays: UsageHistoryRollup(
                period: .sevenDays, earliestDay: Date(), tokens: 99, cost: 1,
                agents: AgentCounts(sessions: 300, agents: 120))
        ]
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(
                providers: [
                    ProviderSlice(
                        id: ProviderID.claudeCode, tokens: 10, cost: 1,
                        agents: AgentCounts(sessions: 41, agents: 10))
                ],
                history: history),
            period: .sevenDays)
        XCTAssertEqual(snapshot.agents.counted, AgentCounts(sessions: 300, agents: 120))
    }

    /// A provider keeps its row whether or not any of its processes is up:
    /// the counts are the day's and the running total is the moment's, and a
    /// row that vanished between turns would read as a CLI that stopped
    /// working.
    func testAProviderRowSurvivesHavingNothingRunning() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(
                providers: [
                    ProviderSlice(
                        id: ProviderID.codex, tokens: 5, cost: 1,
                        agents: AgentCounts(sessions: 16, agents: 8))
                ],
                memory: memory([])))
        XCTAssertEqual(snapshot.agents.byProvider.map(\.id), [ProviderID.codex])
        XCTAssertEqual(snapshot.agents.byProvider.first?.running, 0)
        XCTAssertEqual(snapshot.agents.byProvider.first?.counts.agents, 8)
    }

    func testTheRunningCountIsPerProvider() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(
                providers: [
                    ProviderSlice(id: ProviderID.claudeCode, tokens: 1, cost: 1),
                    ProviderSlice(id: ProviderID.codex, tokens: 1, cost: 1),
                ],
                memory: memory([
                    agent(ProviderID.claudeCode, bytes: 1, pid: 1),
                    agent(ProviderID.claudeCode, bytes: 1, pid: 2),
                    agent(ProviderID.codex, bytes: 1, pid: 3),
                ])))
        let byProvider = Dictionary(
            uniqueKeysWithValues: snapshot.agents.byProvider.map { ($0.id, $0.running) })
        XCTAssertEqual(byProvider[ProviderID.claudeCode], 2)
        XCTAssertEqual(byProvider[ProviderID.codex], 1)
    }
}

/// How the figures are worded.
final class AgentFormatTests: XCTestCase {
    /// Base ten, because this figure sits beside Activity Monitor's and macOS
    /// has counted in base ten since 10.6.
    func testBytesAreWordedTheWayTheSystemWordsThem() {
        XCTAssertEqual(UsageFormat.bytes(1_940_000_000), "1.94 GB")
        XCTAssertEqual(UsageFormat.bytes(308_000_000), "308 MB")
        XCTAssertEqual(UsageFormat.bytes(512_000), "512 KB")
    }

    func testOneAgentIsNotPluralised() {
        XCTAssertEqual(UsageFormat.agentsRunning(1, footprint: 1_000_000_000), "1 agent · 1.00 GB")
        XCTAssertEqual(
            UsageFormat.agentCount(1, singular: "session", plural: "sessions"), "1 session")
        XCTAssertEqual(
            UsageFormat.agentCount(0, singular: "session", plural: "sessions"), "0 sessions")
    }
}
