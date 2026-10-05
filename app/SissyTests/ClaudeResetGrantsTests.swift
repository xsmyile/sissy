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

    /// The token the CLI's slot holds, which a test can rotate under the probe.
    private final class Slot: @unchecked Sendable {
        private let lock = NSLock()
        private var held = "t1"
        var token: String {
            get { lock.withLock { held } }
            set { lock.withLock { held = newValue } }
        }
    }

    private static let organization = "1001DDB9-0000-4000-8000-000000000000"

    private func probe(
        _ spends: Spends, slot: Slot = Slot(),
        organization: @escaping @Sendable () throws -> String = { organization }
    ) -> ClaudeLimitsProbe {
        let reading = ClaudeLimitsProbe.parse(block(), observedAt: Self.now)
        return ClaudeLimitsProbe(
            credentials: { _ in
                .found(ClaudeCredentials(accessToken: slot.token, expiresAt: .distantFuture))
            },
            fetch: { _ in reading },
            organization: { _, _ in try organization() },
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

        let first = await probe.useReset {}
        let second = await probe.useReset {}
        let third = await probe.useReset {}

        XCTAssertEqual(first, .unconfirmed)
        XCTAssertEqual(second, .reset)
        XCTAssertEqual(third, .reset)
        let sent = spends.requests
        XCTAssertEqual(sent.map(\.grantID), Array(repeating: Self.grantID, count: 3))
        XCTAssertEqual(sent[0].requestID, sent[1].requestID)
        XCTAssertNotEqual(sent[1].requestID, sent[2].requestID)
        XCTAssertEqual(sent[0].userAgent, "claude-cli/2.1.289 (external, cli)")
        await probe.stop()
    }

    /// A refusal means the request was never taken, so the next press is a
    /// fresh attempt rather than a resend.
    func testARefusedSpendKeepsNoRequestID() async {
        let spends = Spends([.failure(UsageRequestError.badStatus(401)), .success(.reset)])
        let probe = probe(spends)
        await probe.refresh {}

        let refused = await probe.useReset {}
        _ = await probe.useReset {}

        XCTAssertEqual(refused, .refused)
        XCTAssertNotEqual(spends.requests[0].requestID, spends.requests[1].requestID)
        await probe.stop()
    }

    /// A grant read with one account's token is not spent with another's
    /// without reading the account again: the press re-reads with the token
    /// it will spend, and spends what that reading names.
    func testATokenTheGrantWasNotReadWithIsReadAgainBeforeTheSpend() async {
        let spends = Spends([.success(.reset)])
        let slot = Slot()
        let fetched = Fetches()
        let reading = ClaudeLimitsProbe.parse(block(), observedAt: Self.now)
        let probe = ClaudeLimitsProbe(
            credentials: { _ in
                .found(ClaudeCredentials(accessToken: slot.token, expiresAt: .distantFuture))
            },
            fetch: { token in
                fetched.record(token)
                return reading
            },
            organization: { _, _ in Self.organization },
            spend: { try spends.answer($0) },
            cliVersion: { "2.1.289" })
        await probe.refresh {}
        slot.token = "another-account"

        let outcome = await probe.useReset {}

        XCTAssertEqual(outcome, .reset)
        XCTAssertEqual(Array(fetched.tokens.prefix(2)), ["t1", "another-account"])
        XCTAssertEqual(spends.requests.map(\.token), ["another-account"])
        await probe.stop()
    }

    private final class Fetches: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        func record(_ token: String) { lock.withLock { seen.append(token) } }
        var tokens: [String] { lock.withLock { seen } }
    }

    /// A probe switched off holds no reading to have offered a reset from.
    func testAStoppedProbeSpendsNothing() async {
        let spends = Spends([])
        let probe = probe(spends)
        await probe.refresh {}
        await probe.stop()
        let outcome = await probe.useReset {}
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertTrue(spends.requests.isEmpty)
    }

    /// The CLI renews its token every few hours, and the attempt is the
    /// account's rather than the token's: a renewed token resends it.
    func testARenewedTokenResendsTheUnansweredAttempt() async {
        let spends = Spends([.failure(URLError(.timedOut)), .success(.reset)])
        let slot = Slot()
        let probe = probe(spends, slot: slot)
        await probe.refresh {}

        _ = await probe.useReset {}
        slot.token = "t2"
        let resent = await probe.useReset {}

        XCTAssertEqual(resent, .reset)
        XCTAssertEqual(spends.requests[0].requestID, spends.requests[1].requestID)
        XCTAssertEqual(spends.requests[1].token, "t2")
        await probe.stop()
    }

    /// A press that could not learn the organisation never reached the spend,
    /// so the next one is a fresh attempt and its answers are not a resend's.
    func testAnOrganisationThatCannotBeReadIsNoAttempt() async {
        let spends = Spends([.success(.notLimited)])
        let reads = Slot()
        let probe = probe(spends) {
            if reads.token == "t1" {
                reads.token = "read"
                throw URLError(.timedOut)
            }
            return Self.organization
        }
        await probe.refresh {}

        let first = await probe.useReset {}
        let second = await probe.useReset {}

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
        XCTAssertEqual(row.resetTarget, LimitResetTarget(provider: ProviderID.claudeCode, account: nil))
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
            LimitResetTarget(provider: ProviderID.claudeCode, account: nil))
    }
}
