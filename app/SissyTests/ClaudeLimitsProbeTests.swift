import XCTest

@testable import Sissy

/// Who is allowed to make macOS ask, and what a read that was not allowed to
/// does to the probe.
final class ClaudeLimitsProbeTests: XCTestCase {
    /// Records what each credential read was allowed to do, and lets a test
    /// wait for the nth read rather than for a duration.
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var interactive: [Bool] = []
        private var pending: [(count: Int, expectation: XCTestExpectation)] = []

        func record(_ allowingInteraction: Bool) {
            lock.lock()
            interactive.append(allowingInteraction)
            let ready = pending.filter { $0.count <= interactive.count }
            pending.removeAll { $0.count <= interactive.count }
            lock.unlock()
            ready.forEach { $0.expectation.fulfill() }
        }

        func expectation(forReadCount count: Int) -> XCTestExpectation {
            let waiting = XCTestExpectation(description: "read \(count)")
            lock.lock()
            if interactive.count >= count {
                lock.unlock()
                waiting.fulfill()
                return waiting
            }
            pending.append((count, waiting))
            lock.unlock()
            return waiting
        }

        var all: [Bool] { lock.withLock { interactive } }
        var count: Int { lock.withLock { interactive.count } }
    }

    private func makeProbe(
        _ reads: Reads,
        answering outcome: @escaping @Sendable () -> ClaudeCredentialsLookup
    ) -> ClaudeLimitsProbe {
        ClaudeLimitsProbe { _, allowingInteraction in
            reads.record(allowingInteraction)
            return outcome()
        }
    }

    /// The rule the whole issue is about: a launch that merely finds the
    /// setting already on must not put a dialog in front of someone who did
    /// not just ask for one.
    func testALaunchThatFindsTheSwitchOnNeverAsks() async {
        let reads = Reads()
        let probe = makeProbe(reads) { .interactionRequired }
        let first = reads.expectation(forReadCount: 1)

        await probe.start(userInitiated: false) {}
        await fulfillment(of: [first], timeout: 5)
        await probe.stop()

        XCTAssertEqual(reads.all, [false], "a launch asked macOS for permission")
    }

    /// And its other half: flipping the switch is a user action, and the one
    /// moment Sissy is allowed to ask.
    func testFlippingTheSwitchIsAllowedToAsk() async {
        let reads = Reads()
        let probe = makeProbe(reads) { .absent }
        let first = reads.expectation(forReadCount: 1)

        await probe.start(userInitiated: true) {}
        await fulfillment(of: [first], timeout: 5)
        await probe.stop()

        XCTAssertEqual(reads.all, [true], "the switch was not allowed to ask")
    }

    /// A silent miss is not a refusal, so the poll loop survives it: the grant
    /// can come back on its own — the CLI rewrites the item, the user allows
    /// it in Keychain Access — and a probe that stopped would need a relaunch
    /// to find out. Aliveness is read through `start` being idempotent: a
    /// second start finds the loop still holding the slot and does nothing.
    func testASilentMissLeavesTheProbeAlive() async {
        let reads = Reads()
        let probe = makeProbe(reads) { .interactionRequired }
        let first = reads.expectation(forReadCount: 1)
        await probe.start(userInitiated: false) {}
        await fulfillment(of: [first], timeout: 5)

        await probe.start(userInitiated: false) {}
        await probe.stop()

        XCTAssertEqual(reads.count, 1, "the probe had stopped and a second start restarted it")
    }

    /// A refusal is a person saying no, and re-asking them on a timer would be
    /// harassment — so that one does stop the loop, and a later start is what
    /// begins again.
    func testARefusalStopsTheProbe() async {
        let reads = Reads()
        let probe = makeProbe(reads) { .denied }
        let first = reads.expectation(forReadCount: 1)
        await probe.start(userInitiated: true) {}
        await fulfillment(of: [first], timeout: 5)

        let second = reads.expectation(forReadCount: 2)
        await probe.start(userInitiated: true) {}
        await fulfillment(of: [second], timeout: 5)
        await probe.stop()

        XCTAssertEqual(reads.all, [true, true], "a refusal left the poll loop running")
    }
}
