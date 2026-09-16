import XCTest

@testable import Sissy

/// The hooks switch against the app going away.
///
/// Registering the hook writes two other programs' configuration files, and
/// `stop()` joins the pass it finds before tearing the engine down. A pass
/// started inside that join is one nothing awaits and nothing can cancel: the
/// process exits on `applicationShouldTerminate`'s reply, which can land
/// between the two targets and leave one CLI registered and the other not.
///
/// Refusing to start is the recoverable end of it — an install is re-affirmed
/// at the next launch, a removal is retried from `agentHooksRemovalPending` —
/// so the refusal is the fix rather than a cancellation.
@MainActor
final class AgentHooksTeardownTests: XCTestCase {

    /// The Settings switch, flipped inside the window where `stop()` is
    /// suspended on the pass it joined. The published flag goes nowhere with
    /// it: nothing is written after this point, and a switch showing the
    /// position it was moved to claims a configuration that is not on disk.
    func testTheSwitchIsRefusedOnceTeardownHasBegun() async {
        let host = UsageEngineHost()

        await host.stop()
        host.setAgentHooks(true)

        XCTAssertFalse(host.agentHooks)
    }

    /// The same gesture before teardown, so the refusal above is read as the
    /// stop rather than as a host with nothing wired to it.
    func testTheSwitchIsTakenWhileTheAppIsRunning() {
        let host = UsageEngineHost()

        host.setAgentHooks(true)

        XCTAssertTrue(host.agentHooks)
    }
}
