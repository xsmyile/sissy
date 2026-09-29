import XCTest

@testable import Sissy

/// What the watcher hands its handler, driven through `dispatch` so the order
/// is the test's rather than the kernel's coalescing.
final class FSWatcherTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-fswatcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Batches reach the handler in the order they were yielded and one at a
    /// time, even when the first is slow: a `rescanAll` batch must not land
    /// after the per-file batch that followed it.
    func testBatchesArriveInOrderAndOneAtATime() async throws {
        let seen = SeenBatches()
        let watcher = FSWatcher(label: "sissy.test.fswatcher.order")
        XCTAssertTrue(
            watcher.start(path: root, ignoreSelf: false) { event in
                await seen.handle(event)
            })
        addTeardownBlock { watcher.stop() }
        let names = (0..<5).map { "batch-\($0)" }

        for name in names {
            watcher.dispatch(
                FSWatcherEvent(
                    urls: [URL(fileURLWithPath: "/\(name)")], rescanAll: name == names[0],
                    rootChanged: false))
        }

        let deadline = ContinuousClock.now + .seconds(5)
        while await seen.names.count < names.count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let delivered = await seen.names
        let overlap = await seen.mostAtOnce
        XCTAssertEqual(delivered, names)
        XCTAssertEqual(overlap, 1, "two batches were handled at once")
    }
}

/// Records each batch's name and how many were in the handler at once, the
/// first one taking long enough for the rest to pile up behind it.
private actor SeenBatches {
    private(set) var names: [String] = []
    private(set) var mostAtOnce = 0
    private var inside = 0

    func handle(_ event: FSWatcherEvent) async {
        inside += 1
        mostAtOnce = max(mostAtOnce, inside)
        if names.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        names.append(contentsOf: event.urls.map(\.lastPathComponent))
        inside -= 1
    }
}
