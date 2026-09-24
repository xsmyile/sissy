import XCTest

@testable import Sissy

/// What OpenAI says about a Codex account's resets, and how a press spends one.
final class CodexResetCreditsTests: XCTestCase {
    private static func body(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    /// The usage reply as measured 2026-09-24, windows at 29% and 83%.
    private static func usageReply(resets: String) -> [String: Any] {
        body(
            """
            {
              "plan_type": "plus",
              "rate_limit": {
                "allowed": true, "limit_reached": false,
                "primary_window": {"used_percent": 29, "limit_window_seconds": 18000, "reset_at": 1790277824},
                "secondary_window": {"used_percent": 83, "limit_window_seconds": 604800, "reset_at": 1790529786}
              },
              "rate_limit_reset_credits": \(resets)
            }
            """)
    }

    /// The list as measured 2026-09-24, with a second and a spent reset added.
    private static func list() -> [String: Any] {
        body(
            """
            {
              "credits": [
                {"id": "never", "reset_type": "codex_rate_limits", "status": "available",
                 "granted_at": "2026-09-01T00:00:00Z", "expires_at": null},
                {"id": "RateLimitResetCredit_fce6", "reset_type": "codex_rate_limits",
                 "is_supported_by_plan": true, "status": "available",
                 "granted_at": "2026-09-22T18:31:37.448566Z", "expires_at": "2026-10-22T18:31:37.448566Z",
                 "redeem_started_at": null, "redeemed_at": null,
                 "title": "Full reset (Weekly + 5 hr)",
                 "description": "Thanks for using Codex! You've been granted one free rate limit reset."},
                {"id": "spent", "reset_type": "codex_rate_limits", "status": "redeemed",
                 "granted_at": "2026-09-02T00:00:00Z", "expires_at": "2026-10-01T00:00:00Z"},
                {"id": "lapsed", "reset_type": "codex_rate_limits", "status": "available",
                 "granted_at": "2026-08-01T00:00:00Z", "expires_at": "2026-09-01T00:00:00Z"}
              ],
              "available_count": 3,
              "total_earned_count": 0
            }
            """)
    }

    private static let now = Date(timeIntervalSince1970: 1_790_200_000)

    // MARK: - The count

    func testReadsTheCountAndWhatTheVendorWouldApplyNow() {
        let resets = CodexResetCredits.summary(
            Self.usageReply(resets: #"{"available_count": 1, "applicable_available_count": 0}"#))
        XCTAssertEqual(resets?.available, 1)
        XCTAssertEqual(resets?.applicable, 0)
        XCTAssertEqual(resets?.usable, 0)
    }

    /// A reply that names no applicable count is read the way OpenAI's desktop
    /// client reads it: the whole inventory.
    func testWithoutAnApplicableCountEveryResetIsUsable() {
        let resets = CodexResetCredits.summary(
            Self.usageReply(resets: #"{"available_count": 2}"#))
        XCTAssertNil(resets?.applicable)
        XCTAssertEqual(resets?.usable, 2)
    }

    /// No block is an account nobody knows about, never a zero.
    func testAnAbsentOrMalformedBlockIsNoReading() {
        XCTAssertNil(CodexResetCredits.summary(Self.usageReply(resets: "null")))
        XCTAssertNil(
            CodexResetCredits.summary(Self.usageReply(resets: #"{"available_count": -1}"#)))
        XCTAssertNil(
            CodexResetCredits.summary(Self.usageReply(resets: #"{"available_count": "1"}"#)))
    }

    func testTheUsageReadingCarriesTheCount() {
        let reading = CodexUsagePayload.reading(
            Self.usageReply(resets: #"{"available_count": 1, "applicable_available_count": 0}"#),
            observedAt: Date())
        XCTAssertEqual(reading.resets, LimitResets(available: 1, applicable: 0))
    }

    // MARK: - The list

    func testTheListOffersWhatIsStillAvailableSoonestToLapseFirst() {
        let credits = CodexResetCredits.credits(Self.list(), now: Self.now)
        XCTAssertEqual(credits.map(\.id), ["RateLimitResetCredit_fce6", "never"])
        XCTAssertEqual(credits.first?.title, "Full reset (Weekly + 5 hr)")
        XCTAssertEqual(
            credits.first?.expiresAt?.timeIntervalSince1970 ?? 0, 1_792_693_897.448566,
            accuracy: 0.001)
        XCTAssertNil(credits.last?.expiresAt)
    }

    func testTheVendorsFourAnswers() {
        let answers = ["reset", "already_redeemed", "nothing_to_reset", "no_credit", "other"].map {
            CodexResetCredits.answer(["code": $0, "windows_reset": 2])
        }
        XCTAssertEqual(answers, [.reset, .alreadyRedeemed, .nothingToReset, .noCredit, nil])
    }

    /// `already_redeemed` is the vendor saying an earlier attempt under the
    /// same request id already did it.
    func testAnAlreadyRedeemedRequestIsAReset() {
        XCTAssertEqual(CodexResetOutcome(.alreadyRedeemed), .reset)
        XCTAssertEqual(CodexResetOutcome(.reset), .reset)
    }

    // MARK: - Which reading the row takes

    /// The rollouts never carry a count, so the reader's is the row's even
    /// when its windows lose to a newer turn.
    func testTheResetsCrossEvenWhenTheTurnIsNewer() throws {
        var rollout = ProviderSignals()
        rollout.windows = [try XCTUnwrap(UsageWindow(minutes: 300, usedPercent: 30, resetsAt: nil))]
        rollout.limitsObservedAt = Date(timeIntervalSince1970: 3000)
        var live = ProviderSignals()
        live.windows = [try XCTUnwrap(UsageWindow(minutes: 300, usedPercent: 12, resetsAt: nil))]
        live.limitsObservedAt = Date(timeIntervalSince1970: 2000)
        live.resets = LimitResets(available: 1, applicable: 0)
        let merged = CodexSignals.merge(rollout: rollout, live: live)
        XCTAssertEqual(merged.windows.first?.usedPercent, 30)
        XCTAssertEqual(merged.resets?.available, 1)
    }

    // MARK: - A poll

    private static func credential() -> CodexCredential {
        CodexCredential(
            accessToken: "token", refreshToken: nil, idToken: nil,
            accountId: "7c31482a-768d-4750-8521-cd39b2669767", userId: "user-1",
            email: "someone@example.com", plan: "plus", expiresAt: nil)
    }

    /// Every spend a stubbed reader was asked for, in order.
    private final class Spends: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(requestID: String, creditID: String?)] = []

        func record(_ requestID: String, _ creditID: String?) {
            lock.withLock { calls.append((requestID, creditID)) }
        }

        var requestIDs: [String] { lock.withLock { calls.map(\.requestID) } }
        var creditIDs: [String?] { lock.withLock { calls.map(\.creditID) } }
    }

    private static func source(
        resets: String = #"{"available_count": 1, "applicable_available_count": 1}"#,
        credential: CodexCredentialReading = .found(credential()),
        interactions: LockedValue<[Bool]> = LockedValue([]),
        lists: LockedValue<Int> = LockedValue(0),
        list: @escaping @Sendable () throws -> [CodexResetCredits.Credit] = {
            CodexResetCredits.credits(CodexResetCreditsTests.list(), now: CodexResetCreditsTests.now)
        },
        spends: Spends = Spends(),
        answer: @escaping @Sendable (Int) throws -> CodexResetCredits.Answer = { _ in .reset }
    ) -> CodexUsageSource {
        CodexUsageSource(
            credentialSource: { interactive in
                interactions.update { $0.append(interactive) }
                return credential
            },
            fetchSource: { _ in
                CodexUsagePayload.reading(usageReply(resets: resets), observedAt: Date())
            },
            creditsSource: { _ in
                lists.update { $0 += 1 }
                return try list()
            },
            consumeSource: { _, requestID, creditID in
                spends.record(requestID, creditID)
                return try answer(spends.requestIDs.count)
            })
    }

    func testAPollDatesTheSoonestReset() async {
        let source = Self.source()
        _ = await source.refreshOnce {}
        let resets = source.currentSignals().resets
        XCTAssertEqual(resets?.available, 1)
        XCTAssertEqual(resets?.title, "Full reset (Weekly + 5 hr)")
        XCTAssertNotNil(resets?.nextExpiry)
    }

    /// The list is a second request, and an account that holds nothing never
    /// pays for it.
    func testAnAccountWithNoResetsIsNotAskedForTheList() async {
        let lists = LockedValue(0)
        let source = Self.source(resets: #"{"available_count": 0}"#, lists: lists)
        _ = await source.refreshOnce {}
        XCTAssertEqual(source.currentSignals().resets?.available, 0)
        XCTAssertEqual(lists.load(), 0)
    }

    /// The count is the row's answer and the list only dates it, so a list
    /// that fails costs the caption and never the count.
    func testAListThatFailsKeepsTheCount() async {
        let source = Self.source(list: { throw UsageRequestError.badStatus(500) })
        _ = await source.refreshOnce {}
        let resets = source.currentSignals().resets
        XCTAssertEqual(resets?.available, 1)
        XCTAssertNil(resets?.nextExpiry)
    }

    // MARK: - A press

    func testAPressSpendsTheSoonestResetTheListNamed() async {
        let spends = Spends()
        let source = Self.source(spends: spends)
        _ = await source.refreshOnce {}
        let outcome = await source.useReset(retrying: false) {}
        await source.stop()
        XCTAssertEqual(outcome, .reset)
        XCTAssertEqual(spends.creditIDs, ["RateLimitResetCredit_fce6"])
    }

    /// An answer that never arrived may still have spent the reset, so the
    /// retry carries the same request id and the vendor redeems it once.
    func testARetryAfterNoAnswerSendsTheSameRequest() async {
        let spends = Spends()
        let source = Self.source(
            spends: spends,
            answer: { call in
                if call == 1 { throw URLError(.timedOut) }
                return .alreadyRedeemed
            })
        let first = await source.useReset(retrying: false) {}
        let retry = await source.useReset(retrying: true) {}
        await source.stop()
        XCTAssertEqual(first, .unconfirmed)
        XCTAssertEqual(retry, .reset)
        XCTAssertEqual(spends.requestIDs.count, 2)
        XCTAssertEqual(spends.requestIDs.first, spends.requestIDs.last)
    }

    /// Only the retry reuses the id: a fresh press is a fresh request, and an
    /// answered one is never sent again.
    func testAFreshPressIsAFreshRequest() async {
        let spends = Spends()
        let source = Self.source(
            spends: spends,
            answer: { call in
                if call == 1 { throw URLError(.timedOut) }
                return .nothingToReset
            })
        _ = await source.useReset(retrying: false) {}
        _ = await source.useReset(retrying: false) {}
        _ = await source.useReset(retrying: true) {}
        await source.stop()
        XCTAssertEqual(Set(spends.requestIDs).count, 3)
    }

    func testARefusedCredentialIsNotAnUnconfirmedSpend() async {
        let source = Self.source(answer: { _ in throw UsageRequestError.badStatus(401) })
        let outcome = await source.useReset(retrying: false) {}
        await source.stop()
        XCTAssertEqual(outcome, .refused)
    }

    func testNoCredentialSpendsNothing() async {
        let spends = Spends()
        let source = Self.source(credential: .signedOut, spends: spends)
        let outcome = await source.useReset(retrying: false) {}
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertTrue(spends.requestIDs.isEmpty)
    }

    /// A spend is not the moment to put a keychain dialog up, and neither is
    /// the read that follows it.
    func testAPressNeverAsksForTheKeychain() async {
        let interactions = LockedValue<[Bool]>([])
        let source = Self.source(interactions: interactions)
        _ = await source.useReset(retrying: false) {}
        await source.stop()
        XCTAssertEqual(interactions.load(), [false, false])
    }

    /// An account unlinked while its spend was in flight keeps no poll loop:
    /// the read after the answer is the one place a press could start one.
    func testAReaderRetiredDuringASpendStaysRetired() async {
        let box = LockedValue<CodexUsageSource?>(nil)
        let retiring = CodexUsageSource(
            credentialSource: { _ in .found(Self.credential()) },
            fetchSource: { _ in
                CodexUsagePayload.reading(
                    Self.usageReply(resets: #"{"available_count": 1}"#), observedAt: Date())
            },
            consumeSource: { _, _, _ in
                await box.load()?.retire()
                return .reset
            })
        box.store(retiring)
        let outcome = await retiring.useReset(retrying: false) {}
        XCTAssertEqual(outcome, .reset)
        XCTAssertNil(retiring.currentSignals().limitsObservedAt)
    }

    /// The answer and the cleared windows reach the panel together: the press
    /// reads the account again before it returns.
    func testAPressReadsTheAccountAgain() async {
        let refreshed = LockedValue(0)
        let source = Self.source()
        _ = await source.useReset(retrying: false) { refreshed.update { $0 += 1 } }
        let observedAt = source.currentSignals().limitsObservedAt
        await source.stop()
        XCTAssertNotNil(observedAt)
        XCTAssertEqual(refreshed.load(), 1)
    }
}
