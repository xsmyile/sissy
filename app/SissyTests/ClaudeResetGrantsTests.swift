import XCTest

@testable import Sissy

/// What Anthropic's reply says about a Claude account's resets, and how the
/// probe spends one.
final class ClaudeResetGrantsTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)
    private static let grantID = "opus55-launch-team-20260921"

    /// The block as measured on 2026-10-05, with the dates moved around `now`.
    private func block(
        eligible: Bool = true, atLimit: Bool = false, usableNow: Bool = true,
        requiresLimit: Bool = false, left: Int = 1, endsAt: String = "2026-10-22T16:00:00+00:00"
    ) -> [String: Any] {
        [
            "cedar_ember": [
                "eligible": eligible, "ineligible_reason": NSNull(), "at_limit": atLimit,
                "grants": [
                    [
                        "id": Self.grantID,
                        "label": "Claude Opus 5.5 launch: one usage-limit reset for Team members",
                        "resets_total": 1, "resets_left": left,
                        "starts_at": "2026-09-22T16:00:00+00:00", "ends_at": endsAt,
                        "clears": ["five_hour", "seven_day", "seven_day_overage_included"],
                        "paused": false, "usable_now": usableNow, "use_requires_limit": requiresLimit,
                    ] as [String: Any]
                ],
                "next_grant_id": Self.grantID,
            ] as [String: Any]
        ]
    }

    // MARK: - Reading

    func testTheMeasuredGrantIsOneResetClearingBothWindows() throws {
        let status = try XCTUnwrap(ClaudeResetGrants.status(block(), now: Self.now))
        XCTAssertEqual(status.grantID, Self.grantID)
        XCTAssertEqual(status.resets.available, 1)
        XCTAssertEqual(status.resets.applicable, 1)
        XCTAssertEqual(status.resets.clears, [300, 10_080])
        XCTAssertEqual(
            status.resets.title, "Claude Opus 5.5 launch: one usage-limit reset for Team members")
        XCTAssertEqual(
            status.resets.nextExpiry, UsageReaderShared.parseTimestamp("2026-10-22T16:00:00+00:00"))
    }

    /// The plain reply carries `cedar_ember: null`, and an account the vendor
    /// will not offer one to says why in a block with no grants.
    func testNoBlockAndAnIneligibleAccountOfferNothing() {
        XCTAssertNil(ClaudeResetGrants.status(["cedar_ember": NSNull()], now: Self.now))
        XCTAssertNil(ClaudeResetGrants.status(block(eligible: false), now: Self.now))
    }

    /// The log says why a reply drew no row, in the vendor's words where it
    /// gives any: a missing block, a refused account and a spent grant are
    /// three different things to do about it.
    func testTheNoteSaysWhyAReplyOffersNoReset() {
        XCTAssertEqual(ClaudeResetGrants.note([:], now: Self.now), "the reply carried no reset block")
        var refused = block(eligible: false)
        refused["cedar_ember"] = ["eligible": false, "ineligible_reason": "surface"]
        XCTAssertEqual(ClaudeResetGrants.note(refused, now: Self.now), "ineligible (surface)")
        XCTAssertEqual(
            ClaudeResetGrants.note(block(left: 0), now: Self.now), "no grant left that clears a window")
        XCTAssertEqual(ClaudeResetGrants.note(block(), now: Self.now), "1 available, 1 usable now")
    }

    /// Every log line leads with the instant it was written, offset included,
    /// so a switch and the reading after it can be put on the clock.
    func testALogLineLeadsWithItsInstant() throws {
        let rome = try XCTUnwrap(TimeZone(identifier: "Europe/Rome"))
        XCTAssertEqual(
            SissyLogLine.stamped("sissy: hello\nforged", at: Self.now, zone: rome),
            "2026-09-21T16:13:20+02:00 sissy: hello\\nforged")
    }

    func testASpentOrLapsedGrantOffersNothing() {
        XCTAssertNil(ClaudeResetGrants.status(block(left: 0), now: Self.now))
        XCTAssertNil(
            ClaudeResetGrants.status(block(endsAt: "2026-09-01T00:00:00+00:00"), now: Self.now))
    }

    /// A reset that clears no window the page draws has nothing on it to move.
    func testAGrantClearingNoDrawnWindowOffersNothing() throws {
        var body = block()
        var status = try XCTUnwrap(body["cedar_ember"] as? [String: Any])
        var grants = try XCTUnwrap(status["grants"] as? [[String: Any]])
        grants[0]["clears"] = ["seven_day_overage_included"]
        status["grants"] = grants
        body["cedar_ember"] = status
        XCTAssertNil(ClaudeResetGrants.status(body, now: Self.now))
    }

    /// A grant usable only at a limit keeps its row away from one, and says the
    /// vendor would not apply it yet.
    func testAGrantForALimitDoesNotApplyBeforeOne() throws {
        let early = try XCTUnwrap(
            ClaudeResetGrants.status(block(requiresLimit: true), now: Self.now))
        XCTAssertFalse(early.resets.appliesNow)
        let atLimit = try XCTUnwrap(
            ClaudeResetGrants.status(block(atLimit: true, requiresLimit: true), now: Self.now))
        XCTAssertTrue(atLimit.resets.appliesNow)
        let unusable = try XCTUnwrap(
            ClaudeResetGrants.status(block(usableNow: false), now: Self.now))
        XCTAssertFalse(unusable.resets.appliesNow)
    }

    /// Measured 2026-10-05: no agent, `claude-cli` alone and an old version are
    /// all refused the block, so only a version the CLI recorded is named.
    func testTheAgentNamesTheCLIAtARecordedVersionOnly() {
        XCTAssertEqual(
            ClaudeResetGrants.userAgent(cliVersion: "2.1.289"), "claude-cli/2.1.289 (external, cli)")
        XCTAssertNil(ClaudeResetGrants.userAgent(cliVersion: nil))
        XCTAssertNil(ClaudeResetGrants.userAgent(cliVersion: "2.1"))
        XCTAssertNil(ClaudeResetGrants.userAgent(cliVersion: "2.1.289 (evil)"))
    }

    // MARK: - Answers

    /// A resend is what turns three answers from "nothing was spent" into "the
    /// first may have", as the CLI words them.
    func testAResendReadsTheVendorsAnswersAsTheFirstAttempts() {
        XCTAssertEqual(LimitResetOutcome(.alreadyUsed, retrying: false), .noCredit)
        XCTAssertEqual(LimitResetOutcome(.alreadyUsed, retrying: true), .reset)
        XCTAssertEqual(LimitResetOutcome(.notLimited, retrying: false), .nothingToReset)
        XCTAssertEqual(LimitResetOutcome(.notLimited, retrying: true), .mayHaveLanded)
        XCTAssertEqual(LimitResetOutcome(.cooldown, retrying: false), .cooldown)
        XCTAssertEqual(LimitResetOutcome(.unavailable, retrying: false), .unconfirmed)
    }

    // MARK: - The spend

    func testTheProfileNamesTheAccountAndTheOrganisation() throws {
        let owner = try ClaudeResetGrants.owner([
            "account": ["uuid": "user-1"], "organization": ["uuid": Self.organization],
        ])
        XCTAssertEqual(owner, ClaudeResetGrants.Owner(account: "user-1", organization: Self.organization))
        XCTAssertThrowsError(try ClaudeResetGrants.owner(["account": ["uuid": "user-1"]]))
    }

    private final class Spends: @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [ClaudeLimitsProbe.ResetSpend] = []
        private var answers: [Result<ClaudeResetGrants.Answer, Error>]

        init(_ answers: [Result<ClaudeResetGrants.Answer, Error>]) { self.answers = answers }

        func answer(_ spend: ClaudeLimitsProbe.ResetSpend) throws -> ClaudeResetGrants.Answer {
            let next = lock.withLock {
                sent.append(spend)
                return answers.removeFirst()
            }
            return try next.get()
        }

        var requests: [ClaudeLimitsProbe.ResetSpend] { lock.withLock { sent } }
    }

    /// Mutable state a test changes under a running probe: the token in the
    /// CLI's slot, whose account it is, and which grant the vendor names next.
    private final class World: @unchecked Sendable {
        private let lock = NSLock()
        private var state = (token: "t1", account: "user-1", grant: ClaudeResetGrantsTests.grantID)
        private var failOwner = false

        var token: String {
            get { lock.withLock { state.token } }
            set { lock.withLock { state.token = newValue } }
        }
        var account: String {
            get { lock.withLock { state.account } }
            set { lock.withLock { state.account = newValue } }
        }
        var grant: String {
            get { lock.withLock { state.grant } }
            set { lock.withLock { state.grant = newValue } }
        }
        var failsOwnerOnce: Bool {
            get { lock.withLock { failOwner } }
            set { lock.withLock { failOwner = newValue } }
        }
    }

    private static let organization = "1001DDB9-0000-4000-8000-000000000000"

    private func reading(grant: String) -> ClaudeLimitsProbe.Reading {
        var body = block()
        if var status = body["cedar_ember"] as? [String: Any],
            var grants = status["grants"] as? [[String: Any]]
        {
            grants[0]["id"] = grant
            status["grants"] = grants
            status["next_grant_id"] = grant
            body["cedar_ember"] = status
        }
        return ClaudeLimitsProbe.parse(body, observedAt: Self.now)
    }

    private func probe(_ spends: Spends, world: World = World()) -> ClaudeLimitsProbe {
        let first = reading(grant: Self.grantID)
        let second = reading(grant: "second-grant")
        return ClaudeLimitsProbe(
            credentials: { _ in
                .found(ClaudeCredentials(accessToken: world.token, expiresAt: .distantFuture))
            },
            fetch: { _ in world.grant == Self.grantID ? first : second },
            owner: { _, _ in
                if world.failsOwnerOnce {
                    world.failsOwnerOnce = false
                    throw URLError(.timedOut)
                }
                return ClaudeResetGrants.Owner(account: world.account, organization: Self.organization)
            },
            spend: { try spends.answer($0) },
            cliVersion: { "2.1.289" })
    }

    func testAReadingPublishesTheResets() async {
        let probe = probe(Spends([]))
        await probe.refresh {}
        XCTAssertEqual(probe.currentSignals().resets?.available, 1)
        await probe.stop()
        XCTAssertNil(probe.currentSignals().resets)
    }

    /// An answer that never arrived keeps its request id, so the press after
    /// it cannot spend a second reset, and the vendor's answer then settles it.
    func testAnUnansweredSpendIsResentUnderTheSameRequestID() async {
        let spends = Spends([.failure(URLError(.timedOut)), .success(.alreadyUsed), .success(.reset)])
        let probe = probe(spends)
        await probe.refresh {}

        let first = await probe.useReset(offeredTo: "user-1") {}
        let second = await probe.useReset(offeredTo: "user-1") {}
        let third = await probe.useReset(offeredTo: "user-1") {}

        XCTAssertEqual(first, .unconfirmed)
        XCTAssertEqual(second, .reset)
        XCTAssertEqual(third, .reset)
        let sent = spends.requests
        XCTAssertEqual(sent.map(\.grantID), Array(repeating: Self.grantID, count: 3))
        XCTAssertEqual(sent[0].requestID, sent[1].requestID)
        XCTAssertNotEqual(sent[1].requestID, sent[2].requestID)
        XCTAssertEqual(sent[0].userAgent, "claude-cli/2.1.289 (external, cli)")
        XCTAssertEqual(sent[0].organization, Self.organization)
        await probe.stop()
    }

    /// A reading taken after a timeout can name the next grant precisely
    /// because the first attempt landed: `Try again` resends the first, and
    /// spends nothing of the second.
    func testARetryResendsTheFirstGrantWhenTheReadingNamesAnother() async {
        let spends = Spends([.failure(URLError(.timedOut)), .success(.alreadyUsed)])
        let world = World()
        let probe = probe(spends, world: world)
        await probe.refresh {}
        world.grant = "second-grant"

        _ = await probe.useReset(offeredTo: "user-1") {}
        let retried = await probe.useReset(offeredTo: "user-1") {}

        XCTAssertEqual(retried, .reset)
        XCTAssertEqual(spends.requests.map(\.grantID), [Self.grantID, Self.grantID])
        XCTAssertEqual(spends.requests[0].requestID, spends.requests[1].requestID)
        await probe.stop()
    }

    /// A refusal means the request was never taken, so the next press is a
    /// fresh attempt rather than a resend.
    func testARefusedSpendKeepsNoRequestID() async {
        let spends = Spends([.failure(UsageRequestError.badStatus(401)), .success(.reset)])
        let probe = probe(spends)
        await probe.refresh {}

        let refused = await probe.useReset(offeredTo: "user-1") {}
        _ = await probe.useReset(offeredTo: "user-1") {}

        XCTAssertEqual(refused, .refused)
        XCTAssertNotEqual(spends.requests[0].requestID, spends.requests[1].requestID)
        await probe.stop()
    }

    /// The CLI renews its token every few hours: the same account under a
    /// renewed token is read again and spends.
    func testARenewedTokenOfTheSameAccountSpends() async {
        let spends = Spends([.success(.reset)])
        let world = World()
        let probe = probe(spends, world: world)
        await probe.refresh {}
        world.token = "t2"

        let outcome = await probe.useReset(offeredTo: "user-1") {}

        XCTAssertEqual(outcome, .reset)
        XCTAssertEqual(spends.requests.map(\.token), ["t2"])
        await probe.stop()
    }

    func testARenewedTokenResendsTheUnansweredAttempt() async {
        let spends = Spends([.failure(URLError(.timedOut)), .success(.reset)])
        let world = World()
        let probe = probe(spends, world: world)
        await probe.refresh {}

        _ = await probe.useReset(offeredTo: "user-1") {}
        world.token = "t2"
        let resent = await probe.useReset(offeredTo: "user-1") {}

        XCTAssertEqual(resent, .reset)
        XCTAssertEqual(spends.requests[0].requestID, spends.requests[1].requestID)
        XCTAssertEqual(spends.requests[1].token, "t2")
        await probe.stop()
    }

    /// A `/login` to another account between the offer and the press spends
    /// nothing, whatever that account holds.
    func testAnAccountSwitchSinceTheOfferSpendsNothing() async {
        let spends = Spends([])
        let world = World()
        let probe = probe(spends, world: world)
        await probe.refresh {}
        world.token = "t-other"
        world.account = "user-2"

        let outcome = await probe.useReset(offeredTo: "user-1") {}

        XCTAssertEqual(outcome, .offerChanged)
        XCTAssertTrue(spends.requests.isEmpty)
        await probe.stop()
    }

    /// With no account on the page there is nothing to check a changed token
    /// against, so only the token the reading was taken with spends.
    func testWithNoAccountNamedAChangedTokenSpendsNothing() async {
        let spends = Spends([])
        let world = World()
        let probe = probe(spends, world: world)
        await probe.refresh {}
        world.token = "t2"

        let outcome = await probe.useReset(offeredTo: nil) {}

        XCTAssertEqual(outcome, .offerChanged)
        XCTAssertTrue(spends.requests.isEmpty)
        await probe.stop()
    }

    /// A probe switched off holds no reading to have offered a reset from.
    func testAStoppedProbeSpendsNothing() async {
        let spends = Spends([])
        let probe = probe(spends)
        await probe.refresh {}
        await probe.stop()
        let outcome = await probe.useReset(offeredTo: "user-1") {}
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertTrue(spends.requests.isEmpty)
    }

    /// A press that could not learn whose the token is never reached the
    /// spend, so the next one is a fresh attempt and its answers are not a
    /// resend's.
    func testAnOwnerThatCannotBeReadIsNoAttempt() async {
        let spends = Spends([.success(.notLimited)])
        let world = World()
        world.failsOwnerOnce = true
        let probe = probe(spends, world: world)
        await probe.refresh {}

        let first = await probe.useReset(offeredTo: "user-1") {}
        let second = await probe.useReset(offeredTo: "user-1") {}

        XCTAssertEqual(first, .unavailable)
        XCTAssertEqual(second, .nothingToReset)
        XCTAssertEqual(spends.requests.count, 1)
        await probe.stop()
    }

    // MARK: - The page

    func testTheClaudeRowSpendsTheCLIsCredentialAndNamesWhatItClears() {
        var signals = ProviderSignals()
        signals.resets = LimitResets(available: 1, applicable: 1, clears: [10_080, 300])
        let slice = ProviderSlice(id: ProviderID.claudeCode, tokens: 0, cost: 0, signals: signals)
        let frame = FrameData(
            tokens: 0, cost: 0, burn: nil, providers: [slice], keepAwake: .off, history: [:],
            projects: [])
        let row = UsagePanelSnapshot.make(frame: frame).providers[0]
        XCTAssertEqual(
            row.resetTarget, LimitResetTarget(provider: ProviderID.claudeCode, account: nil))
        XCTAssertEqual(row.resets?.clears, ["Session", "Weekly"])
        XCTAssertEqual(
            LimitResetCopy.confirmBody(
                available: 1, clears: row.resets?.clears ?? [], naturalReset: nil, appliesNow: false,
                provider: ProviderID.claudeCode),
            "Session and Weekly go back to zero. This spends 1 of 1. Anthropic does not count one "
                + "as needed yet and may decline it, which spends nothing.")
    }

    private func account(signedIn: Bool) -> AccountSignals {
        AccountSignals(id: "user", account: nil, plan: nil, planTier: nil, isSignedIn: signedIn)
    }

    /// Only the CLI's own credential can spend, so an account it is not signed
    /// in as has no button.
    func testAnotherClaudeAccountHasNoResetTarget() {
        XCTAssertNil(
            UsagePanelSnapshot.accountResetTarget(
                provider: ProviderID.claudeCode, id: "user-2", reading: account(signedIn: false)))
        XCTAssertEqual(
            UsagePanelSnapshot.accountResetTarget(
                provider: ProviderID.claudeCode, id: "user-1", reading: account(signedIn: true)),
            LimitResetTarget(provider: ProviderID.claudeCode, account: "user-1"))
    }
}
