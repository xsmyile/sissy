import IOKit.pwr_mgt
import XCTest

@testable import Sissy

/// The hold is something the machine either has or does not, so these ask the
/// machine rather than the actor's own bookkeeping.
///
/// Counted against a baseline instead of tested for presence: these run in a
/// host process where another test's engine may already be holding assertions
/// under the same names, and a leak is a count that does not come back down.
final class KeepAwakeTests: XCTestCase {
    /// The names a user reads in `pmset -g assertions`, pinned here because
    /// that is the surface: renaming one is a visible change, not a refactor.
    private static let systemAssertionName = "Sissy is keeping this Mac awake"
    private static let displayAssertionName = "Sissy is keeping this screen on"

    private let keepAwake = KeepAwake()

    override func setUp() {
        super.setUp()
        let keepAwake = keepAwake
        addTeardownBlock { _ = await keepAwake.apply(holding: false, includingScreen: true) }
    }

    func testHoldingTakesTheSystemAndTheDisplayAssertion() async {
        let baseline = heldAssertionNames()

        let hold = await keepAwake.apply(holding: true, includingScreen: true)

        XCTAssertEqual(hold, KeepAwakeHold(system: true, screen: true))
        XCTAssertEqual(
            namesAdded(since: baseline),
            [Self.systemAssertionName, Self.displayAssertionName].sorted())
    }

    func testReleasingGivesBothBack() async {
        let baseline = heldAssertionNames()
        _ = await keepAwake.apply(holding: true, includingScreen: true)

        let hold = await keepAwake.apply(holding: false, includingScreen: true)

        XCTAssertEqual(hold, .none)
        XCTAssertEqual(namesAdded(since: baseline), [])
    }

    /// `UsageEngine.stop()` runs on every exit path, including the ones where
    /// the switch was never on, so releasing nothing has to be a no-op rather
    /// than a stray `IOPMAssertionRelease` on a zeroed id.
    func testReleasingWhatWasNeverHeldChangesNothing() async {
        let baseline = heldAssertionNames()

        let hold = await keepAwake.apply(holding: false, includingScreen: true)

        XCTAssertEqual(hold, .none)
        XCTAssertEqual(namesAdded(since: baseline), [])
    }

    /// `applyKeepAwake` re-runs on every config change the engine sees, so a
    /// hold that stacks would leak one pair per change and outlive the switch
    /// being turned off.
    func testHoldingTwiceStacksNothing() async {
        let baseline = heldAssertionNames()
        _ = await keepAwake.apply(holding: true, includingScreen: true)

        _ = await keepAwake.apply(holding: true, includingScreen: true)

        XCTAssertEqual(
            namesAdded(since: baseline),
            [Self.systemAssertionName, Self.displayAssertionName].sorted())
    }

    /// The system assertion is the hold and the display one is an addition to
    /// it, so switching the screen half off must leave a Mac that is still
    /// being kept awake — not a Mac free to idle behind a dimmed screen.
    func testHoldingWithoutTheScreenTakesTheSystemAssertionAlone() async {
        let baseline = heldAssertionNames()

        let hold = await keepAwake.apply(holding: true, includingScreen: false)

        XCTAssertEqual(hold, KeepAwakeHold(system: true, screen: false))
        XCTAssertEqual(namesAdded(since: baseline), [Self.systemAssertionName])
    }

    /// The setting is live: someone who switches the screen off while agents
    /// are running gets the display released under a hold that never lifts.
    func testDroppingTheScreenUnderARunningHoldKeepsTheMacAwake() async {
        let baseline = heldAssertionNames()
        _ = await keepAwake.apply(holding: true, includingScreen: true)

        let hold = await keepAwake.apply(holding: true, includingScreen: false)

        XCTAssertEqual(hold, KeepAwakeHold(system: true, screen: false))
        XCTAssertEqual(namesAdded(since: baseline), [Self.systemAssertionName])
    }

    /// And back, without the Mac blinking awake in between: the system
    /// assertion is never released to add the screen one.
    func testAddingTheScreenBackTakesTheDisplayAssertionAgain() async {
        let baseline = heldAssertionNames()
        _ = await keepAwake.apply(holding: true, includingScreen: false)

        let hold = await keepAwake.apply(holding: true, includingScreen: true)

        XCTAssertEqual(hold, KeepAwakeHold(system: true, screen: true))
        XCTAssertEqual(
            namesAdded(since: baseline),
            [Self.systemAssertionName, Self.displayAssertionName].sorted())
    }

    private func heldAssertionNames() -> [String] {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
            let assertions = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return [] }
        let pid = NSNumber(value: ProcessInfo.processInfo.processIdentifier)
        return (assertions[pid] ?? []).compactMap { $0[kIOPMAssertionNameKey] as? String }
    }

    private func namesAdded(since baseline: [String]) -> [String] {
        var unmatched = baseline
        var added: [String] = []
        for name in heldAssertionNames() {
            if let index = unmatched.firstIndex(of: name) {
                unmatched.remove(at: index)
            } else {
                added.append(name)
            }
        }
        return added.sorted()
    }
}
