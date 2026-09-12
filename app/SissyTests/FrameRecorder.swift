import XCTest

@testable import Sissy

/// Collects what the engine emits and lets a test wait for the nth frame.
///
/// A frame arrives on whatever task the aggregator emits from, so the count and
/// the waiting are both behind a lock rather than on the test's own thread.
final class FrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [FrameData] = []
    private var pending: [(count: Int, expectation: XCTestExpectation)] = []

    func record(_ frame: FrameData) {
        lock.lock()
        frames.append(frame)
        let ready = pending.filter { $0.count <= frames.count }
        pending.removeAll { $0.count <= frames.count }
        lock.unlock()
        ready.forEach { $0.expectation.fulfill() }
    }

    func expectation(forFrameCount count: Int) -> XCTestExpectation {
        let waiting = XCTestExpectation(description: "frame \(count)")
        lock.lock()
        if frames.count >= count {
            lock.unlock()
            waiting.fulfill()
            return waiting
        }
        pending.append((count, waiting))
        lock.unlock()
        return waiting
    }

    var all: [FrameData] { lock.withLock { frames } }
    var count: Int { lock.withLock { frames.count } }
}
