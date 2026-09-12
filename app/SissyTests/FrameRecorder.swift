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
    private var matching: [(predicate: @Sendable (FrameData) -> Bool, expectation: XCTestExpectation)] =
        []

    func record(_ frame: FrameData) {
        lock.lock()
        frames.append(frame)
        let ready = pending.filter { $0.count <= frames.count }
        pending.removeAll { $0.count <= frames.count }
        let matched = matching.filter { $0.predicate(frame) }
        matching.removeAll { entry in matched.contains { $0.expectation === entry.expectation } }
        lock.unlock()
        ready.forEach { $0.expectation.fulfill() }
        matched.forEach { $0.expectation.fulfill() }
    }

    /// Waits for the next frame that says something, rather than for the next
    /// frame.
    ///
    /// A count cannot express "the frame where the hold let go": the tail
    /// emits on its own while the test waits, so whichever frame lands first
    /// satisfies a count and the assertions then run against a state that has
    /// not happened yet. Frames already recorded are deliberately not
    /// considered — every one of these waits for something to change.
    func expectation(
        _ description: String,
        forNextFrameMatching predicate: @escaping @Sendable (FrameData) -> Bool
    ) -> XCTestExpectation {
        let waiting = XCTestExpectation(description: description)
        lock.lock()
        matching.append((predicate, waiting))
        lock.unlock()
        return waiting
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
