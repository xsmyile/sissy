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
        let resets = try XCTUnwrap(ClaudeResetGrants.status(block(), now: Self.now))
        let expiry = UsageReaderShared.parseTimestamp("2026-10-22T16:00:00+00:00")
        XCTAssertEqual(resets.available, 1)
        XCTAssertEqual(resets.applicable, 1)
        XCTAssertEqual(resets.nextExpiry, expiry)
        XCTAssertEqual(
            resets.grants,
            [
                LimitResetGrant(
                    id: Self.grantID, left: 1, appliesNow: true, expiry: expiry,
                    label: "Claude Opus 5.5 launch: one usage-limit reset for Team members",
                    clears: [
                        ResetWindow(minutes: 300, scope: nil), ResetWindow(minutes: 10_080, scope: nil),
                    ],
                    givesBackWeekly: false)
            ])
    }

    /// The reply as measured on 2026-11-11 on a Max account: a full reset the
    /// vendor names next and a Fable one beside it, each its own grant.
    private func fullAndFable() -> [String: Any] {
        let grant: (String, [String], Bool, String) -> [String: Any] = { id, clears, givesBack, ends in
            [
                "id": id, "label": "label of \(id)", "resets_total": 1, "resets_left": 1,
                "ends_at": ends, "clears": clears, "paused": false, "usable_now": true,
                "use_requires_limit": false, "gives_back_weekly": givesBack,
            ]
        }
        return [
            "limits": [
                ["kind": "weekly_all", "percent": 30, "resets_at": "2026-11-17T16:00:00+00:00"],
                [
                    "kind": "weekly_scoped", "percent": 12, "resets_at": "2026-11-17T16:00:00+00:00",
                    "scope": ["model": ["id": NSNull(), "display_name": "Fable"]],
                ],
            ],
            "cedar_ember": [
                "eligible": true, "at_limit": false,
                "grants": [
                    grant(
                        "launch-2610-fable", ["seven_day_overage_included"], true,
                        "2027-03-09T07:59:00+00:00"),
                    grant(
                        "full-reset-2611", ["seven_day", "seven_day_overage_included"], false,
                        "2026-12-10T22:00:00+00:00"),
                ],
                "next_grant_id": "full-reset-2611",
            ] as [String: Any],
        ]
    }

    /// A Fable reset clears the one model-metered weekly window, which the
    /// reply names `seven_day_overage_included` without naming the model, so
    /// it is drawn as its own kind next to the full one rather than dropped.
    func testAFableResetIsAGrantOfItsOwnBesideTheFullOne() throws {
        let resets = try XCTUnwrap(ClaudeResetGrants.status(fullAndFable(), now: Self.now))
        let fable = ResetWindow(minutes: 10_080, scope: "Fable")
        XCTAssertEqual(resets.available, 2)
        XCTAssertEqual(resets.applicable, 2)
        XCTAssertEqual(resets.grants.map(\.id), ["full-reset-2611", "launch-2610-fable"])
        XCTAssertEqual(
            resets.grants.map(\.clears), [[ResetWindow(minutes: 10_080, scope: nil), fable], [fable]])
        XCTAssertEqual(resets.grants.map(\.givesBackWeekly), [false, true])
        XCTAssertEqual(resets.nextExpiry, UsageReaderShared.parseTimestamp("2026-12-10T22:00:00+00:00"))
        XCTAssertEqual(ClaudeResetGrants.note(fullAndFable(), now: Self.now), "2 available, 2 usable now")
    }

    /// Spending one kind leaves the other on the row until the next reading.
    func testSpendingOneKindKeepsTheOther() throws {
        let resets = try XCTUnwrap(ClaudeResetGrants.status(fullAndFable(), now: Self.now))
        let spent = resets.spendingOne(grant: "launch-2610-fable")
        XCTAssertEqual(spent.available, 1)
        XCTAssertEqual(spent.grants.map(\.id), ["full-reset-2611"])
    }

    /// The page names each kind the way claude.ai does, and the confirmation
    /// says what a Fable reset gives back besides the window it clears.
    func testThePageNamesEachKindAndWhatItGivesBack() throws {
        let resets = try XCTUnwrap(ClaudeResetGrants.status(fullAndFable(), now: Self.now))
        let rows = UsagePanelSnapshot.kinds(resets.grants).map(UsagePanelSnapshot.makeGrant)
        XCTAssertTrue(rows[0].caption.hasPrefix("Full reset · expires "), rows[0].caption)
        XCTAssertTrue(rows[1].caption.hasPrefix("Fable reset · expires "), rows[1].caption)
        XCTAssertEqual(rows[1].clears, ["Weekly · Fable"])
        XCTAssertEqual(rows[1].help, "label of launch-2610-fable")
        XCTAssertEqual(
            LimitResetCopy.confirmBody(
                available: rows[1].left, clears: rows[1].clears,
                givesBackWeekly: rows[1].givesBackWeekly, naturalReset: nil, appliesNow: true,
                provider: ProviderID.claudeCode),
            "Weekly · Fable goes back to zero. What Fable used of Weekly comes back too. This "
                + "spends 1 of 1.")
    }

    /// A Team account's claude.ai reply, measured 2026-11-11: a full reset and
    /// two Fable grants of one shape, which the page lists as two kinds, the
    /// Fable one counted twice and pressed through the first of its grants.
    func testATeamsTwoFableGrantsAreOneKindCountedTwice() throws {
        var body = fullAndFable()
        var block = try XCTUnwrap(body["cedar_ember"] as? [String: Any])
        var grants = try XCTUnwrap(block["grants"] as? [[String: Any]])
        grants[0]["clears"] = ["five_hour", "seven_day_overage_included"]
        grants[1]["clears"] = ["five_hour", "seven_day", "seven_day_overage_included"]
        grants.append(
            grants[0].merging(["id": "launch-2610-fable-6mo", "label": "label of 6mo"]) { $1 })
        block["grants"] = grants
        body["cedar_ember"] = block
        let resets = try XCTUnwrap(ClaudeResetGrants.status(body, now: Self.now))
        XCTAssertEqual(resets.available, 3)
        let rows = UsagePanelSnapshot.kinds(resets.grants).map(UsagePanelSnapshot.makeGrant)
        XCTAssertEqual(rows.map(\.id), ["full-reset-2611", "launch-2610-fable"])
        XCTAssertTrue(rows[1].caption.hasPrefix("Fable reset · 2 · expires "), rows[1].caption)
        XCTAssertEqual(rows[1].left, 2)
        XCTAssertEqual(rows[1].clears, ["Session", "Weekly · Fable"])
        XCTAssertEqual(rows[1].help, "label of launch-2610-fable\nlabel of 6mo")
        XCTAssertEqual(rows[0].clears, ["Session", "Weekly", "Weekly · Fable"])
    }

    /// The vendor's next grant only orders the list, so a reply naming one
    /// this build drops still shows the others.
    func testANextGrantThatIsDroppedLeavesTheOthers() throws {
        var body = fullAndFable()
        var block = try XCTUnwrap(body["cedar_ember"] as? [String: Any])
        block["next_grant_id"] = "gone"
        body["cedar_ember"] = block
        let resets = try XCTUnwrap(ClaudeResetGrants.status(body, now: Self.now))
        XCTAssertEqual(resets.grants.map(\.id), ["launch-2610-fable", "full-reset-2611"])
    }

    /// With two models metered on their own there is no telling which one a
    /// reset of `seven_day_overage_included` means, so it clears nothing the
    /// page can name.
    func testTwoModelWeeksLeaveTheFableResetUnnamed() throws {
        var body = fullAndFable()
        var limits = try XCTUnwrap(body["limits"] as? [[String: Any]])
        limits.append([
            "kind": "weekly_scoped", "percent": 3, "scope": ["model": ["display_name": "Opus"]],
        ])
        body["limits"] = limits
        let resets = try XCTUnwrap(ClaudeResetGrants.status(body, now: Self.now))
        XCTAssertEqual(resets.grants.map(\.id), ["full-reset-2611"])
        XCTAssertEqual(resets.grants[0].clears, [ResetWindow(minutes: 10_080, scope: nil)])
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

    /// A reset that clears no window the page draws has nothing on it to move:
    /// a reply metering no model's week cannot place the one it names.
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
        XCTAssertFalse(early.appliesNow)
        XCTAssertEqual(early.grants.map(\.appliesNow), [false])
        let atLimit = try XCTUnwrap(
            ClaudeResetGrants.status(block(atLimit: true, requiresLimit: true), now: Self.now))
        XCTAssertTrue(atLimit.appliesNow)
        let unusable = try XCTUnwrap(
            ClaudeResetGrants.status(block(usableNow: false), now: Self.now))
        XCTAssertFalse(unusable.appliesNow)
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
        XCTAssertThrowsError(
            try ClaudeResetGrants.owner([
                "account": ["uuid": "user-1"], "organization": ["uuid": "not-a-uuid"],
            ]))
        XCTAssertThrowsError(
            try ClaudeResetGrants.owner([
                "account": ["uuid": ""], "organization": ["uuid": Self.organization],
            ]))
    }

    /// The profile, the poll and the spend all go through this builder, and
    /// the timeout and the agent are the only parts each caller chooses.
    func testTheRequestCarriesTheCLIsHeadersAndTheCallersTimeout() throws {
        let url = try XCTUnwrap(URL(string: "https://api.anthropic.com/api/oauth/profile"))
        let named = ClaudeResetGrants.request(url, token: "t1", userAgent: "claude-cli/2.1.289", timeout: 25)
        XCTAssertEqual(named.timeoutInterval, 25)
        XCTAssertEqual(named.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(named.value(forHTTPHeaderField: "Authorization"), "Bearer t1")
        XCTAssertEqual(named.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(named.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(named.value(forHTTPHeaderField: "User-Agent"), "claude-cli/2.1.289")

        let anonymous = ClaudeResetGrants.request(url, token: "t1", userAgent: nil, timeout: 10)
        XCTAssertEqual(anonymous.timeoutInterval, 10)
        XCTAssertNil(anonymous.value(forHTTPHeaderField: "User-Agent"))
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

    private func reading(grants ids: [String]) -> ClaudeLimitsProbe.Reading {
        var body = block()
        if var status = body["cedar_ember"] as? [String: Any],
            let grants = status["grants"] as? [[String: Any]]
        {
            status["grants"] = ids.map { id in grants[0].merging(["id": id]) { $1 } }
            status["next_grant_id"] = ids[0]
            body["cedar_ember"] = status
        }
        return ClaudeLimitsProbe.parse(body, observedAt: Self.now)
    }

    private func probe(
        _ spends: Spends, world: World = World(), offering: [String] = [ClaudeResetGrantsTests.grantID]
    ) -> ClaudeLimitsProbe {
        let first = reading(grants: offering)
        let second = reading(grants: ["second-grant"])
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

    /// A press names the kind of reset it spends, and one the reading no
    /// longer offers spends nothing rather than another kind in its place.
    func testAPressSpendsTheGrantItNamesAndNoOther() async {
        let spends = Spends([.success(.reset)])
        let probe = probe(spends)
        await probe.refresh {}

        let gone = await probe.useReset(offeredTo: "user-1", grant: "second-grant") {}
        let named = await probe.useReset(offeredTo: "user-1", grant: Self.grantID) {}

        XCTAssertEqual(gone, .noCredit)
        XCTAssertEqual(named, .reset)
        XCTAssertEqual(spends.requests.map(\.grantID), [Self.grantID])
        await probe.stop()
    }

    /// An unanswered press for one kind of reset is resent only by a press
    /// for that kind: a press for another kind is the user's choice of it,
    /// and resending the first under it would answer for a reset they did not
    /// pick.
    func testAnUnansweredAttemptIsResentOnlyForItsOwnGrant() async {
        let spends = Spends([.failure(URLError(.timedOut)), .success(.reset), .success(.alreadyUsed)])
        let world = World()
        let probe = probe(spends, world: world, offering: [Self.grantID, "fable-grant"])
        await probe.refresh {}

        _ = await probe.useReset(offeredTo: "user-1", grant: Self.grantID) {}
        let other = await probe.useReset(offeredTo: "user-1", grant: "fable-grant") {}
        let retried = await probe.useReset(offeredTo: "user-1", grant: Self.grantID) {}

        XCTAssertEqual(other, .reset)
        XCTAssertEqual(retried, .reset)
        let sent = spends.requests
        XCTAssertEqual(sent.map(\.grantID), [Self.grantID, "fable-grant", Self.grantID])
        XCTAssertEqual(sent[0].requestID, sent[2].requestID)
        XCTAssertNotEqual(sent[0].requestID, sent[1].requestID)
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
        signals.resets = LimitResets(
            available: 1, applicable: 1,
            grants: [
                LimitResetGrant(
                    id: Self.grantID, left: 1, appliesNow: false, expiry: nil, label: nil,
                    clears: [
                        ResetWindow(minutes: 300, scope: nil), ResetWindow(minutes: 10_080, scope: nil),
                    ],
                    givesBackWeekly: false)
            ])
        let slice = ProviderSlice(id: ProviderID.claudeCode, tokens: 0, cost: 0, signals: signals)
        let frame = FrameData(
            tokens: 0, cost: 0, burn: nil, providers: [slice], keepAwake: .off, history: [:],
            projects: [])
        let row = UsagePanelSnapshot.make(frame: frame).providers[0]
        XCTAssertEqual(
            row.reading.resetTarget, LimitResetTarget(provider: ProviderID.claudeCode, account: nil))
        let grant = row.reading.resets?.grants.first
        XCTAssertEqual(grant?.clears, ["Session", "Weekly"])
        XCTAssertEqual(grant?.caption, "Full reset")
        XCTAssertEqual(
            LimitResetCopy.confirmBody(
                available: 1, clears: grant?.clears ?? [], naturalReset: nil, appliesNow: false,
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
