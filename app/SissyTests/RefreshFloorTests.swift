import XCTest

@testable import Sissy

/// The floor under how long "refreshing" stays on screen.
@MainActor
final class RefreshFloorTests: XCTestCase {

    /// A refresh that returns inside a frame — which is every Codex refresh,
    /// since it re-reads one JSON file — has to wait, or the word never
    /// paints and the click reads as a button that does nothing.
    func testWorkFasterThanTheFloorWaitsOutTheRest() {
        XCTAssertEqual(
            UsageEngineHost.remainingFloor(elapsed: .milliseconds(50)), .milliseconds(400))
    }

    /// A refresh that took longer than the floor owes nothing: the word has
    /// been on screen the whole time already.
    func testWorkSlowerThanTheFloorWaitsForNothing() {
        XCTAssertNil(UsageEngineHost.remainingFloor(elapsed: .seconds(3)))
    }

    /// The boundary lands on "no wait" rather than a zero-length sleep, so
    /// the caller has one shape for "done" instead of two.
    func testWorkExactlyTheFloorWaitsForNothing() {
        XCTAssertNil(UsageEngineHost.remainingFloor(elapsed: .milliseconds(450)))
    }

    /// A refresh a teardown cancelled finishes after the engine built next
    /// has started its own for the same id, and must leave that one's word
    /// and handle alone: clearing them stopped the new spinner early and
    /// let a second refresh for the id in.
    func testACancelledRefreshLeavesTheNextEnginesRefreshStanding() async {
        let host = UsageEngineHost()
        let first = Gate()
        let second = Gate()
        let stale = host.track("claude-code", in: .provider) { await first.wait() }
        host.cancelRefreshes()
        let current = host.track("claude-code", in: .provider) { await second.wait() }
        XCTAssertNotNil(current)

        await first.open()
        await stale?.value

        XCTAssertEqual(host.refreshing, ["claude-code"])
        XCTAssertNil(host.track("claude-code", in: .provider) {})
        await second.open()
        await current?.value
        XCTAssertEqual(host.refreshing, [])
    }
}

/// Holds a refresh's work open until the test lets it go, and ignores
/// cancellation the way an engine call already in flight does.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
