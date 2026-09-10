import ServiceManagement
import XCTest

@testable import Sissy

/// The panel's numbers and its "updated Ns ago" line are one reading, so they
/// hang off one gate. Once the daemon is gone that reading no longer exists:
/// the frame left behind describes a day nobody is counting, and the footer
/// keeps ageing a timestamp nothing will ever refresh.
@MainActor
final class SissyModelLiveFrameTests: XCTestCase {
    private static let landedAt = Date(timeIntervalSince1970: 1_789_000_000)

    /// Pins `SMAppService` to a plist the bundle does not carry, so
    /// `isRegistered` is false whatever agent is installed on the machine
    /// running the tests. Health then decides `isOn` on its own.
    private func makeModel() -> SissyModel {
        SissyModel(
            serverService: ServerServiceController(
                service: .agent(plistName: "com.radonforge.sissy.tests.absent.plist")
            )
        )
    }

    private func frame() -> DisplayFrame {
        DisplayFrame(
            tokens: "26K",
            cost: "0.09",
            burn: "1.5K",
            state: "code",
            ts: Int(Self.landedAt.timeIntervalSince1970),
            primary: "26K",
            primaryLabel: "TOKENS",
            devicePresent: true,
            milestone: nil,
            providers: [],
            prev: nil
        )
    }

    func testLastFrameIsWithheldOnceTheServerIsOff() {
        let model = makeModel()
        model.currentFrame = frame()
        model.lastFrameAt = Self.landedAt
        model.serverHealth.status = .down

        XCTAssertNil(model.liveFrame)
    }

    func testLiveFrameCarriesTheFrameAndWhenItLanded() {
        let model = makeModel()
        model.currentFrame = frame()
        model.lastFrameAt = Self.landedAt
        model.serverHealth.status = .up

        XCTAssertEqual(model.liveFrame?.at, Self.landedAt)
        XCTAssertEqual(model.liveFrame?.frame.state, "code")
        XCTAssertEqual(model.liveFrame?.frame.devicePresent, true)
    }

    /// A daemon that is up but has found no JSONL is still counting, so its
    /// last frame stays on screen.
    func testAnEmptyUsageReaderStillCountsAsRunning() {
        let model = makeModel()
        model.currentFrame = frame()
        model.lastFrameAt = Self.landedAt
        model.serverHealth.status = .usageReaderEmpty

        XCTAssertNotNil(model.liveFrame)
    }

    func testNoFrameYetReadsTheSameAsAStoppedServer() {
        let model = makeModel()
        model.serverHealth.status = .up

        XCTAssertNil(model.liveFrame)
    }
}
