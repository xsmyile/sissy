import XCTest

@testable import Sissy

/// What the Overview's agents door and the stats page behind it say.
final class AgentStatsSnapshotTests: XCTestCase {
    private func memory(
        _ agents: [AgentProcess], samples: [UInt64] = [], since: Date = Date(),
        perAgent: [[AgentProcess.Key: AgentSample]]? = nil
    ) -> AgentMemoryReading {
        AgentMemoryReading(
            current: AgentProcessReading(observedAt: since, agents: agents),
            samples: samples,
            interval: 15,
            since: since,
            perAgent: perAgent
                ?? samples.map { _ in
                    Dictionary(
                        uniqueKeysWithValues: agents.map {
                            ($0.key, AgentSample(footprint: $0.footprint, cpuLoad: nil))
                        })
                })
    }

    private func agent(_ provider: String, bytes: UInt64, pid: pid_t = 1) -> AgentProcess {
        AgentProcess(
            pid: pid, provider: provider, footprint: bytes, treeFootprint: bytes * 2,
            startedAt: Date(), version: nil, directory: nil, project: nil)
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

    /// One sample is not a line, and a chart drawn through it would be a
    /// claim about a stretch that has not been measured yet.
    func testOneSampleDrawsNoChart() {
        let single = UsagePanelSnapshot.make(
            frame: frame(memory: memory([agent(ProviderID.codex, bytes: 512)], samples: [512])))
        XCTAssertNil(single.agents.live?.chart)
        let pair = UsagePanelSnapshot.make(
            frame: frame(
                memory: memory([agent(ProviderID.codex, bytes: 512)], samples: [512, 600])))
        XCTAssertEqual(pair.agents.live?.chart?.totals, [512, 600])
    }

    /// The bands stack in the list's order with the rest on top, and at every
    /// sample they add up to the total the single line used to draw, exited
    /// agents included.
    func testTheBandsFollowTheListAndReachTheTotal() throws {
        let running = agents(7)
        let exited = agent(ProviderID.codex, bytes: 40, pid: 99)
        let first = Dictionary(
            uniqueKeysWithValues: (running + [exited]).map {
                ($0.key, AgentSample(footprint: $0.footprint, cpuLoad: nil))
            })
        let second = Dictionary(
            uniqueKeysWithValues: running.map {
                ($0.key, AgentSample(footprint: $0.footprint, cpuLoad: 0.5))
            })
        let totals = [first, second].map { $0.values.reduce(0) { $0 + $1.footprint } }
        let chart = try XCTUnwrap(
            UsagePanelSnapshot.make(
                frame: frame(memory: memory(running, samples: totals, perAgent: [first, second]))
            ).agents.live?.chart)
        XCTAssertEqual(chart.bands.map(\.process), [1, 2, 3, 4, 5, nil])
        for index in totals.indices {
            XCTAssertEqual(chart.bands.reduce(0) { $0 + $1.values[index] }, totals[index])
        }
    }

    /// Every row the list draws has a band of its own colour, including the
    /// sixth one a list of exactly six keeps unfolded.
    func testEveryStandingRowHasItsOwnStep() {
        XCTAssertEqual(
            AgentMemoryChart.bandOpacities.count,
            UsagePanelSnapshot.AgentsBlock.Live.processRowLimit)
    }

    /// A lane starts where its agent did, and the chart marks that sample.
    func testALaneStartsWhereItsAgentDid() throws {
        let old = agent(ProviderID.claudeCode, bytes: 900, pid: 1)
        let new = agent(ProviderID.claudeCode, bytes: 100, pid: 2)
        let before = [old.key: AgentSample(footprint: 900, cpuLoad: 0.2)]
        let after = [
            old.key: AgentSample(footprint: 900, cpuLoad: 0.1),
            new.key: AgentSample(footprint: 100, cpuLoad: 0.9),
        ]
        let live = try XCTUnwrap(
            UsagePanelSnapshot.make(
                frame: frame(
                    memory: memory([old, new], samples: [900, 1_000], perAgent: [before, after]))
            ).agents.live)
        XCTAssertEqual(live.processes.first { $0.id == 2 }?.lane, [nil, 0.9])
        XCTAssertEqual(live.chart?.starts, [1])
        XCTAssertEqual(live.chart?.leaders(at: 1).map(\.process), [1, 2])
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
        )
        XCTAssertEqual(
            snapshot.agents.counted[.today]?.counts, AgentCounts(sessions: 57, agents: 18))
    }

    /// The defect this replaced: the rows under the figures came off the
    /// slices, which answer for today, so a thirty-day heading sat over
    /// today's numbers and the two never agreed.
    func testAWiderWindowIsCountedFromTheArchiveRowsIncluded() {
        let history: [UsagePeriod: UsageHistoryRollup] = [
            .sevenDays: UsageHistoryRollup(
                period: .sevenDays, earliestDay: Date(), tokens: 99, cost: 1,
                agents: AgentCounts(sessions: 300, agents: 120),
                agentsByProvider: [
                    ProviderID.claudeCode: AgentCounts(sessions: 250, agents: 100),
                    ProviderID.codex: AgentCounts(sessions: 50, agents: 20),
                ])
        ]
        let snapshot = UsagePanelSnapshot.make(
            frame: frame(
                providers: [
                    ProviderSlice(
                        id: ProviderID.claudeCode, tokens: 10, cost: 1,
                        agents: AgentCounts(sessions: 41, agents: 10))
                ],
                history: history))
        let week = snapshot.agents.counted[.sevenDays]
        XCTAssertEqual(week?.counts, AgentCounts(sessions: 300, agents: 120))
        XCTAssertEqual(
            week?.byProvider.first { $0.id == ProviderID.claudeCode }?.counts,
            AgentCounts(sessions: 250, agents: 100),
            "the row under a seven-day heading carried today's figure")
        XCTAssertEqual(
            week?.byProvider.map(\.counts).reduce(into: AgentCounts.none) { $0.add($1) },
            week?.counts,
            "the rows did not add up to the total above them")
    }

    /// The page offers only the windows there is something to show for.
    func testOnlyAnsweredWindowsAreOffered() {
        let snapshot = UsagePanelSnapshot.make(frame: frame())
        XCTAssertEqual(snapshot.agents.periods, [.today])
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
        let today = snapshot.agents.counted[.today]
        XCTAssertEqual(today?.byProvider.map(\.id), [ProviderID.codex])
        XCTAssertEqual(today?.byProvider.first?.running, 0)
        XCTAssertEqual(today?.byProvider.first?.counts.agents, 8)
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
            uniqueKeysWithValues: (snapshot.agents.counted[.today]?.byProvider ?? []).map {
                ($0.id, $0.running)
            })
        XCTAssertEqual(byProvider[ProviderID.claudeCode], 2)
        XCTAssertEqual(byProvider[ProviderID.codex], 1)
    }
    private func agents(_ count: Int) -> [AgentProcess] {
        (0..<count).map {
            agent(ProviderID.claudeCode, bytes: UInt64(1_000 * (count - $0)), pid: pid_t($0 + 1))
        }
    }

    /// A list at the limit is drawn whole: a fold standing for one row costs
    /// the row it hides.
    func testAListAtTheLimitIsNotFolded() {
        let live = UsagePanelSnapshot.make(
            frame: frame(
                memory: memory(agents(UsagePanelSnapshot.AgentsBlock.Live.processRowLimit)))
        ).agents.live
        XCTAssertEqual(live?.standingProcesses.count, 6)
        XCTAssertEqual(live?.foldedProcesses, [])
    }

    /// Past it, the dearest five stand and the rest fold, in order, so the
    /// fold's own figure is what the rows under the headline were missing.
    func testAListPastTheLimitFoldsAllButTheDearestFive() throws {
        let live = try XCTUnwrap(
            UsagePanelSnapshot.make(frame: frame(memory: memory(agents(8)))).agents.live)
        XCTAssertEqual(live.standingProcesses.map(\.id), [1, 2, 3, 4, 5])
        XCTAssertEqual(live.foldedProcesses.map(\.id), [6, 7, 8])
        XCTAssertEqual(
            (live.standingProcesses + live.foldedProcesses).reduce(0) { $0 + $1.footprint },
            live.footprint)
    }
}

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

    func testTheLoadIsWordedTheWayPsReadsIt() {
        XCTAssertEqual(UsageFormat.cpuDuration(42), "42s")
        XCTAssertEqual(UsageFormat.cpuDuration(1_129), "18m 49s")
        XCTAssertEqual(UsageFormat.cpuDuration(4_380), "1h 13m")
        XCTAssertEqual(UsageFormat.cpuLoad(0.964), "96%")
        XCTAssertEqual(UsageFormat.cpuLoad(2.5), "250%")
    }

    func testTheCountersCaptionSaysWhatAndSince() {
        let since = Date()
        XCTAssertEqual(
            UsageFormat.agentsLoad(cpu: 1_129, energy: 1_004_600_000_000, since: since),
            "CPU 18m 49s · 0.28 Wh " + UsageFormat.samplesSince(since))
    }

    /// The caption under the pointer names the time, the total and the two
    /// agents holding most of it, never more.
    func testTheInstantCaptionNamesTheTwoLeaders() {
        let instant = Date()
        let caption = UsageFormat.chartInstant(
            instant, total: 2_410_000_000,
            leaders: [("sissy", 612_000_000), ("legion", 540_000_000), ("orca", 90_000_000)])
        XCTAssertTrue(caption.hasSuffix(" · 2.41 GB · sissy 612 MB, legion 540 MB"), caption)
        XCTAssertEqual(UsageFormat.chartSpan(minutes: 60), "60m ago")
    }

    /// The fold carries what it hides, so the list still reaches its total.
    func testTheFoldSaysWhatItHolds() {
        XCTAssertEqual(UsageFormat.agentsFolded(3, footprint: 829_000_000), "3 more · 829 MB")
    }
}
