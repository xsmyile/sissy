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
            token: { _ in .found("token") })
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
            token: { _ in .absent })
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
    /// token that was never the problem. It stays retryable, so the poll picks
    /// the account back up on its own.
    func testAStaleKeychainGrantIsRetryableRatherThanAMissingToken() async {
        let attempts = LockedValue(0)
        let monitor = ForgeActivityMonitor(
            connections: [Self.gitHub],
            fetch: { connection, _, _, _ in
                attempts.update { $0 += 1 }
                return Self.reading(connection, login: "gh", contributions: 1, merged: 0)
            },
            token: { _ in .interactionRequired })
        _ = await monitor.refreshOnce {}
        _ = await monitor.refreshOnce {}
        XCTAssertEqual(attempts.load(), 0)
        XCTAssertEqual(monitor.currentReadings().first?.failure, .credentialUnreadable)
        XCTAssertFalse(ForgeReadFailure.credentialUnreadable.needsTheUser)
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
            token: { _ in .absent })
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
            token: { _ in .found("token") })
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
            token: { _ in .found("token") })
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
            token: { _ in .found("token") })
        _ = await refused.refreshOnce {}
        _ = await refused.refreshOnce {}
        XCTAssertEqual(attempts.load(), 1)
        let replaced = ForgeActivityMonitor(
            connections: [Self.gitHub],
            fetch: { connection, _, _, _ in
                Self.reading(connection, login: "gh", contributions: 5, merged: 1)
            },
            token: { _ in .found("token") })
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
            token: { _ in .found("token") })
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
            token: { _ in .found("token") })
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
            token: { _ in .found("token") })
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
            token: { _ in .found("token") })
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
        let remaining = Duration.seconds((midnight ?? late).timeIntervalSince(late))
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
            token: { _ in .found("token") })
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
            token: { _ in .found("token") })
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
            token: { _ in .found("token") })
        _ = await monitor.refreshOnce {}
        XCTAssertEqual(attempts.load(), 1)

        failure.store(.unreachable)
        await monitor.refreshOnce(id: Self.gitHub.id) {}
        XCTAssertEqual(attempts.load(), 2)

        _ = await monitor.refreshOnce {}
        XCTAssertEqual(attempts.load(), 3)
        XCTAssertEqual(monitor.currentReadings().first?.failure, .unreachable)
    }

    /// **A refresh that lands mid-round joins it rather than asking twice.**
    /// Two requests would answer at two moments, and the one that finished
    /// last — not the one that was asked last — would be the one the row kept:
    /// a slow round could put its older figures back over a refresh the user
    /// had just watched land, or park a connection that refresh proved healthy.
    ///
    /// Nothing outside the monitor can observe that the second caller is
    /// inside it, so the pool is yielded rather than slept on before the fetch
    /// is let go. A caller that has not joined by then spends a second
    /// request, which is what `attempts` fails on — the test cannot pass by
    /// never having overlapped.
    func testARefreshDuringARoundJoinsItRatherThanAskingTwice() async {
        let gate = FetchGate()
        let attempts = LockedValue(0)
        let monitor = ForgeActivityMonitor(
            connections: [Self.gitHub],
            fetch: { connection, _, _, _ in
                attempts.update { $0 += 1 }
                await gate.arrive()
                return Self.reading(connection, login: "gh", contributions: 11, merged: 2)
            },
            token: { _ in .found("token") })
        async let round: Duration = monitor.refreshOnce {}
        await gate.waitForStart()
        async let manual: Void = monitor.refreshOnce(id: Self.gitHub.id) {}
        await letTheOtherCallerIn()
        await gate.letGo()
        _ = await round
        await manual
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
            token: { _ in .found("token") })
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
            token: { _ in .found("token") })

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
            token: { _ in .found("token") })
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
