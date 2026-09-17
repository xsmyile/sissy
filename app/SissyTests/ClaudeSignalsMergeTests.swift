import XCTest

@testable import Sissy

/// Which of Claude Code's two limit readers answers for the row.
///
/// Untested when it was written, which is how a merge that always preferred
/// the web source — built at launch whether or not it runs — took the OAuth
/// probe's windows off the panel for everyone who had not imported a session.
final class ClaudeSignalsMergeTests: XCTestCase {
    private func window(_ percent: Double) -> UsageWindow {
        UsageWindow(minutes: 300, usedPercent: percent, resetsAt: .distantFuture)!
    }

    private func signals(
        windows: [UsageWindow] = [],
        state: ProviderLimitsState = .quiet,
        observedAt: Date? = nil
    ) -> ProviderSignals {
        ProviderSignals(
            windows: windows, limitsState: state, limitsObservedAt: observedAt)
    }

    /// A block ends when the vendor said it would, whether or not a poll was
    /// able to go back and be refused again.
    ///
    /// The path that needs it: the sleep runs out, and the poll that follows
    /// cannot spend a request at all — an access token the CLI has not
    /// renewed, a keychain that did not answer — so it returns before
    /// reaching the endpoint and publishes nothing. Without this the row
    /// would go on naming a deadline in the past for as long as that lasted.
    func testAVendorBlockDoesNotOutliveTheDeadlineItNamed() {
        let now = Date()
        let expired = signals(state: .rateLimited(until: now.addingTimeInterval(-1)))

        XCTAssertEqual(expired.live(at: now).limitsState, .quiet)
    }

    func testAVendorBlockStandsUntilThatDeadline() {
        let now = Date()
        let standing = signals(state: .rateLimited(until: now.addingTimeInterval(60)))

        XCTAssertEqual(
            standing.live(at: now).limitsState, .rateLimited(until: now.addingTimeInterval(60)))
    }

    /// Every account's reading is given the same treatment for the reason its
    /// windows are: two rows drawn from one moment must not disagree.
    func testAnAccountsBlockExpiresWithTheRowsAbove() {
        let now = Date()
        var reading = signals()
        reading.accounts = [
            AccountSignals(
                id: "account", account: nil, plan: nil, planTier: nil,
                limitsState: .rateLimited(until: now.addingTimeInterval(-1)))
        ]

        XCTAssertEqual(reading.live(at: now).accounts.map(\.limitsState), [.quiet])
    }

    /// Both readers exist at launch. Which one answers is which one has read,
    /// never which one was constructed.
    func testTheProbeAnswersWhenNoSessionWasImported() {
        let merged = ClaudeCodeSignals.merge(
            profile: signals(),
            web: signals(),
            probe: signals(windows: [window(42)], observedAt: Date()))

        XCTAssertEqual(merged.windows.map(\.usedPercent), [42])
    }

    func testTheWebSourceAnswersWhenItIsTheOneRunning() {
        let merged = ClaudeCodeSignals.merge(
            profile: signals(),
            web: signals(windows: [window(80)], observedAt: Date()),
            probe: signals())

        XCTAssertEqual(merged.windows.map(\.usedPercent), [80])
    }

    /// The live reader owns the credits, including when it has none.
    ///
    /// The cached copy in `.claude.json` survives signing into a different
    /// account — measured 2026-09-15, a config naming a day-old account still
    /// carried the previous one's spend, in the previous one's currency. So a
    /// live reading that reports no spend has to take that figure off the row
    /// rather than let it fill in behind.
    func testALiveReaderWithNoCreditsTakesTheCachedOnesOffTheRow() {
        var profile = signals()
        profile.credits = cached

        let merged = ClaudeCodeSignals.merge(
            profile: profile,
            web: signals(),
            probe: signals(windows: [window(12)], observedAt: Date()))

        XCTAssertNil(merged.credits)
    }

    /// The same cached figure is the answer when nothing live is running,
    /// which is every user who never switched limits on.
    func testTheCachedCreditsStandWhenNoReaderIsRunning() {
        var profile = signals()
        profile.credits = cached

        let merged = ClaudeCodeSignals.merge(profile: profile, web: signals(), probe: signals())

        XCTAssertEqual(merged.credits, cached)
    }

    private var cached: ProviderCredits {
        ProviderCredits(
            isEnabled: true, unit: .money(currency: "EUR", exponent: 2),
            usedMinor: 35934, capMinor: 37500, observedAt: Date(timeIntervalSince1970: 0))
    }

    /// A reader that has produced nothing yet but has something to say about
    /// why still reaches the row: the notice is the only way back.
    func testAReaderWithNoReadingStillExplainsItself() {
        let merged = ClaudeCodeSignals.merge(
            profile: signals(),
            web: signals(),
            probe: signals(state: .needsAuthorization))

        XCTAssertEqual(merged.limitsState, .needsAuthorization)
    }

    /// The plan, the tier and the account come off the config file whichever
    /// reader answers for the windows — they cost no permission and are
    /// readable with limits switched off entirely.
    func testTheProfileKeepsTheIdentityWhicheverReaderAnswers() {
        var profile = signals()
        profile.plan = "max"
        let merged = ClaudeCodeSignals.merge(
            profile: profile,
            web: signals(windows: [window(10)], observedAt: Date()),
            probe: signals())

        XCTAssertEqual(merged.plan, "max")
    }

    /// Neither reader running leaves the row on the config file alone, with
    /// no windows and nothing to explain.
    func testNeitherReaderRunningLeavesTheProfileUntouched() {
        let merged = ClaudeCodeSignals.merge(
            profile: signals(), web: signals(), probe: signals())

        XCTAssertTrue(merged.windows.isEmpty)
        XCTAssertEqual(merged.limitsState, .quiet)
    }
}
