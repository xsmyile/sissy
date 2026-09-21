import XCTest

@testable import Sissy

/// The poll around the forge readers, what it publishes on a failure, and the
/// row that comes out the other side.
///
/// Nothing here reaches a network or a keychain: the monitor takes its fetch
/// and its token lookup as closures for the reason every other reader in this
/// app does, so the contract can be asserted without a credential.
final class ForgeMonitorTests: XCTestCase {
    private static let gitHub = ForgeConnection.gitHub()
    private static let gitLab = ForgeConnection(kind: .gitLab, host: "gitlab.example.com")
    private static let readAt = Date(timeIntervalSince1970: 1_789_600_000)

    private static func reading(
        _ connection: ForgeConnection, login: String, contributions: Int, merged: Int,
        at when: Date = readAt
    ) -> ForgeActivityReading {
        ForgeActivityReading(
            id: connection.id, kind: connection.kind, host: connection.host, login: login,
            activity: ForgeActivity(
                contributions: [.today: contributions], merged: [.today: merged], issues: [:],
                comments: [:],
                contributionsBoundedToOneYear: connection.kind == .gitHub),
            readAt: when, failure: nil)
    }

    // MARK: What a round publishes

    func testAGoodRoundPublishesOneRowPerConnectionInOrder() async {
        let monitor = ForgeActivityMonitor(
            connections: [Self.gitHub, Self.gitLab],
            fetch: { connection, _, _, _ in
                Self.reading(
                    connection, login: connection.kind == .gitHub ? "gh" : "gl",
                    contributions: 10, merged: 2)
            },
            token: { _, _ in .found("token") })
        _ = await monitor.refreshOnce {}
        let rows = monitor.currentReadings()
        XCTAssertEqual(rows.map(\.id), [Self.gitHub.id, Self.gitLab.id])
        XCTAssertEqual(rows.map(\.login), ["gh", "gl"])
    }

    /// A connection with no token gets a row saying so rather than no row: the
    /// user connected it, so the absence has to be visible where they look for
    /// the number.
    func testAConnectionWithNoTokenGetsARowWithAReason() async {
        let monitor = ForgeActivityMonitor(
            connections: [Self.gitHub],
            fetch: { connection, _, _, _ in Self.reading(connection, login: "gh", contributions: 1, merged: 0)
            },
            token: { _, _ in .absent })
        _ = await monitor.refreshOnce {}
        let row = monitor.currentReadings().first
        XCTAssertEqual(row?.failure, .noCredential)
        XCTAssertNil(row?.login)
        XCTAssertNil(row?.contributions(for: .today))
    }

    /// A keychain that would not hand over an item it *has* is not a missing
    /// token, and the difference is not cosmetic: the grant on Sissy's own item
    /// goes stale on every re-signed build, so reporting it as missing would
    /// park a connection that is working and leave no way back but re-pasting a
    /// token that was never the problem. It stays retryable, so the refusals
    /// that are transient clear themselves and the row keeps its figures.
    func testAStaleKeychainGrantIsRetryableRatherThanAMissingToken() async {
        let attempts = LockedValue(0)
        let monitor = ForgeActivityMonitor(
            connections: [Self.gitHub],
            fetch: { connection, _, _, _ in
                attempts.update { $0 += 1 }
                return Self.reading(connection, login: "gh", contributions: 1, merged: 0)
            },
            token: { _, _ in .interactionRequired })
        _ = await monitor.refreshOnce {}
        _ = await monitor.refreshOnce {}
        XCTAssertEqual(attempts.load(), 0)
        XCTAssertEqual(monitor.currentReadings().first?.failure, .credentialUnreadable)
        XCTAssertFalse(ForgeReadFailure.credentialUnreadable.needsTheUser)
    }

    /// **A round reads silently and the row's own refresh does not**, which is
    /// the whole of what makes the stale grant above recoverable.
    ///
    /// Both halves are load-bearing and they fail in opposite directions. A
    /// suppressed read can only ever be refused again, so a refresh that could
    /// not ask would leave the row reporting `credentialUnreadable` on every
    /// round for ever, with no cure but re-pasting a token that was never the
    /// problem. And a round that could ask would put the keychain's panel on
    /// screen every five minutes, unprompted, on a Mac nobody is touching.
    func testOnlyTheRowsOwnRefreshMayRaiseTheKeychainDialog() async {
        let asked = LockedValue([Bool]())
        let monitor = ForgeActivityMonitor(
            connections: [Self.gitHub],
            fetch: { connection, _, _, _ in
                Self.reading(connection, login: "gh", contributions: 1, merged: 0)
            },
            token: { _, allowingInteraction in
                asked.update { $0.append(allowingInteraction) }
                return .found("token")
            })
        _ = await monitor.refreshOnce {}
        await monitor.refreshOnce(id: Self.gitHub.id) {}
        XCTAssertEqual(asked.load(), [false, true])
    }

    /// A connection nothing was ever filed for is the one of these the user can
    /// act on, so that one stops costing a request every round.
    func testAGenuinelyMissingTokenParksTheConnection() async {
        let attempts = LockedValue(0)
        let monitor = ForgeActivityMonitor(
            connections: [Self.gitHub],
            fetch: { connection, _, _, _ in
                attempts.update { $0 += 1 }
                return Self.reading(connection, login: "gh", contributions: 1, merged: 0)
            },
            token: { _, _ in .absent })
        _ = await monitor.refreshOnce {}
        _ = await monitor.refreshOnce {}
        XCTAssertEqual(attempts.load(), 0)
        XCTAssertTrue(ForgeReadFailure.noCredential.needsTheUser)
    }

    /// The figures stay and so does their age. Figures that were true an hour
    /// ago plus how old they are is a better answer than an error where a
    /// number was — and republishing the round with a new stamp would date a
    /// reading nobody took.
    func testAFailureKeepsTheLastFiguresAndTheirAge() async {
        let outcome = LockedValue<Bool>(true)
        let monitor = ForgeActivityMonitor(
            connections: [Self.gitHub],
            fetch: { connection, _, _, _ in
                guard outcome.load() else { throw ForgeReadFailure.unreachable }
                return Self.reading(connection, login: "gh", contributions: 42, merged: 7)
            },
            token: { _, _ in .found("token") })
        _ = await monitor.refreshOnce {}
        outcome.store(false)
        _ = await monitor.refreshOnce {}
        let row = monitor.currentReadings().first
        XCTAssertEqual(row?.contributions(for: .today), 42)
        XCTAssertEqual(row?.merged(for: .today), 7)
        XCTAssertEqual(row?.failure, .unreachable)
        XCTAssertEqual(row?.readAt, Self.readAt)
    }

    /// A refused token cannot be fixed by asking again in five minutes, so the
    /// connection is parked and the next round spends no request on it.
    func testARefusedTokenParksTheConnectionUntilTheUserActs() async {
        let attempts = LockedValue(0)
        let monitor = ForgeActivityMonitor(
            connections: [Self.gitHub],
            fetch: { _, _, _, _ in
                attempts.update { $0 += 1 }
                throw ForgeReadFailure.unauthorized
            },
            token: { _, _ in .found("token") })
        _ = await monitor.refreshOnce {}
        _ = await monitor.refreshOnce {}
        _ = await monitor.refreshOnce {}
        XCTAssertEqual(attempts.load(), 1)
        XCTAssertEqual(monitor.currentReadings().first?.failure, .unauthorized)
    }

    /// One way back from a parked connection is connecting the host again,
    /// which builds a new monitor with nothing parked. The cadence never
    /// unparks on its own, and that is deliberate: a token the vendor refused
    /// cannot be un-refused by asking again on a timer. What can is the user,
    /// through the refresh on the row — which the tests below hold.
    func testAFreshMonitorHasNothingParked() async {
        let attempts = LockedValue(0)
        let refused = ForgeActivityMonitor(
            connections: [Self.gitHub],
            fetch: { _, _, _, _ in
                attempts.update { $0 += 1 }
                throw ForgeReadFailure.unauthorized
            },
            token: { _, _ in .found("token") })
        _ = await refused.refreshOnce {}
        _ = await refused.refreshOnce {}
        XCTAssertEqual(attempts.load(), 1)
        let replaced = ForgeActivityMonitor(
            connections: [Self.gitHub],
            fetch: { connection, _, _, _ in
                Self.reading(connection, login: "gh", contributions: 5, merged: 1)
            },
            token: { _, _ in .found("token") })
        _ = await replaced.refreshOnce {}
        XCTAssertEqual(replaced.currentReadings().first?.contributions(for: .today), 5)
        XCTAssertNil(replaced.currentReadings().first?.failure)
    }

    /// Stopping drops what was published, for the reason every reader in this
    /// app stops that way: the frame is rebuilt from this, so a cancelled loop
    /// would leave a count standing under a connection that is gone.
    func testStoppingDropsTheReadings() async {
        let monitor = ForgeActivityMonitor(
            connections: [Self.gitHub],
            fetch: { connection, _, _, _ in Self.reading(connection, login: "gh", contributions: 3, merged: 0)
            },
            token: { _, _ in .found("token") })
        _ = await monitor.refreshOnce {}
        XCTAssertFalse(monitor.currentReadings().isEmpty)
        await monitor.stop()
        XCTAssertTrue(monitor.currentReadings().isEmpty)
    }

    /// A round that republished the identical reading costs no frame.
    ///
    /// Identical is the whole of it, and in production that means a round that
    /// asked nothing — every connection parked, or a failure that kept the
    /// figures and the reason it already had. A round that reached the vendor
    /// always changes something, because `readAt` is part of a reading and the
    /// row prints it; the test below is that half.
    func testARoundThatRepublishesTheSameReadingAsksForNoFrame() async {
        let frames = LockedValue(0)
        let monitor = ForgeActivityMonitor(
            connections: [Self.gitHub],
            fetch: { connection, _, _, _ in Self.reading(connection, login: "gh", contributions: 9, merged: 4)
            },
            token: { _, _ in .found("token") })
        _ = await monitor.refreshOnce { frames.update { $0 += 1 } }
        _ = await monitor.refreshOnce { frames.update { $0 += 1 } }
        XCTAssertEqual(frames.load(), 1)
    }

    /// The same counts read at a new instant are a new reading, and the frame
    /// has to carry it: the age under the row is a reading of its own, so a
    /// poll that confirmed the figures still has something to say.
    func testTheSameCountsAtANewInstantAskForAFrame() async {
        let frames = LockedValue(0)
        let when = LockedValue(Self.readAt)
        let monitor = ForgeActivityMonitor(
            connections: [Self.gitHub],
            fetch: { connection, _, _, _ in
                Self.reading(connection, login: "gh", contributions: 9, merged: 4, at: when.load())
            },
            token: { _, _ in .found("token") })
        _ = await monitor.refreshOnce { frames.update { $0 += 1 } }
        when.store(Self.readAt.addingTimeInterval(300))
        _ = await monitor.refreshOnce { frames.update { $0 += 1 } }
        XCTAssertEqual(frames.load(), 2)
    }

    // MARK: When the next round is due

    private func idleMonitor() -> ForgeActivityMonitor {
        ForgeActivityMonitor(
            connections: [Self.gitHub],
            fetch: { connection, _, _, _ in
                Self.reading(connection, login: "gh", contributions: 1, merged: 0)
            },
            token: { _, _ in .found("token") })
    }

    private func at(hour: Int, _ calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: hour, minute: 50, second: 0, of: Self.readAt) ?? Self.readAt
    }

    /// **A wait never crosses local midnight.** Every window a reading carries
    /// is worked out from the instant it was asked for, so a round at 23:50
    /// answers `Today` for the day that is ending — and on the idle cadence
    /// that figure would stand under a heading naming the new day for the next
    /// half hour.
    func testAWaitNeverCrossesLocalMidnight() async {
        let calendar = Calendar.current
        let late = at(hour: 23, calendar)
        let midnight = calendar.date(
            byAdding: .day, value: 1, to: calendar.startOfDay(for: late))
        let remaining = Duration.seconds(
            (midnight ?? late).timeIntervalSince(late))
        let delay = await idleMonitor().nextDelay(from: late, calendar: calendar)
        XCTAssertLessThanOrEqual(delay, remaining)
        XCTAssertLessThan(delay, ForgeActivityMonitor.idleRefreshInterval)
        XCTAssertGreaterThanOrEqual(delay, ForgeActivityMonitor.shortestWait)
    }

    /// Away from the boundary the cap changes nothing, so the ordinary cadence
    /// is what it has always been.
    func testAWaitAwayFromMidnightIsTheOrdinaryInterval() async {
        let delay = await idleMonitor().nextDelay(from: at(hour: 12))
        XCTAssertGreaterThanOrEqual(delay, ForgeActivityMonitor.idleRefreshInterval)
    }

    /// **An idle wait ends early once agents are working.** The interval is
    /// chosen when the round finishes, and work that begins a minute later
    /// would otherwise keep the idle cadence for the rest of the wait — half
    /// an hour of it, over exactly the stretch the short cadence exists for.
    func testAnIdleWaitEndsEarlyOnceAgentsAreWorking() {
        let short = ForgeActivityMonitor.refreshInterval
        let idle = ForgeActivityMonitor.idleRefreshInterval
        XCTAssertFalse(
            ForgeActivityMonitor.waitIsOver(
                waited: short - .seconds(1), of: idle, working: true))
        XCTAssertTrue(ForgeActivityMonitor.waitIsOver(waited: short, of: idle, working: true))
    }

    /// With nobody working the wait runs its full length, so an idle Mac keeps
    /// costing one request every half hour and not one every five minutes.
    func testAWaitWithNobodyWorkingRunsItsFullLength() {
        let idle = ForgeActivityMonitor.idleRefreshInterval
        XCTAssertFalse(
            ForgeActivityMonitor.waitIsOver(waited: idle - .seconds(1), of: idle, working: false))
        XCTAssertTrue(ForgeActivityMonitor.waitIsOver(waited: idle, of: idle, working: false))
    }

    /// The frame path reports the work without awaiting this actor, and the
    /// next interval is picked from it.
    ///
    /// This is the interval chosen when a round *finishes*; that a wait already
    /// running is cut short is the test below.
    func testTheNextIntervalIsPickedFromWhatTheFramePathReported() async {
        let monitor = idleMonitor()
        XCTAssertFalse(monitor.isWorking())
        monitor.noteActivity()
        XCTAssertTrue(monitor.isWorking())
        let delay = await monitor.nextDelay(from: at(hour: 12))
        XCTAssertLessThan(delay, ForgeActivityMonitor.idleRefreshInterval)
    }

    /// **The wait itself ends early, not just the predicate that decides it.**
    /// The slicing loop is where a wrong clock or a wrong operand would live,
    /// and the predicate beside it cannot catch either — so this runs a real
    /// wait, in milliseconds rather than minutes, and holds that it comes back
    /// long before the ceiling it was given.
    func testAWaitInFlightEndsOnceAgentsAreWorking() async throws {
        let monitor = idleMonitor()
        monitor.noteActivity()
        let ceiling = Duration.seconds(10)
        let started = ContinuousClock.now
        try await monitor.wait(ceiling, slice: .milliseconds(5), shortest: .milliseconds(20))
        XCTAssertLessThan(ContinuousClock.now - started, ceiling / 2)
    }

    /// And it does run its length when nobody is working, so the slices are a
    /// way out rather than a shorter interval by the back door.
    func testAWaitInFlightRunsOnWithNobodyWorking() async throws {
        let monitor = idleMonitor()
        XCTAssertFalse(monitor.isWorking())
        let ceiling = Duration.milliseconds(120)
        let started = ContinuousClock.now
        try await monitor.wait(ceiling, slice: .milliseconds(5), shortest: .milliseconds(20))
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, ceiling)
    }

    // MARK: The refresh on a row

    /// How many times the pool is handed back before a blocked fetch is
    /// released, so an already-runnable second caller can reach the actor.
    private static let yieldsBeforeRelease = 50

    private func letTheOtherCallerIn() async {
        for _ in 0..<Self.yieldsBeforeRelease { await Task.yield() }
    }

    /// **The refresh reaches a connection the cadence has given up on.** That
    /// is the point of it: a token refused once is otherwise never asked again
    /// until the host is connected a second time, however transient the
    /// refusal was. A success lifts the parking, so the cadence has it back.
    func testARefreshReachesAParkedConnectionAndASuccessUnparksIt() async {
        let attempts = LockedValue(0)
        let refused = LockedValue(true)
        let frames = LockedValue(0)
        let monitor = ForgeActivityMonitor(
            connections: [Self.gitHub],
            fetch: { connection, _, _, _ in
                attempts.update { $0 += 1 }
                if refused.load() { throw ForgeReadFailure.unauthorized }
                return Self.reading(connection, login: "gh", contributions: 8, merged: 3)
            },
            token: { _, _ in .found("token") })
        _ = await monitor.refreshOnce {}
        _ = await monitor.refreshOnce {}
        XCTAssertEqual(attempts.load(), 1)

        refused.store(false)
        await monitor.refreshOnce(id: Self.gitHub.id) { frames.update { $0 += 1 } }
        XCTAssertEqual(attempts.load(), 2)
        XCTAssertEqual(frames.load(), 1)
        XCTAssertEqual(monitor.currentReadings().first?.contributions(for: .today), 8)

        _ = await monitor.refreshOnce {}
        XCTAssertEqual(attempts.load(), 3)
    }

    /// A refusal that still stands keeps the parking, so the click costs one
    /// request and the cadence goes on spending none.
    func testARefusalThatStillStandsKeepsTheConnectionParked() async {
        let attempts = LockedValue(0)
        let monitor = ForgeActivityMonitor(
            connections: [Self.gitHub],
            fetch: { _, _, _, _ in
                attempts.update { $0 += 1 }
                throw ForgeReadFailure.unauthorized
            },
            token: { _, _ in .found("token") })
        _ = await monitor.refreshOnce {}
        await monitor.refreshOnce(id: Self.gitHub.id) {}
        XCTAssertEqual(attempts.load(), 2)
        _ = await monitor.refreshOnce {}
        XCTAssertEqual(attempts.load(), 2)
    }

    /// A retryable failure on the refresh lifts the parking, because the answer
    /// the parking was for is not the answer the vendor just gave. Without it a
    /// click made off the VPN — this user's ordinary state — would strand the
    /// connection on the one reading nobody can act on.
    func testARetryableFailureOnARefreshLetsTheCadenceTryAgain() async {
        let attempts = LockedValue(0)
        let failure = LockedValue(ForgeReadFailure.unauthorized)
        let monitor = ForgeActivityMonitor(
            connections: [Self.gitHub],
            fetch: { _, _, _, _ in
                attempts.update { $0 += 1 }
                throw failure.load()
            },
            token: { _, _ in .found("token") })
        _ = await monitor.refreshOnce {}
        XCTAssertEqual(attempts.load(), 1)

        failure.store(.unreachable)
        await monitor.refreshOnce(id: Self.gitHub.id) {}
        XCTAssertEqual(attempts.load(), 2)

        _ = await monitor.refreshOnce {}
        XCTAssertEqual(attempts.load(), 3)
        XCTAssertEqual(monitor.currentReadings().first?.failure, .unreachable)
    }

    /// **A refresh that lands mid-round does not join it**, which is the one
    /// case that spends a second request on purpose.
    ///
    /// A scheduled read is suppressed and cannot raise the keychain's panel,
    /// so the click that is trying to clear a grant a re-signed build has
    /// staled would be answered with the very silence it exists to break —
    /// and the row would stay stuck under a gesture that looked like it
    /// worked. The window is not the microseconds a local lookup takes:
    /// `suppressingInteraction` serialises every keychain reader in the
    /// process on one lock, this round's own connections included, and waits
    /// out `suppressorTimeout` for it.
    ///
    /// **The round's own fetch still lands, and must not win by landing
    /// last**, which is what `seq` decides. Here it is released after the
    /// refresh that overtook it and carries different figures, so a monitor
    /// that published on arrival rather than on currency would put the older
    /// reading back over the one the user just watched arrive.
    ///
    /// Nothing outside the monitor can observe that the second caller is
    /// inside it, so the pool is yielded rather than slept on.
    func testARefreshMidRoundOpensItsOwnReadAndOutlivesTheRound() async {
        let round = FetchGate()
        let manual = FetchGate()
        let attempts = LockedValue(0)
        let monitor = ForgeActivityMonitor(
            connections: [Self.gitHub],
            fetch: { connection, _, _, _ in
                attempts.update { $0 += 1 }
                let first = attempts.load() == 1
                await (first ? round : manual).arrive()
                return Self.reading(
                    connection, login: "gh", contributions: first ? 11 : 22, merged: 2)
            },
            token: { _, _ in .found("token") })
        async let polled: Duration = monitor.refreshOnce {}
        await round.waitForStart()
        async let clicked: Void = monitor.refreshOnce(id: Self.gitHub.id) {}
        await manual.waitForStart()
        await manual.letGo()
        await clicked
        await round.letGo()
        _ = await polled
        XCTAssertEqual(attempts.load(), 2)
        XCTAssertEqual(monitor.currentReadings().first?.contributions(for: .today), 22)
    }

    /// **Two clicks still join**, because the rule is about what a caller may
    /// ask rather than about how many there are: a read already allowed to
    /// raise the panel answers the next caller that wants one.
    func testASecondClickJoinsTheRefreshAlreadyAsking() async {
        let gate = FetchGate()
        let attempts = LockedValue(0)
        let monitor = ForgeActivityMonitor(
            connections: [Self.gitHub],
            fetch: { connection, _, _, _ in
                attempts.update { $0 += 1 }
                await gate.arrive()
                return Self.reading(connection, login: "gh", contributions: 11, merged: 2)
            },
            token: { _, _ in .found("token") })
        async let first: Void = monitor.refreshOnce(id: Self.gitHub.id) {}
        await gate.waitForStart()
        async let second: Void = monitor.refreshOnce(id: Self.gitHub.id) {}
        await letTheOtherCallerIn()
        await gate.letGo()
        await first
        await second
        XCTAssertEqual(attempts.load(), 1)
        XCTAssertEqual(monitor.currentReadings().first?.contributions(for: .today), 11)
    }

    /// A fetch still in the air when the monitor is torn down cannot publish
    /// over the run that replaced it. The fetches are unstructured tasks, so
    /// cancelling the loop reaches none of them and the generation is what
    /// decides.
    func testAFetchThatLandsAfterAStopPublishesNothing() async {
        let gate = FetchGate()
        let monitor = ForgeActivityMonitor(
            connections: [Self.gitHub],
            fetch: { connection, _, _, _ in
                await gate.arrive()
                return Self.reading(connection, login: "gh", contributions: 5, merged: 1)
            },
            token: { _, _ in .found("token") })
        async let round: Duration = monitor.refreshOnce {}
        await gate.waitForStart()
        await monitor.stop()
        await gate.letGo()
        _ = await round
        XCTAssertTrue(monitor.currentReadings().isEmpty)
    }

    /// **A fetch torn down mid-flight deregisters nothing.** `stop()` empties
    /// the register itself, so one landing afterwards has nothing of its own
    /// left to take out — and taking out whatever it found would deregister
    /// the fetch that replaced it, leaving the next caller to open the second
    /// request the register exists to prevent.
    ///
    /// `stop()` is never followed by another read on the same instance today —
    /// the engine builds a fresh monitor — so this holds the type's own
    /// contract rather than a path a caller takes.
    func testAStaleFetchDoesNotDeregisterTheOneThatReplacedIt() async {
        let first = FetchGate()
        let second = FetchGate()
        let attempts = LockedValue(0)
        let monitor = ForgeActivityMonitor(
            connections: [Self.gitHub],
            fetch: { connection, _, _, _ in
                attempts.update { $0 += 1 }
                await (attempts.load() == 1 ? first : second).arrive()
                return Self.reading(connection, login: "gh", contributions: 6, merged: 1)
            },
            token: { _, _ in .found("token") })

        async let round: Duration = monitor.refreshOnce {}
        await first.waitForStart()
        await monitor.stop()

        async let replacement: Void = monitor.refreshOnce(id: Self.gitHub.id) {}
        await second.waitForStart()
        await first.letGo()
        _ = await round
        XCTAssertEqual(attempts.load(), 2)

        async let joiner: Void = monitor.refreshOnce(id: Self.gitHub.id) {}
        await letTheOtherCallerIn()
        XCTAssertEqual(attempts.load(), 2)

        await second.letGo()
        await replacement
        await joiner
    }

    /// A refresh for a connection this monitor was not built with is a no-op
    /// rather than a row: the connections are what it was constructed from, and
    /// a rebuild is what a change to them produces.
    func testARefreshForAnUnknownConnectionDoesNothing() async {
        let attempts = LockedValue(0)
        let monitor = ForgeActivityMonitor(
            connections: [Self.gitHub],
            fetch: { connection, _, _, _ in
                attempts.update { $0 += 1 }
                return Self.reading(connection, login: "gh", contributions: 1, merged: 0)
            },
            token: { _, _ in .found("token") })
        await monitor.refreshOnce(id: Self.gitLab.id) {}
        XCTAssertEqual(attempts.load(), 0)
        XCTAssertTrue(monitor.currentReadings().isEmpty)
    }
}

/// A fetch that says when it has started and blocks until it is let go, so a
/// test can hold two callers inside one request without sleeping on a guess.
private actor FetchGate {
    private var starts: [CheckedContinuation<Void, Never>] = []
    private var holds: [CheckedContinuation<Void, Never>] = []
    private var hasStarted = false
    private var released = false

    func arrive() async {
        hasStarted = true
        starts.forEach { $0.resume() }
        starts.removeAll()
        guard !released else { return }
        await withCheckedContinuation { holds.append($0) }
    }

    func waitForStart() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { starts.append($0) }
    }

    func letGo() {
        released = true
        holds.forEach { $0.resume() }
        holds.removeAll()
    }
}
