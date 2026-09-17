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

    /// The state is what the panel acts on, so it has to name the outcome the
    /// probe actually met rather than collapsing every failure into "no
    /// limits". Driven through one poll rather than through the loop: the
    /// read is recorded before the outcome is classified, so an assertion
    /// hung off the read count passes or fails by luck — which is exactly how
    /// this shipped green locally and failed on CI.
    func testEachOutcomeTheUserCanActOnReachesTheFrame() async {
        let cases: [(ClaudeCredentialsLookup, ProviderLimitsState)] = [
            (.interactionRequired, .needsAuthorization),
            (.denied, .refused),
            (.absent, .signedOut),
        ]
        for (lookup, expected) in cases {
            let probe = ClaudeLimitsProbe { _, _ in lookup }

            _ = await probe.refreshOnce {}

            XCTAssertEqual(probe.currentSignals().limitsState, expected)
        }
    }

    /// A transient failure is not something to put on a row: the last reading
    /// stays up with its age, which is what the panel already does.
    func testAFailureNobodyCanActOnLeavesTheStateAlone() async {
        let probe = ClaudeLimitsProbe { _, _ in .denied }
        _ = await probe.refreshOnce {}
        XCTAssertEqual(probe.currentSignals().limitsState, .refused)

        let transient = ClaudeLimitsProbe { _, _ in .timedOut }
        _ = await transient.refreshOnce {}
        XCTAssertEqual(transient.currentSignals().limitsState, .quiet)
    }

    /// The bug this caught: a refusal stops the probe, and the stop used to
    /// clear the state it had just published — so the one thing offering a
    /// way back erased itself. The two stops are told apart by a parameter
    /// rather than by statement order, because they can interleave.
    func testARefusalSurvivesTheStopItTriggers() async {
        let probe = ClaudeLimitsProbe { _, _ in .denied }

        _ = await probe.refreshOnce {}

        XCTAssertEqual(probe.currentSignals().limitsState, .refused)
    }

    /// The other stop. A row explaining why the limits are missing, under a
    /// switch the user has just turned off, blames Sissy for obeying.
    func testSwitchingTheModuleOffClearsTheState() async {
        let probe = ClaudeLimitsProbe { _, _ in .interactionRequired }
        _ = await probe.refreshOnce {}
        XCTAssertEqual(probe.currentSignals().limitsState, .needsAuthorization)

        await probe.stop()

        XCTAssertEqual(probe.currentSignals().limitsState, .quiet)
    }

    /// The authorization the limits ride on lapses every time Claude Code
    /// refreshes its own token, and it lapses on a Mac that may not bill a
    /// single token afterwards. So the loss has to be published on its own:
    /// the poll used to notify only when the *windows* moved, which meant a
    /// probe that could no longer read the keychain sat silent until the next
    /// turn landed.
    func testAStateChangeIsPublishedWithoutAnyTokenEvent() async {
        let probe = ClaudeLimitsProbe { _, _ in .interactionRequired }
        let notified = expectation(description: "the authorization state reached the frame")

        _ = await probe.refreshOnce { notified.fulfill() }

        await fulfillment(of: [notified], timeout: 5)
        await probe.stop()
    }

    /// And its other half: a poll that met the same condition again publishes
    /// nothing, so a steady state costs no frames.
    func testTheSameStateTwiceIsNotPublishedTwice() async {
        let probe = ClaudeLimitsProbe { _, _ in .interactionRequired }
        let repeated = expectation(description: "the unchanged state was published again")
        repeated.isInverted = true
        _ = await probe.refreshOnce {}

        _ = await probe.refreshOnce { repeated.fulfill() }

        await fulfillment(of: [repeated], timeout: 0.5)
        await probe.stop()
    }

    /// A refresh is what the panel's spinner is hung off, so it has to end
    /// when Claude has answered rather than when the request was handed to a
    /// task. It used to return immediately: the spinner then ran out on its
    /// own minimum while the keychain and the network were still working, and
    /// the row went back to "updated" over a reading that had not arrived.
    func testARefreshIsPendingUntilTheRequestFinishes() async {
        let gate = Gate()
        let order = Order()
        let started = expectation(description: "the request began")
        let probe = ClaudeLimitsProbe { _, _ in
            .found(ClaudeCredentials(accessToken: "t", expiresAt: .distantFuture))
        } fetch: { _ in
            started.fulfill()
            await gate.wait()
            await order.requestFinished()
            return ClaudeLimitsProbe.Reading(windows: [], credits: nil)
        }
        let finished = expectation(description: "the refresh returned")
        Task {
            await probe.refresh {}
            await order.refreshReturned()
            finished.fulfill()
        }
        await fulfillment(of: [started], timeout: 5)

        await gate.open()
        await fulfillment(of: [finished], timeout: 5)

        let outran = await order.refreshOutranTheRequest
        XCTAssertFalse(outran, "the refresh reported done while the request was still running")
        await probe.stop()
    }

    /// A one-shot gate, so a test can hold a request open without blocking a
    /// thread the runtime needs to resume it.
    private actor Gate {
        private var waiting: CheckedContinuation<Void, Never>?
        private var opened = false

        func wait() async {
            guard !opened else { return }
            await withCheckedContinuation { waiting = $0 }
        }

        func open() {
            opened = true
            waiting?.resume()
            waiting = nil
        }
    }

    /// Which of the two finished first, recorded rather than timed: a test
    /// that waits a fixed moment to see whether something has happened yet
    /// passes on a loaded machine by luck.
    private actor Order {
        private var requestDone = false
        private(set) var refreshOutranTheRequest = false

        func requestFinished() { requestDone = true }
        func refreshReturned() { refreshOutranTheRequest = !requestDone }
    }

    /// The refresh exists because none of this was reachable from a running
    /// probe: `start` returns early while the poll task lives, so without its
    /// own entry point the second read never happened at all — let alone with
    /// the dialog allowed.
    func testARefreshReadsAgainAndIsAllowedToAsk() async {
        let reads = Reads()
        let probe = makeProbe(reads) { .interactionRequired }
        let first = reads.expectation(forReadCount: 1)
        await probe.start(userInitiated: false) {}
        await fulfillment(of: [first], timeout: 5)

        let second = reads.expectation(forReadCount: 2)
        await probe.refresh {}
        await fulfillment(of: [second], timeout: 5)

        XCTAssertEqual(Array(reads.all.prefix(2)), [false, true])
        await probe.stop()
    }

    /// The bug this caught: the probe held the credential until its own
    /// expiry, so a `/login` to another account left the windows of the one
    /// the user had just left standing under the name of the one they had
    /// joined — measured at eight hours, the life of a Claude Code access
    /// token, because a token that is merely the wrong account's still answers
    /// 200.
    ///
    /// Asserted on the windows rather than on the read count: a probe that
    /// re-reads and then publishes the first answer anyway is the same defect
    /// with a different cause.
    func testANewCredentialReplacesTheWindowsTheOldOneDrew() async {
        let token = LockedValue("first")
        let probe = ClaudeLimitsProbe(
            credentials: { _, _ in
                .found(ClaudeCredentials(accessToken: token.load(), expiresAt: .distantFuture))
            },
            fetch: { accessToken in
                ClaudeLimitsProbe.Reading(
                    windows: [
                        UsageWindow(
                            minutes: 300,
                            usedPercent: accessToken == "first" ? 10 : 20,
                            resetsAt: .distantFuture)!
                    ],
                    credits: nil)
            })

        _ = await probe.refreshOnce {}
        XCTAssertEqual(probe.currentSignals().windows.map(\.usedPercent), [10])

        token.update { $0 = "second" }
        _ = await probe.refreshOnce {}

        XCTAssertEqual(probe.currentSignals().windows.map(\.usedPercent), [20])
        await probe.stop()
    }

    /// The defect this caught, measured 2026-09-17: the endpoint had been
    /// answering 429 since 01:14, every poll published nothing, and by 07:00
    /// all three windows of the last good reading had rolled over. The panel
    /// said "awaiting a reading" — Codex's sentence for a source that cannot
    /// be re-read on demand — where the truth was that the vendor was
    /// refusing to give one.
    ///
    /// The windows stay: they are the last true reading and their age is what
    /// the row is for.
    func testABlockedVendorIsPublishedWithoutDroppingTheLastReading() async {
        let probe = rateLimitedProbe(retryAfter: 1684)

        _ = await probe.refreshOnce {}
        _ = await probe.refreshOnce {}

        guard case .rateLimited(let until) = probe.currentSignals().limitsState else {
            return XCTFail("a 429 left the row with nothing to say")
        }
        XCTAssertEqual(until.timeIntervalSinceNow, 1684, accuracy: 5)
        XCTAssertEqual(probe.currentSignals().windows.map(\.usedPercent), [10])
        await probe.stop()
    }

    /// The vendor's own `Retry-After` is what the panel promises and what the
    /// loop sleeps, so the two cannot disagree.
    func testTheBackoffTakesTheVendorsOwnFigure() async {
        let probe = rateLimitedProbe(retryAfter: 1684)
        _ = await probe.refreshOnce {}
        let delay = await probe.refreshOnce {}
        XCTAssertEqual(delay, .seconds(1684))
        await probe.stop()
    }

    /// Foreign input: a figure shorter than an ordinary poll is what earned
    /// the 429, and one longer than the ceiling is not worth trusting.
    func testTheRetryAfterHeaderIsClamped() {
        XCTAssertEqual(UsageRequestError.backoffSeconds(retryAfter: 0), 300)
        XCTAssertEqual(UsageRequestError.backoffSeconds(retryAfter: 5), 300)
        XCTAssertEqual(UsageRequestError.backoffSeconds(retryAfter: 86_400), 3600)
        XCTAssertEqual(UsageRequestError.backoffSeconds(retryAfter: nil), 1800)
        XCTAssertEqual(UsageRequestError.backoffSeconds(retryAfter: -1), 1800)
    }

    /// A request issued before the deadline the vendor named can only be
    /// refused again, and it is not free: measured 2026-09-17, the instant
    /// stood still across refusals 77 s apart and had moved 142 s further out
    /// 24 minutes later, which is a window that rolls over the requests made
    /// into it. So the button spends nothing, and the notice beside it
    /// already says when there would be something to spend it on.
    func testRefreshDoesNotSpendARequestTheVendorHasRefused() async {
        let fetches = LockedValue(0)
        let probe = rateLimitedProbe(retryAfter: 1684, counting: fetches)

        _ = await probe.refreshOnce {}
        _ = await probe.refreshOnce {}
        XCTAssertEqual(fetches.load(), 2)

        await probe.refresh {}

        XCTAssertEqual(fetches.load(), 2, "refresh hammered an endpoint that had said no")
        await probe.stop()
    }

    /// The gap this closed: the credential read at the top of every poll
    /// wrote `.quiet`, which is its answer for the states that are about the
    /// credential — and a vendor's block is not one. So for the length of the
    /// request that was about to be refused again the row had nothing on it,
    /// and any emit from the tail in that window drew a panel with no notice.
    ///
    /// Observed from inside the request, because that is the only place the
    /// gap exists.
    func testACredentialReadDoesNotLiftAVendorBlock() async {
        let probe = LockedValue<ClaudeLimitsProbe?>(nil)
        let duringRequest = LockedValue<ProviderLimitsState?>(nil)
        let built = ClaudeLimitsProbe(
            credentials: { _, _ in
                .found(ClaudeCredentials(accessToken: "token", expiresAt: .distantFuture))
            },
            fetch: { _ in
                duringRequest.store(probe.load()?.currentSignals().limitsState)
                throw UsageRequestError.rateLimited(retryAfter: 1684)
            })
        probe.store(built)

        _ = await built.refreshOnce {}
        _ = await built.refreshOnce {}

        guard case .rateLimited = duringRequest.load() else {
            return XCTFail("the credential read took the block off the row mid-request")
        }
        await built.stop()
    }

    /// A probe that answers one reading and then meets a vendor refusing to
    /// give another — the shape every assertion above is about.
    private func rateLimitedProbe(
        retryAfter: TimeInterval,
        counting fetches: LockedValue<Int> = LockedValue(0),
        backoff: LimitsBackoffSlot? = nil
    ) -> ClaudeLimitsProbe {
        ClaudeLimitsProbe(
            credentials: { _, _ in
                .found(ClaudeCredentials(accessToken: "token", expiresAt: .distantFuture))
            },
            fetch: { _ in
                var attempt = 0
                fetches.update {
                    $0 += 1
                    attempt = $0
                }
                guard attempt > 1 else {
                    return ClaudeLimitsProbe.Reading(
                        windows: [
                            UsageWindow(minutes: 300, usedPercent: 10, resetsAt: .distantFuture)!
                        ],
                        credits: nil)
                }
                throw UsageRequestError.rateLimited(retryAfter: retryAfter)
            },
            backoff: backoff)
    }

    /// A refusal is written down so the run after this one honours it.
    ///
    /// The deadline is the vendor's own, which is what makes the record worth
    /// keeping: a request made inside the block is refused again and moves it
    /// further out — measured 2026-09-17, from 08:26:44 to 09:30:24 across
    /// three restarts.
    func testAVendorRefusalIsRecordedForTheNextRun() async {
        let held = LockedValue<Date?>(nil)
        let probe = rateLimitedProbe(retryAfter: 1684, backoff: slot(held))

        _ = await probe.refreshOnce {}
        _ = await probe.refreshOnce {}

        XCTAssertEqual(held.load()?.timeIntervalSinceNow ?? 0, 1684, accuracy: 5)
        await probe.stop()
    }

    /// And the run after it waits rather than asking.
    ///
    /// The hole this closes: the state a 429 publishes lives in memory, so
    /// every relaunch — a login item, a provider switched off and on, a build
    /// — used to spend a request on a vendor that was still refusing.
    func testABlockRecordedOnAnEarlierRunCostsNoRequest() async {
        let held = LockedValue<Date?>(Date().addingTimeInterval(900))
        let fetches = LockedValue(0)
        let probe = succeedingProbe(backoff: slot(held), counting: fetches)

        let delay = await probe.refreshOnce {}

        XCTAssertEqual(fetches.load(), 0, "a rebuilt reader spent a request that was refused")
        guard case .rateLimited = probe.currentSignals().limitsState else {
            return XCTFail("the recorded block never reached the row")
        }
        XCTAssertEqual(Double(delay.components.seconds), 900, accuracy: 5)
        await probe.stop()
    }

    /// A reading answers the question the block stood in for, so the record
    /// goes with it rather than being left to expire on its own.
    func testAReadingTakesTheRecordedBlockOut() async {
        let held = LockedValue<Date?>(Date().addingTimeInterval(-1))
        let probe = succeedingProbe(backoff: slot(held))

        _ = await probe.refreshOnce {}

        XCTAssertNil(held.load())
        await probe.stop()
    }

    /// The account switch is the one event that makes a refusal stop being
    /// this reader's: the endpoint authenticates a credential, and the next
    /// request spends a different one. Without this the account switched *to*
    /// had no limits until a deadline its own token never met.
    func testAnAccountSwitchDropsTheRecordedBlock() async {
        let held = LockedValue<Date?>(Date().addingTimeInterval(900))
        let fetches = LockedValue(0)
        let probe = succeedingProbe(backoff: slot(held), counting: fetches)
        _ = await probe.refreshOnce {}
        XCTAssertEqual(fetches.load(), 0)

        await probe.clearBackoff()
        _ = await probe.refreshOnce {}

        XCTAssertEqual(fetches.load(), 1, "the new account was held to the old one's block")
        XCTAssertNil(held.load())
        XCTAssertEqual(probe.currentSignals().limitsState, .quiet)
        await probe.stop()
    }

    /// Reading the record is a suspension like any other, and a `stop()` can
    /// land in it: the switch has just cleared the row, and a block restored
    /// over that is a notice under a module the user turned off.
    ///
    /// Observed from inside the read, because that is the only place the gap
    /// exists.
    func testAStopDuringTheRecordReadDoesNotRestoreTheBlock() async {
        let probe = LockedValue<ClaudeLimitsProbe?>(nil)
        let built = succeedingProbe(
            backoff: LimitsBackoffSlot(
                deadline: {
                    await probe.load()?.stop()
                    return Date().addingTimeInterval(900)
                },
                record: { _ in }))
        probe.store(built)

        _ = await built.refreshOnce {}

        XCTAssertEqual(built.currentSignals().limitsState, .quiet)
    }

    /// A slot held in memory, which is the whole contract: a deadline that is
    /// still ahead, and somewhere to write the next one. Expired entries are
    /// filtered here exactly as the store filters them.
    private func slot(_ held: LockedValue<Date?>) -> LimitsBackoffSlot {
        LimitsBackoffSlot(
            deadline: { held.load().flatMap { $0 > Date() ? $0 : nil } },
            record: { held.store($0) })
    }

    /// A probe the vendor answers, so the assertion is whether the request
    /// happened at all.
    private func succeedingProbe(
        backoff: LimitsBackoffSlot?,
        counting fetches: LockedValue<Int> = LockedValue(0)
    ) -> ClaudeLimitsProbe {
        ClaudeLimitsProbe(
            credentials: { _, _ in
                .found(ClaudeCredentials(accessToken: "token", expiresAt: .distantFuture))
            },
            fetch: { _ in
                fetches.update { $0 += 1 }
                return ClaudeLimitsProbe.Reading(
                    windows: [
                        UsageWindow(minutes: 300, usedPercent: 10, resetsAt: .distantFuture)!
                    ],
                    credits: nil)
            },
            backoff: backoff)
    }
}
