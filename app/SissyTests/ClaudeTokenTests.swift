import XCTest

@testable import Sissy

/// The long-lived token a user gives Sissy, and what it changes about where
/// the limits come from.
///
/// The whole point of the path is that Claude Code's own keychain item is not
/// a permission anyone grants once — the CLI rewrites it on every token
/// refresh and the ACL goes with it. These assert the two halves that make a
/// managed token worth having: it is used *instead of* the foreign item, and
/// a token the endpoint stops accepting says so instead of going quiet.
final class ClaudeTokenTests: XCTestCase {
    private static let managed = ClaudeCredentials(
        accessToken: "sk-ant-oat01-test", expiresAt: nil, origin: .managed)
    private static let cli = ClaudeCredentials(
        accessToken: "cli", expiresAt: Date.distantFuture, origin: .cli)

    /// Counts what each source was asked, so a test can assert an item was
    /// never touched rather than only that the right one answered.
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        private var pending: [(source: String, count: Int, expectation: XCTestExpectation)] = []

        func record(_ source: String) {
            lock.lock()
            counts[source, default: 0] += 1
            let reached = counts[source] ?? 0
            let ready = pending.filter { $0.source == source && $0.count <= reached }
            pending.removeAll { $0.source == source && $0.count <= reached }
            lock.unlock()
            ready.forEach { $0.expectation.fulfill() }
        }

        func count(_ source: String) -> Int { lock.withLock { counts[source] ?? 0 } }

        /// Records the read and, separately, whether it was allowed to put a
        /// dialog on screen — the one thing about a read that a test of the
        /// permission rule has to see.
        func record(_ source: String, asking: Bool) {
            record(source)
            if asking { record("\(source):asked") }
        }

        /// Waits for the nth read of a source rather than for a duration: the
        /// poll loop's read happens on its own task, and a count sampled
        /// straight after `start` measures the scheduler instead of the probe.
        func expectation(for source: String, count: Int) -> XCTestExpectation {
            let waiting = XCTestExpectation(description: "\(source) read \(count)")
            lock.lock()
            if counts[source] ?? 0 >= count {
                lock.unlock()
                waiting.fulfill()
                return waiting
            }
            pending.append((source, count, waiting))
            lock.unlock()
            return waiting
        }
    }

    private func makeProbe(
        reads: Reads = Reads(),
        managed: @escaping @Sendable () -> ClaudeCredentialsLookup,
        cli: @escaping @Sendable () -> ClaudeCredentialsLookup = { .absent },
        transport: @escaping ClaudeUsageTransport = { _ in throw URLError(.notConnectedToInternet) }
    ) -> ClaudeLimitsProbe {
        ClaudeLimitsProbe(
            credentials: { _, asking in
                reads.record("cli", asking: asking)
                return cli()
            },
            managedToken: { _, asking in
                reads.record("managed", asking: asking)
                return managed()
            },
            transport: transport
        )
    }

    private func responding(
        _ status: Int,
        body: String = "{}",
        counting reads: Reads? = nil
    ) -> ClaudeUsageTransport {
        { request in
            reads?.record("request")
            let url = request.url ?? URL(fileURLWithPath: "/")
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: nil)
            return (Data(body.utf8), response ?? URLResponse())
        }
    }

    // MARK: - Which item answers

    /// The reason the feature exists: with a token on file, Claude Code's item
    /// is never read, so nothing can rewrite the grant out from under Sissy.
    func testATokenOnFileMeansTheCLIsItemIsNeverTouched() async {
        let reads = Reads()
        let probe = makeProbe(
            reads: reads,
            managed: { .found(Self.managed) },
            transport: responding(200, body: #"{"five_hour":{"utilization":10,"resets_at":1}}"#))

        _ = await probe.refreshOnce {}

        XCTAssertEqual(reads.count("managed"), 1)
        XCTAssertEqual(
            reads.count("cli"), 0,
            "a stored token still let Sissy read Claude Code's keychain item")
    }

    /// And the upgrade path: someone who has pasted nothing keeps the
    /// behaviour they already had.
    func testWithoutATokenTheCLIsItemIsStillTheSource() async {
        let reads = Reads()
        let probe = makeProbe(
            reads: reads,
            managed: { .absent },
            cli: { .found(Self.cli) },
            transport: responding(200, body: #"{"five_hour":{"utilization":10,"resets_at":1}}"#))

        _ = await probe.refreshOnce {}

        XCTAssertEqual(reads.count("cli"), 1, "an absent token did not fall through to the CLI")
    }

    /// Only *absence* falls through. A token that exists and cannot be read —
    /// which is what a re-signed build meets — is an answer, and continuing to
    /// the foreign item would raise the very dialog the token was pasted to
    /// avoid.
    func testAnUnreadableTokenDoesNotFallBackToTheCLIsItem() async {
        let reads = Reads()
        let probe = makeProbe(reads: reads, managed: { .interactionRequired }, cli: { .found(Self.cli) })

        _ = await probe.refreshOnce {}

        XCTAssertEqual(
            reads.count("cli"), 0,
            "an unreadable stored token fell through and reached for the CLI's item")
        XCTAssertEqual(probe.currentLimitsState(), .needsAuthorization)
    }

    // MARK: - A token the endpoint stops accepting

    /// `claude setup-token` publishes no expiry Sissy can read, so a 401 is
    /// the only thing that knows the token died. It has to reach the panel:
    /// gauges that silently stop is the failure this path exists to end.
    func testARejectedManagedTokenAsksForANewOne() async {
        let probe = makeProbe(managed: { .found(Self.managed) }, transport: responding(401))

        _ = await probe.refreshOnce {}

        XCTAssertEqual(probe.currentLimitsState(), .tokenRejected)
    }

    /// A 403 naming the scope is the same thing said differently: the token
    /// authenticates and was minted without what the endpoint wants, and only
    /// another `setup-token` fixes it.
    func testATokenMintedWithoutTheScopeAlsoAsksForANewOne() async {
        let probe = makeProbe(
            managed: { .found(Self.managed) },
            transport: responding(403, body: #"{"error":"requires scope user:profile"}"#))

        _ = await probe.refreshOnce {}

        XCTAssertEqual(probe.currentLimitsState(), .tokenRejected)
    }

    /// Any other 403 is not a token to replace. Guessing would tell someone to
    /// re-paste a credential that was never the problem.
    func testAnUnrelatedForbiddenIsNotBlamedOnTheToken() async {
        let probe = makeProbe(
            managed: { .found(Self.managed) },
            transport: responding(403, body: #"{"error":"region unsupported"}"#))

        _ = await probe.refreshOnce {}

        XCTAssertEqual(probe.currentLimitsState(), .quiet)
    }

    /// The CLI's token rotates on its own, so a 401 on it is a stale copy
    /// rather than anything a user should be asked to fix.
    func testARejectedCLITokenIsNotTheUsersProblem() async {
        let probe = makeProbe(
            managed: { .absent }, cli: { .found(Self.cli) }, transport: responding(401))

        _ = await probe.refreshOnce {}

        XCTAssertEqual(
            probe.currentLimitsState(), .quiet,
            "a stale CLI token was reported as a token the user has to replace")
    }

    /// A rejected token is worth one row, not a request every five minutes:
    /// polling a credential known to be dead is how a third-party poller earns
    /// a persistent 429. Aliveness is read through `start` being idempotent —
    /// a second start that runs a fresh read proves the loop had stopped.
    /// Counted in requests rather than in keychain reads: the token stays
    /// cached across the stop on purpose, so a restarted probe reaches the
    /// endpoint without reading the item again, and a keychain count would
    /// show one either way.
    func testARejectedTokenStopsThePoll() async {
        let reads = Reads()
        let probe = makeProbe(
            reads: reads,
            managed: { .found(Self.managed) },
            transport: responding(401, counting: reads))

        let first = reads.expectation(for: "request", count: 1)
        await probe.start(userInitiated: false) {}
        await fulfillment(of: [first], timeout: 5)

        // A second request landing promptly proves the loop had stopped: a
        // running one would be asleep for the refresh interval, and `start`
        // on it is a no-op.
        let second = reads.expectation(for: "request", count: 2)
        await probe.start(userInitiated: false) {}
        await fulfillment(of: [second], timeout: 5)
        await probe.stop()

        XCTAssertEqual(reads.count("request"), 2, "a rejection left the poll loop running")
    }

    /// And the state has to survive that stop, because the row explaining why
    /// the gauges went is the only thing telling the user a paste is needed.
    func testTheRejectionSurvivesTheStopItCauses() async {
        let reads = Reads()
        let probe = makeProbe(
            reads: reads, managed: { .found(Self.managed) }, transport: responding(401))

        let first = reads.expectation(for: "managed", count: 1)
        await probe.start(userInitiated: false) {}
        await fulfillment(of: [first], timeout: 5)

        XCTAssertEqual(probe.currentLimitsState(), .tokenRejected)
        XCTAssertTrue(probe.currentWindows().isEmpty, "gauges outlived the token that fed them")
    }

    /// A managed token publishes no expiry, so it never falls out of the
    /// cache on its own. Switching the module off has to drop it, or a user
    /// who removes their token while the switch is off and turns it back on
    /// keeps metering with a credential Sissy was told to forget.
    func testSwitchingTheModuleOffForgetsTheToken() async {
        let reads = Reads()
        let probe = makeProbe(
            reads: reads,
            managed: { .found(Self.managed) },
            transport: responding(200, body: #"{"five_hour":{"utilization":4,"resets_at":1}}"#))

        _ = await probe.refreshOnce {}
        await probe.stop()
        _ = await probe.refreshOnce {}

        XCTAssertEqual(
            reads.count("managed"), 2,
            "the module came back on still holding the token it was switched off with")
    }

    /// Changing the stored token is a user action that still must not ask.
    ///
    /// Removing one falls the probe back to Claude Code's item, and a Settings
    /// button nobody pointed at the keychain raising its dialog would be a
    /// third gesture where `UsageEngine.refreshProvider` says there are two.
    /// The silent read answers `.interactionRequired` and the panel's notice
    /// row is what offers the permission back.
    func testChangingTheStoredTokenIsNotAllowedToAsk() async {
        let reads = Reads()
        let probe = makeProbe(reads: reads, managed: { .absent }, cli: { .interactionRequired })

        let read = reads.expectation(for: "cli", count: 1)
        await probe.refresh(userInitiated: false) {}
        await fulfillment(of: [read], timeout: 5)
        await probe.stop()

        XCTAssertEqual(
            reads.count("cli:asked"), 0,
            "removing a token put a keychain dialog in front of someone who asked for neither")
        XCTAssertEqual(reads.count("managed:asked"), 0)
    }

    /// The panel's own refresh button keeps the permission it always had —
    /// that gesture is one of the two allowed to ask.
    func testThePanelRefreshIsStillAllowedToAsk() async {
        let reads = Reads()
        let probe = makeProbe(reads: reads, managed: { .absent }, cli: { .interactionRequired })

        let read = reads.expectation(for: "cli", count: 1)
        await probe.refresh {}
        await fulfillment(of: [read], timeout: 5)
        await probe.stop()

        XCTAssertEqual(reads.count("cli:asked"), 1, "the refresh button stopped being able to ask")
    }

    // MARK: - What a paste is checked against

    func testVerificationNamesWhatTheEndpointSaid() async {
        let cases: [(Int, String, ClaudeTokenVerification)] = [
            (200, #"{"five_hour":{"utilization":4,"resets_at":1}}"#, .accepted),
            (200, "{}", .acceptedWithoutWindows),
            (401, "{}", .rejected),
            (403, #"{"error":"scope user:profile"}"#, .missingScope),
            (429, "{}", .rateLimited),
        ]
        for (status, body, expected) in cases {
            let verdict = await ClaudeLimitsProbe.verify(
                token: "sk-ant-oat01-test", transport: responding(status, body: body))
            XCTAssertEqual(verdict, expected, "HTTP \(status) was read as \(verdict)")
        }
    }

    /// A token that authenticates against a plan publishing no buckets is an
    /// account fact, not a bad paste, and storing it is right.
    func testAnAccountWithNoWindowsStillHasAUsableToken() {
        XCTAssertTrue(ClaudeTokenVerification.acceptedWithoutWindows.isUsable)
        XCTAssertFalse(ClaudeTokenVerification.rateLimited.isUsable)
    }

    // MARK: - The paste itself

    /// A token copied out of a terminal carries whitespace and one copied out
    /// of a header carries `Bearer `. Both are the same token, and refusing
    /// either would be a puzzle rather than an error.
    func testAPasteIsTakenAsTheUserFoundIt() {
        for raw in ["  sk-ant-oat01-abc\n", "Bearer sk-ant-oat01-abc", "sk-ant-oat01-abc"] {
            XCTAssertEqual(ClaudeTokenStore.normalize(raw), "sk-ant-oat01-abc")
        }
    }

    func testAnObviousMispasteIsRecognisedWithoutSpendingARequest() {
        XCTAssertTrue(ClaudeTokenStore.looksLikeToken("Bearer sk-ant-oat01-abc"))
        XCTAssertFalse(ClaudeTokenStore.looksLikeToken("claude setup-token"))
        XCTAssertFalse(ClaudeTokenStore.looksLikeToken(""))
        XCTAssertFalse(ClaudeTokenStore.looksLikeToken(ClaudeTokenStore.tokenPrefix))
    }

    /// A managed token has no expiry to check, and treating that as "expired"
    /// would make the endpoint unreachable rather than merely unproven.
    func testATokenWithNoPublishedExpiryIsNotTreatedAsExpired() {
        XCTAssertTrue(Self.managed.isValid())
        XCTAssertFalse(
            ClaudeCredentials(
                accessToken: "x", expiresAt: Date.distantPast, origin: .cli
            ).isValid())
    }

    // MARK: - What the row offers

    /// No action button: a refresh cannot fix a dead token, and offering one
    /// would spend a click to arrive back at the same row.
    func testTheRejectedNoticeOffersNoRetry() {
        let notice = UsageFormat.limitsNotice(.tokenRejected)
        XCTAssertNotNil(notice)
        XCTAssertNil(notice?.action, "a dead token was given a retry button that cannot help")
    }
}
