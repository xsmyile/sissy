import XCTest

@testable import Sissy

/// The hooks switch where the pass behind it cannot run.
///
/// Registering the hook rewrites two other programs' configuration files, so
/// where this switch sits is a claim about files Sissy does not own. Two
/// windows on this object leave the pass unable to start: `stop()` suspended
/// on the pass it joined, and the stretch a provider switch spends with the
/// engine already released. In both, the flip has to go nowhere rather than be
/// published against nothing — a dropped *off* otherwise says two other
/// programs have stopped running Sissy's line while they have not, and the
/// next launch re-affirms from the file and undoes the click.
///
/// From outside the class the two windows are one behaviour. A host with no
/// engine is the only shape a test can build without starting a real one
/// against this machine's own trees, so what is pinned here is that no flip is
/// shown that was not written, never which of the two guards refused it.
@MainActor
final class AgentHooksTeardownTests: XCTestCase {

    /// `releaseEngine` clears the engine before awaiting the stop it is built
    /// on, and the General tab's switch is not disabled while a provider
    /// switch runs — so this window is reachable by a click.
    func testAFlipThatCannotReachThePassIsNotPublished() {
        let host = UsageEngineHost()

        host.setAgentHooks(true)

        XCTAssertFalse(host.agentHooks)
    }
}
