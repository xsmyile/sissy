import XCTest

@testable import Sissy

final class PollLoopTests: XCTestCase {
    private func finished(_ task: Task<Void, Never>?) async throws {
        let task = try XCTUnwrap(task)
        await task.value
    }

    func testARunFirstLoopStepsWithoutWaiting() async {
        let waits = LockedValue<[Duration]>([])
        var steps = 0
        await PollLoop.run(
            wait: { delay in waits.update { $0.append(delay) } },
            step: {
                steps += 1
                return steps < 3 ? .seconds(7) : nil
            })
        XCTAssertEqual(steps, 3)
        XCTAssertEqual(waits.load(), [.seconds(7), .seconds(7)])
    }

    func testASleepFirstLoopWaitsBeforeItsFirstStep() async {
        let waits = LockedValue<[Duration]>([])
        await PollLoop.run(
            first: .seconds(5),
            wait: { delay in waits.update { $0.append(delay) } },
            step: {
                XCTAssertEqual(waits.load(), [.seconds(5)])
                return nil
            })
    }

    func testAWaitThatThrowsEndsTheLoop() async {
        var steps = 0
        await PollLoop.run(
            wait: { _ in throw CancellationError() },
            step: {
                steps += 1
                return .seconds(1)
            })
        XCTAssertEqual(steps, 1)
    }

    func testStartingARunningLoopIsANoOp() async throws {
        let steps = LockedValue(0)
        var loop = PollLoop()
        loop.start(first: .seconds(3600)) {
            steps.update { $0 += 1 }
            return nil
        }
        loop.start {
            steps.update { $0 += 1 }
            return nil
        }
        try await finished(loop.stop())
        XCTAssertEqual(steps.load(), 0)
        XCTAssertFalse(loop.isRunning)
    }

    func testStopEndsALoopInItsWait() async throws {
        var loop = PollLoop()
        loop.start(first: .seconds(3600)) { nil }
        XCTAssertTrue(loop.isRunning)
        try await finished(loop.stop())
    }

    func testStopRetiresTheStampsTakenBeforeIt() {
        var loop = PollLoop()
        let stamp = loop.generation
        XCTAssertTrue(loop.isCurrent(stamp))
        loop.stop()
        XCTAssertFalse(loop.isCurrent(stamp))
        XCTAssertTrue(loop.isCurrent(loop.generation))
    }

    func testAStampIsNotCurrentOnACancelledTask() async {
        let loop = PollLoop()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return loop.isCurrent(loop.generation)
        }
        let current = await task.value
        XCTAssertFalse(current)
    }

    /// The defect: both slept the whole idle delay, so a reading stayed stale up
    /// to 30 and 60 minutes after work resumed. A real wait running under each
    /// one's own pace is what `ForgeMonitorTests` holds for the slicing.
    func testStatusAndIdentityWaitsFollowTheClockTheyWereGiven() {
        let activity = ActivityClock()
        let status = ProviderStatusMonitor(providers: [], activity: activity)
        XCTAssertTrue(status.pacedWait.activity === activity)
        XCTAssertEqual(status.pacedWait.shortest, ProviderStatusMonitor.refreshInterval)
        let identity = GitIdentityMonitor(ledger: ProjectLedger(), activity: activity)
        XCTAssertTrue(identity.pacedWait.activity === activity)
        XCTAssertEqual(identity.pacedWait.shortest, GitIdentityMonitor.refreshInterval)
    }

    func testAnIdleWaitEndsOnceWorkResumesPartWayThrough() async throws {
        let activity = ActivityClock()
        let paced = ActivityPacedWait(
            activity: activity, shortest: .milliseconds(20), slice: .milliseconds(5))
        let ceiling = Duration.seconds(10)
        let started = ContinuousClock.now
        let waiting = Task { try await paced.wait(ceiling) }
        try await Task.sleep(for: .milliseconds(30))
        activity.note()
        try await waiting.value
        XCTAssertLessThan(ContinuousClock.now - started, ceiling / 2)
    }
}
