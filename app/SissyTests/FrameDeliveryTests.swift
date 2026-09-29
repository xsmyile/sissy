import XCTest

@testable import Sissy

/// The rules frames reach the app under: never an older reading after a newer
/// one, never out of order, never a backlog, the newest always, and nothing
/// once the engine has stopped. Frames are plain integers here, each one its
/// own revision unless a test says otherwise.
final class FrameDeliveryTests: XCTestCase {
    func testAnOvertakenFrameIsRefused() async {
        let sent = SentFrames()
        let delivery = FrameDelivery<Int> { await sent.record($0) }

        let newer = await delivery.deliver(2, revision: 2)
        let older = await delivery.deliver(1, revision: 1)

        XCTAssertEqual(newer, .delivered)
        XCTAssertEqual(older, .overtaken)
        let frames = await sent.frames
        XCTAssertEqual(frames, [2])
    }

    /// Two frames built from one reading both go out, because the second is
    /// what carries a monitor's news.
    func testTheSameRevisionIsDeliveredAgain() async {
        let sent = SentFrames()
        let delivery = FrameDelivery<Int> { await sent.record($0) }

        _ = await delivery.deliver(10, revision: 1)
        let again = await delivery.deliver(11, revision: 1)

        XCTAssertEqual(again, .delivered)
        let frames = await sent.frames
        XCTAssertEqual(frames, [10, 11])
    }

    /// While the app is still taking the first frame, the ones behind it
    /// coalesce into the newest: it goes out next, after the first and never
    /// before it, and every caller has returned by then.
    func testFramesBehindASlowOneCoalesceIntoTheNewest() async throws {
        let sent = SentFrames(holdingFirst: true)
        let delivery = FrameDelivery<Int> { await sent.record($0) }

        let first = Task { await delivery.deliver(1, revision: 1) }
        await sent.waitUntilHolding()
        var queued: [Task<FrameDelivery<Int>.Outcome, Never>] = []
        for frame in 2...4 {
            queued.append(Task { await delivery.deliver(frame, revision: frame) })
            try await waitUntil { await delivery.waiting == frame }
        }
        await sent.release()

        let firstOutcome = await first.value
        var outcomes: [FrameDelivery<Int>.Outcome] = []
        for task in queued { outcomes.append(await task.value) }

        XCTAssertEqual(firstOutcome, .delivered)
        XCTAssertEqual(outcomes, [.delivered, .delivered, .delivered])
        let frames = await sent.frames
        XCTAssertEqual(frames, [1, 4], "the frames behind the slow one did not coalesce into the newest")
    }

    /// Whatever order the rebuilds arrive in, the app ends on the newest one:
    /// a frame is only ever dropped for one already handed over.
    func testTheNewestFrameAlwaysReachesTheApp() async {
        let sent = SentFrames()
        let delivery = FrameDelivery<Int> { await sent.record($0) }

        await withTaskGroup(of: Void.self) { group in
            for frame in (1...50).shuffled() {
                group.addTask { _ = await delivery.deliver(frame, revision: frame) }
            }
        }

        let frames = await sent.frames
        XCTAssertEqual(frames.last, 50)
        XCTAssertEqual(frames, frames.sorted(), "an older frame reached the app after a newer one")
    }

    func testNothingIsDeliveredAfterStop() async {
        let sent = SentFrames()
        let delivery = FrameDelivery<Int> { await sent.record($0) }

        await delivery.stop()
        let outcome = await delivery.deliver(1, revision: 1)

        XCTAssertEqual(outcome, .stopped)
        let frames = await sent.frames
        XCTAssertEqual(frames, [])
    }

    /// A frame still waiting behind a slow one when the engine stops is
    /// dropped rather than handed to an app that was told metering is over.
    func testAFrameWaitingAtStopIsDropped() async throws {
        let sent = SentFrames(holdingFirst: true)
        let delivery = FrameDelivery<Int> { await sent.record($0) }

        let first = Task { await delivery.deliver(1, revision: 1) }
        await sent.waitUntilHolding()
        let waiting = Task { await delivery.deliver(2, revision: 2) }
        try await waitUntil { await delivery.waiting == 2 }
        await delivery.stop()
        await sent.release()

        let firstOutcome = await first.value
        let waitingOutcome = await waiting.value
        XCTAssertEqual(firstOutcome, .stopped)
        XCTAssertEqual(waitingOutcome, .stopped)
        let frames = await sent.frames
        XCTAssertEqual(frames, [1])
    }

    private func waitUntil(
        timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw WaitTimedOut() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private struct WaitTimedOut: Error {}
}

/// What reached the app, optionally holding the first frame until released,
/// which is the slow consumer the coalescing is for.
private actor SentFrames {
    private(set) var frames: [Int] = []
    private var holdsFirst: Bool
    private var holding: CheckedContinuation<Void, Never>?
    private var holdingWaiters: [CheckedContinuation<Void, Never>] = []

    init(holdingFirst: Bool = false) {
        holdsFirst = holdingFirst
    }

    func record(_ frame: Int) async {
        frames.append(frame)
        guard holdsFirst else { return }
        holdsFirst = false
        await withCheckedContinuation { continuation in
            holding = continuation
            holdingWaiters.forEach { $0.resume() }
            holdingWaiters.removeAll()
        }
    }

    func waitUntilHolding() async {
        guard holding == nil else { return }
        await withCheckedContinuation { holdingWaiters.append($0) }
    }

    func release() {
        holding?.resume()
        holding = nil
    }
}
