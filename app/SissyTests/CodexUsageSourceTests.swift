import XCTest

@testable import Sissy

/// What OpenAI's usage reply turns into, and which of the two Codex readings
/// the row ends up on.
final class CodexUsageSourceTests: XCTestCase {
    /// The reply as measured 2026-09-17, with the address replaced.
    ///
    /// Parsed from text rather than written as a dictionary, because the
    /// difference is the thing under test: `JSONSerialization` answers with
    /// `NSNumber`, which bridges an integer percentage to `Double`, while a
    /// Swift literal answers with `Int`, which does not. A fixture built by
    /// hand passes against a parser the vendor's own bytes would defeat.
    private static func reply() -> [String: Any] {
        body(
            """
            {
              "account_id": "7c31482a-768d-4750-8521-cd39b2669767",
              "email": "someone@example.com",
              "plan_type": "plus",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 32,
                  "limit_window_seconds": 18000,
                  "reset_at": 1789651044
                },
                "secondary_window": {
                  "used_percent": 54.5,
                  "limit_window_seconds": 604800,
                  "reset_at": 1789924239
                }
              },
              "credits": {"has_credits": false, "unlimited": false, "balance": "0"}
            }
            """)
    }

    private static func body(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    private static func credential(expiresAt: Date? = nil) -> CodexCredential {
        CodexCredential(
            accessToken: "token", refreshToken: nil, idToken: nil,
            accountId: "7c31482a-768d-4750-8521-cd39b2669767", userId: "user-1",
            email: "someone@example.com", plan: "plus", expiresAt: expiresAt)
    }

    private static func source(
        account: String? = nil,
        credential: @escaping @Sendable (Bool) async -> CodexCredentialReading,
        fetch: @escaping @Sendable (CodexCredential) async throws -> CodexUsagePayload.Reading
    ) -> CodexUsageSource {
        CodexUsageSource(account: account, credentialSource: credential, fetchSource: fetch)
    }

    // MARK: - The payload

    func testReadsBothWindowsInMinutes() {
        let reading = CodexUsagePayload.reading(Self.reply(), observedAt: Date())
        XCTAssertEqual(reading.windows.map(\.minutes), [300, 10_080])
        XCTAssertEqual(reading.windows.map(\.usedPercent), [32, 54.5])
        XCTAssertEqual(
            reading.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_789_651_044))
    }

    func testReadsThePlanTheAccountAndTheBalance() {
        let reading = CodexUsagePayload.reading(Self.reply(), observedAt: Date())
        XCTAssertEqual(reading.plan, "plus")
        XCTAssertEqual(reading.accountId, "7c31482a-768d-4750-8521-cd39b2669767")
        XCTAssertEqual(reading.account?.email, "someone@example.com")
        XCTAssertEqual(reading.credits?.balanceMinor, 0)
    }

    /// The period is what the panel words the window with, so one that does
    /// not come to whole minutes is dropped rather than rounded into a period
    /// the vendor never named.
    func testDropsAWindowWhoseLengthIsNotWholeMinutes() {
        let body = Self.body(
            """
            {"rate_limit": {"primary_window":
              {"used_percent": 10, "limit_window_seconds": 90, "reset_at": 1}}}
            """)
        XCTAssertTrue(CodexUsagePayload.windows(body).isEmpty)
    }

    /// A period nobody has started yet arrives with no reset. That is a window
    /// at zero, not a window that does not exist.
    func testKeepsAWindowWithNoReset() {
        let body = Self.body(
            """
            {"rate_limit": {"primary_window":
              {"used_percent": 0, "limit_window_seconds": 18000}}}
            """)
        let windows = CodexUsagePayload.windows(body)
        XCTAssertEqual(windows.count, 1)
        XCTAssertNil(windows.first?.resetsAt)
    }

    // MARK: - Which of the two readings the row takes

    private static func rollout(at observedAt: Date, percent: Double) -> ProviderSignals {
        var signals = ProviderSignals()
        signals.windows = [UsageWindow(minutes: 300, usedPercent: percent, resetsAt: nil)!]
        signals.limitsObservedAt = observedAt
        signals.plan = "plus"
        return signals
    }

    private static func live(at observedAt: Date, percent: Double) -> ProviderSignals {
        var signals = ProviderSignals()
        signals.windows = [UsageWindow(minutes: 300, usedPercent: percent, resetsAt: nil)!]
        signals.limitsObservedAt = observedAt
        return signals
    }

    func testTheLaterReadingWins() {
        let turn = Date(timeIntervalSince1970: 1000)
        let poll = Date(timeIntervalSince1970: 2000)
        let merged = CodexSignals.merge(
            rollout: Self.rollout(at: turn, percent: 30),
            live: Self.live(at: poll, percent: 32))
        XCTAssertEqual(merged.windows.first?.usedPercent, 32)
        XCTAssertEqual(merged.limitsObservedAt, poll)
    }

    /// The turns keep the row when the reader has nothing newer, which is what
    /// a Mac that has been offline since the last turn looks like.
    func testAnOlderPollDoesNotDisplaceTheTurns() {
        let turn = Date(timeIntervalSince1970: 3000)
        let merged = CodexSignals.merge(
            rollout: Self.rollout(at: turn, percent: 30),
            live: Self.live(at: Date(timeIntervalSince1970: 2000), percent: 12))
        XCTAssertEqual(merged.windows.first?.usedPercent, 30)
        XCTAssertEqual(merged.limitsObservedAt, turn)
    }

    /// A reader that has stopped keeps nothing, and the row falls back to the
    /// turns with no memory of what the reader used to say.
    func testAStoppedReaderHandsTheRowBackToTheTurns() {
        let turn = Date(timeIntervalSince1970: 3000)
        let merged = CodexSignals.merge(
            rollout: Self.rollout(at: turn, percent: 30), live: ProviderSignals())
        XCTAssertEqual(merged.windows.first?.usedPercent, 30)
        XCTAssertEqual(merged.limitsState, .quiet)
    }

    /// Why there is nothing newer is the reader's answer and nobody else's,
    /// so it crosses even when its reading does not.
    func testTheReaderStateReachesTheRowWhateverTheWindowsDo() {
        var live = ProviderSignals()
        live.limitsState = .sessionExpired
        let merged = CodexSignals.merge(
            rollout: Self.rollout(at: Date(), percent: 30), live: live)
        XCTAssertEqual(merged.limitsState, .sessionExpired)
        XCTAssertEqual(merged.windows.count, 1)
    }

    // MARK: - One poll

    func testAPollPublishesTheReading() async {
        let source = Self.source(
            credential: { _ in .found(Self.credential()) },
            fetch: { _ in CodexUsagePayload.reading(Self.reply(), observedAt: Date()) })
        _ = await source.refreshOnce {}
        let signals = source.currentSignals()
        XCTAssertEqual(signals.windows.map(\.minutes), [300, 10_080])
        XCTAssertEqual(signals.plan, "plus")
        XCTAssertNotNil(signals.limitsObservedAt)
        XCTAssertEqual(source.observedAccount, "user-1")
    }

    /// A linked credential the vendor has retired says so on the row, and
    /// keeps the windows: the last reading and its age are still true, and the
    /// turns are still writing them.
    func testARefusedCredentialSaysSoAndKeepsTheWindows() async {
        let refuse = LockedValue(false)
        let source = Self.source(
            account: "user-1",
            credential: { _ in .found(Self.credential()) },
            fetch: { _ in
                if refuse.load() { throw UsageRequestError.badStatus(401) }
                return CodexUsagePayload.reading(Self.reply(), observedAt: Date())
            })
        _ = await source.refreshOnce {}
        refuse.store(true)
        _ = await source.refreshOnce {}
        XCTAssertEqual(source.currentSignals().limitsState, .sessionExpired)
        XCTAssertFalse(source.currentSignals().windows.isEmpty)
    }

    // MARK: - A linked token refused early

    private static let renewedToken = "token-renewed"

    private static func renewedCredential() -> CodexCredential {
        CodexCredential(
            accessToken: renewedToken, refreshToken: nil, idToken: nil,
            accountId: "7c31482a-768d-4750-8521-cd39b2669767", userId: "user-1",
            email: "someone@example.com", plan: "plus", expiresAt: nil)
    }

    private static func linkedSource(
        renewal: @escaping @Sendable (CodexCredential) async -> CodexCredentialReading,
        fetch: @escaping @Sendable (CodexCredential) async throws -> CodexUsagePayload.Reading
    ) -> CodexUsageSource {
        CodexUsageSource(
            account: "user-1", credentialSource: { _ in .found(Self.credential()) },
            renewRefused: renewal, fetchSource: fetch)
    }

    /// OpenAI can revoke an access token before its expiry while the refresh
    /// token behind it is still good, so a refusal is one renewal and one
    /// read away from a reading rather than from Link again.
    func testARefusedLinkedReadIsRenewedAndReadAgain() async {
        let renewals = LockedValue(0)
        let reads = LockedValue(0)
        let source = Self.linkedSource(
            renewal: { _ in
                renewals.update { $0 += 1 }
                return .found(Self.renewedCredential())
            },
            fetch: { credential in
                reads.update { $0 += 1 }
                guard credential.accessToken == Self.renewedToken else {
                    throw UsageRequestError.badStatus(401)
                }
                return CodexUsagePayload.reading(Self.reply(), observedAt: Date())
            })
        _ = await source.refreshOnce {}
        XCTAssertEqual(source.currentSignals().limitsState, .quiet)
        XCTAssertFalse(source.currentSignals().windows.isEmpty)
        XCTAssertEqual(renewals.load(), 1)
        XCTAssertEqual(reads.load(), 2)
    }

    func testARefusedLinkedReadWhoseRenewalIsRejectedEndsTheLink() async {
        let reads = LockedValue(0)
        let source = Self.linkedSource(
            renewal: { _ in .expired },
            fetch: { _ in
                reads.update { $0 += 1 }
                throw UsageRequestError.badStatus(403)
            })
        _ = await source.refreshOnce {}
        XCTAssertEqual(source.currentSignals().limitsState, .sessionExpired)
        XCTAssertEqual(reads.load(), 1)
    }

    /// A renewed token the vendor refuses too is a link that has ended, and
    /// the poll says so rather than renewing again: one renewal, one retry.
    func testARenewedTokenRefusedAgainEndsTheLinkWithoutLooping() async {
        let renewals = LockedValue(0)
        let reads = LockedValue(0)
        let source = Self.linkedSource(
            renewal: { _ in
                renewals.update { $0 += 1 }
                return .found(Self.renewedCredential())
            },
            fetch: { _ in
                reads.update { $0 += 1 }
                throw UsageRequestError.badStatus(401)
            })
        _ = await source.refreshOnce {}
        XCTAssertEqual(source.currentSignals().limitsState, .sessionExpired)
        XCTAssertEqual(renewals.load(), 1)
        XCTAssertEqual(reads.load(), 2)
    }

    /// A renewal that could not reach OpenAI says nothing about the grant, so
    /// the row keeps its reading rather than asking for a new link.
    func testARefusedLinkedReadWhoseRenewalIsDeferredKeepsTheReading() async {
        let refuse = LockedValue(false)
        let source = Self.linkedSource(
            renewal: { _ in .unreadable("the Codex renewal did not get an answer") },
            fetch: { _ in
                if refuse.load() { throw UsageRequestError.badStatus(401) }
                return CodexUsagePayload.reading(Self.reply(), observedAt: Date())
            })
        _ = await source.refreshOnce {}
        refuse.store(true)
        _ = await source.refreshOnce {}
        XCTAssertEqual(source.currentSignals().limitsState, .quiet)
        XCTAssertFalse(source.currentSignals().windows.isEmpty)
    }

    /// The CLI's own credential is `codex login`'s to replace, so a refusal
    /// of it is not a sign-in Sissy can offer to redo: linking would add a
    /// second account and leave this row refused.
    func testARefusedCLICredentialIsTheCLIsToRenew() async {
        let source = Self.source(
            credential: { _ in .found(Self.credential()) },
            fetch: { _ in throw UsageRequestError.badStatus(401) })
        _ = await source.refreshOnce {}
        XCTAssertEqual(source.currentSignals().limitsState, .credentialRefused)
    }

    /// A refusal from the host OpenAI redirected to was a refusal of a
    /// request carrying no token, so the credential is not reported spent.
    func testARefusalFromAnotherHostIsNotASpentCredential() async {
        let refuse = LockedValue(false)
        let source = Self.source(
            credential: { _ in .found(Self.credential()) },
            fetch: { _ in
                if refuse.load() { throw SissyHTTP.LeftItsOrigin(status: 403) }
                return CodexUsagePayload.reading(Self.reply(), observedAt: Date())
            })
        _ = await source.refreshOnce {}
        refuse.store(true)
        _ = await source.refreshOnce {}
        XCTAssertNotEqual(source.currentSignals().limitsState, .sessionExpired)
        XCTAssertFalse(source.currentSignals().windows.isEmpty)
    }

    func testA429BacksOffAndNamesWhen() async {
        let source = Self.source(
            credential: { _ in .found(Self.credential()) },
            fetch: { _ in throw UsageRequestError.rateLimited(retryAfter: 600) })
        let delay = await source.refreshOnce {}
        XCTAssertEqual(delay, .seconds(600))
        guard case .rateLimited = source.currentSignals().limitsState else {
            return XCTFail("a 429 has to reach the row")
        }
    }

    /// An expired token is not a signed-out account: something else renews it,
    /// so the row keeps its last reading rather than blanking.
    func testAnExpiredTokenIsNotSpentAndKeepsTheReading() async {
        let expired = LockedValue(false)
        let source = Self.source(
            credential: { _ in
                .found(Self.credential(expiresAt: expired.load() ? .distantPast : nil))
            },
            fetch: { _ in
                if expired.load() { throw UsageRequestError.badStatus(401) }
                return CodexUsagePayload.reading(Self.reply(), observedAt: Date())
            })
        _ = await source.refreshOnce {}
        expired.store(true)
        // Through `refresh` rather than another poll, because that is the
        // gesture that drops the held credential and reads the file again —
        // which is where an expiry can be noticed at all.
        await source.refresh {}
        XCTAssertEqual(source.currentSignals().limitsState, .quiet)
        XCTAssertFalse(source.currentSignals().windows.isEmpty)
        await source.retire()
    }

    /// `codex login` as another account rewrites `auth.json`, and its tokens
    /// live ten days. A reader that held the first credential it saw would go
    /// on asking OpenAI about the account the user left, under the name the
    /// tail had already moved on to, for the rest of that token's life.
    func testACredentialSwappedUnderTheReaderIsNoticedOnTheNextPoll() async {
        let account = LockedValue("user-one")
        let source = Self.source(
            credential: { _ in
                .found(
                    CodexCredential(
                        accessToken: "token", refreshToken: nil, idToken: nil,
                        accountId: "7c31482a", userId: account.load(), email: nil,
                        plan: nil, expiresAt: nil))
            },
            fetch: { _ in CodexUsagePayload.reading(Self.reply(), observedAt: Date()) })
        _ = await source.refreshOnce {}
        XCTAssertEqual(source.observedAccount, "user-one")

        account.store("user-two")
        _ = await source.refreshOnce {}
        XCTAssertEqual(source.observedAccount, "user-two")
    }

    /// Codex signed out, or driving the API with a key, is an account with no
    /// limits rather than a reading Sissy failed to take.
    func testASignedOutCodexTakesTheGaugesDown() async {
        let source = Self.source(
            credential: { _ in .signedOut },
            fetch: { _ in
                XCTFail("nothing to spend")
                throw UsageRequestError.malformedPayload
            })
        _ = await source.refreshOnce {}
        XCTAssertEqual(source.currentSignals().limitsState, .signedOut)
        XCTAssertTrue(source.currentSignals().windows.isEmpty)
    }
}
