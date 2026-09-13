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
}
