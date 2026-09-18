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

    /// The way back from a parked connection is connecting the host again,
    /// which builds a new monitor with nothing parked. A monitor cannot unpark
    /// itself, and that is deliberate: a token the vendor refused cannot be
    /// un-refused by asking a second time.
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

    /// A round that changed nothing costs no frame.
    func testARoundThatChangesNothingDoesNotAskForAFrame() async {
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
}
