import XCTest

@testable import Sissy

/// What the usage body names, read the way the vendor curates it.
final class ClaudeUsagePayloadTests: XCTestCase {
    private let reset = "2026-09-16T02:00:00.946202+00:00"

    /// `limits` is the only place the model-scoped weekly window appears, so
    /// reading the flat keys alone silently loses it — which is what happened.
    func testTakesTheModelScopedWindowOutOfLimits() {
        let windows = ClaudeUsagePayload.windows([
            "limits": [
                ["kind": "weekly_all", "percent": 100, "resets_at": reset],
                [
                    "kind": "weekly_scoped", "percent": 12, "resets_at": reset,
                    "scope": ["model": ["display_name": "Fable"]],
                ],
            ]
        ])
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows.map(\.scope), [nil, "Fable"])
        XCTAssertEqual(windows.map(\.usedPercent), [100, 12])
    }

    /// Two windows of the same length that count different things must stay
    /// two windows.
    func testTwoWeeklyWindowsAreNotOneWindow() {
        let windows = ClaudeUsagePayload.windows([
            "limits": [
                ["kind": "weekly_all", "percent": 100, "resets_at": reset],
                [
                    "kind": "weekly_scoped", "percent": 0, "resets_at": reset,
                    "scope": ["model": ["display_name": "Fable"]],
                ],
            ]
        ])
        XCTAssertEqual(Set(windows.map(\.minutes)), [10_080])
        XCTAssertEqual(
            Set(windows.map { UsageFormat.windowLabel(minutes: $0.minutes, scope: $0.scope) }),
            ["Weekly", "Weekly · Fable"])
    }

    /// A bucket nobody has started arrives with a null reset. That is a
    /// window at zero, not a window that does not exist — dropping it took
    /// the session row off the panel entirely until someone used it.
    func testABucketWithNoResetIsStillAWindow() {
        let windows = ClaudeUsagePayload.windows([
            "limits": [["kind": "session", "percent": 0, "resets_at": NSNull()]]
        ])
        XCTAssertEqual(windows.map(\.minutes), [300])
        XCTAssertNil(windows.first?.resetsAt)
    }

    /// A bucket with no percentage has nothing to draw and is dropped.
    func testABucketWithNoPercentageIsDropped() {
        let windows = ClaudeUsagePayload.windows([
            "limits": [["kind": "session", "resets_at": reset]]
        ])
        XCTAssertTrue(windows.isEmpty)
    }

    /// A kind this build cannot name a period for is skipped, not guessed at.
    func testAnUnknownKindIsSkipped() {
        let windows = ClaudeUsagePayload.windows([
            "limits": [["kind": "amber_ladder", "percent": 5, "resets_at": reset]]
        ])
        XCTAssertTrue(windows.isEmpty)
    }

    /// A payload from before `limits` still reads through the flat keys.
    func testFallsBackToTheFlatKeysWhenLimitsIsAbsent() {
        let windows = ClaudeUsagePayload.windows([
            "seven_day": ["utilization": 40.0, "resets_at": reset]
        ])
        XCTAssertEqual(windows.map(\.minutes), [10_080])
        XCTAssertNil(windows.first?.scope)
    }

    /// A kind renamed under `limits` used to answer with no windows at all,
    /// published as a fresh quiet reading with both flat buckets beside it.
    func testALimitsListThatMapsToNothingFallsBackToTheFlatKeys() {
        let windows = ClaudeUsagePayload.windows([
            "limits": [["kind": "amber_ladder", "percent": 5, "resets_at": reset]],
            "five_hour": ["utilization": 12.0, "resets_at": reset],
            "seven_day": ["utilization": 40.0, "resets_at": reset],
        ])
        XCTAssertEqual(windows.map(\.minutes), [300, 10_080])
        XCTAssertEqual(windows.map(\.usedPercent), [12, 40])
    }

    func testALimitsListThatMapsKeepsTheFlatKeysOut() {
        let windows = ClaudeUsagePayload.windows([
            "limits": [["kind": "session", "percent": 5, "resets_at": reset]],
            "seven_day": ["utilization": 40.0, "resets_at": reset],
        ])
        XCTAssertEqual(windows.map(\.minutes), [300])
    }

    /// The flat path used to drop a period nobody has started, where its own
    /// docstring and `UsageWindow.resetsAt` both call that a window at zero.
    func testAFlatBucketWithNoResetIsStillAWindow() {
        let windows = ClaudeUsagePayload.windows([
            "five_hour": ["utilization": 0.0, "resets_at": NSNull()]
        ])
        XCTAssertEqual(windows.map(\.minutes), [300])
        XCTAssertNil(windows.first?.resetsAt)
    }

    /// A model-scoped bucket naming no model would draw as a second plan-wide
    /// weekly gauge. The live scope is `{model, surface}`, so either half can
    /// be null.
    func testAScopedBucketNamingNoModelIsSkipped() {
        for scope: Any in [
            NSNull(),
            ["model": NSNull(), "surface": "cowork"],
            ["model": ["display_name": ""], "surface": NSNull()],
            ["model": ["display_name": NSNull()]],
        ] {
            let windows = ClaudeUsagePayload.windows([
                "limits": [
                    ["kind": "weekly_all", "percent": 100, "resets_at": reset],
                    ["kind": "weekly_scoped", "percent": 12, "resets_at": reset, "scope": scope],
                ]
            ])
            XCTAssertEqual(windows.count, 1)
            XCTAssertNil(windows.first?.scope)
        }
    }

    /// What the once-only log line names: the kinds that mapped to nothing,
    /// and the bucket-shaped keys only when the flat ones drew nothing.
    func testUnmappedNamesAreTheKindsAndTheBucketShapedKeys() {
        let listed: [[String: Any]] = [["kind": "amber_ladder"], ["kind": "NOT A TOKEN"]]
        let body: [String: Any] = [
            "ember_scale": ["utilization": 1.0],
            "spend": ["enabled": true],
        ]
        XCTAssertEqual(
            ClaudeUsagePayload.unmappedNames(listed: listed, flat: [], body: body),
            ["amber_ladder", "ember_scale"])
        let drawn = [UsageWindow(minutes: 300, usedPercent: 1, resetsAt: nil)!]
        XCTAssertEqual(
            ClaudeUsagePayload.unmappedNames(listed: listed, flat: drawn, body: body),
            ["amber_ladder"])
        XCTAssertEqual(
            ClaudeUsagePayload.unmappedNames(listed: [], flat: [], body: ["spend": [:]]), [])
    }

    // MARK: - The money

    private var spendBody: [String: Any] {
        [
            "spend": [
                "enabled": true,
                "used": ["amount_minor": 31_691, "currency": "EUR", "exponent": 2],
                "limit": ["amount_minor": 35_000, "currency": "EUR", "exponent": 2],
            ]
        ]
    }

    func testTheBalanceRidesBesideTheSpend() throws {
        let credits = try XCTUnwrap(
            ClaudeUsagePayload.credits(spendBody, observedAt: Date(), balanceMinor: 13_667))
        XCTAssertEqual(credits.usedMinor, 31_691)
        XCTAssertEqual(credits.balanceMinor, 13_667)
    }

    /// A source that cannot answer for the balance says nothing about it
    /// rather than reporting zero, which would read as an empty account.
    func testASourceWithoutABalanceReportsNone() throws {
        let credits = try XCTUnwrap(
            ClaudeUsagePayload.credits(spendBody, observedAt: Date()))
        XCTAssertNil(credits.balanceMinor)
    }

    func testReadsTheBalanceOffThePrepaidReply() {
        let body: [String: Any] = [
            "balance": ["money": ["amount_minor": 13_667, "currency": "EUR", "exponent": 2]]
        ]
        XCTAssertEqual(ClaudeUsagePayload.balance(body, currency: "EUR"), 13_667)
    }

    /// A balance in another currency is not this account's headroom, and
    /// showing it beside a spend in euros would be adding two things.
    func testABalanceInAnotherCurrencyIsNotRead() {
        let body: [String: Any] = [
            "balance": ["money": ["amount_minor": 100, "currency": "USD", "exponent": 2]]
        ]
        XCTAssertNil(ClaudeUsagePayload.balance(body, currency: "EUR"))
    }
}
