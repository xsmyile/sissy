import ServiceManagement
import XCTest

@testable import Sissy

/// Sissy's face and the header's words are one signal: the eye is shut
/// exactly when the header says she is sleeping, and the second line says why
/// only while she is. Anything else and the panel contradicts the menu bar.
@MainActor
final class SissyModelHeaderTests: XCTestCase {
    /// Pins `SMAppService` to a plist the bundle does not carry, so
    /// `isRegistered` is false whatever agent is installed on the machine
    /// running the tests. Health then decides the rest on its own.
    private func makeModel() -> SissyModel {
        SissyModel(
            serverService: ServerServiceController(
                service: .agent(plistName: "com.radonforge.sissy.tests.absent.plist")
            )
        )
    }

    private func frame() -> FrameData {
        FrameData(
            tokens: "26K",
            cost: "0.09",
            burn: "1.5K",
            primary: "26K",
            primaryLabel: "TOKENS",
            providers: [],
            prevTokens: nil,
            prevCost: nil,
            keepAwake: .off
        )
    }

    func testAStoppedDaemonSleepsAndTheLineSaysWhy() {
        let model = makeModel()
        model.serverHealth.status = .down

        let snapshot = model.menuSnapshot

        XCTAssertTrue(snapshot.header.isAsleep)
        XCTAssertTrue(snapshot.statusIcon.isAsleep)
        XCTAssertEqual(snapshot.header.title, "Sissy is sleeping")
        XCTAssertEqual(snapshot.header.subtitle, "Server is off")
    }

    func testADaemonWithNothingToShowYetIsAwake() {
        let model = makeModel()
        model.serverHealth.status = .up

        let snapshot = model.menuSnapshot

        XCTAssertFalse(snapshot.header.isAsleep)
        XCTAssertFalse(snapshot.statusIcon.isAsleep)
        XCTAssertEqual(snapshot.header.title, "Looking for Sissy...")
        XCTAssertNil(snapshot.header.subtitle, "an awake Sissy owes the line back to the date")
    }

    func testAFrameOnALiveSocketNamesSissyAndNothingElse() {
        let model = makeModel()
        model.serverHealth.status = .up
        model.currentFrame = frame()
        model.webSocketClient.isConnected = true

        let snapshot = model.menuSnapshot

        XCTAssertFalse(snapshot.header.isAsleep)
        XCTAssertEqual(snapshot.header.title, "Sissy")
        XCTAssertNil(snapshot.header.subtitle)
    }
}
