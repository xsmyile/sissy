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
