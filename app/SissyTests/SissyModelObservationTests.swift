import Observation
import XCTest

@testable import Sissy

/// `AGENTS.md`'s rule that a surface not on screen costs nothing, for the two
/// that outlive the panel: the menu bar and Settings. A frame that changes
/// only what they do not draw must not wake them.
@MainActor
final class SissyModelObservationTests: XCTestCase {
    private final class Fired: @unchecked Sendable {
        var value = false
    }

    private func frame(
        tokens: Int = 1,
        keepAwake: KeepAwakeState = .off,
        pressure: MacHealthLevel? = nil,
        providers: [ProviderSlice] = [],
        forge: [ForgeActivityReading] = []
    ) -> FrameData {
        FrameData(
            tokens: tokens, cost: Decimal(tokens), burn: nil, providers: providers,
            keepAwake: keepAwake,
            forge: forge,
            mac: pressure.map {
                MacHealthReading(
                    observedAt: Date(timeIntervalSince1970: 1_790_000_000), pressure: $0,
                    freeMemoryPercent: 75, swap: nil, loadAverage: nil, activeCores: 12,
                    uptime: 86_400, heaviest: nil)
            })
    }

    /// How many of `frames` fire an observer of what `read` reads, re-armed
    /// before each one the way `StatusItemController.observeModel` re-arms.
    private func fires(
        across frames: [FrameData], on model: SissyModel, read: @escaping () -> Void
    ) -> Int {
        frames.count { frame in
            let fired = Fired()
            withObservationTracking(read) { fired.value = true }
            model.applyFrame(frame)
            return fired.value
        }
    }

    private func accounts(_ percent: Double) -> [ProviderSlice] {
        let window = UsageWindow(minutes: 300, usedPercent: percent, resetsAt: .distantFuture)
        var signals = ProviderSignals()
        signals.accounts = [
            AccountSignals(
                id: "a1b2c3d4", account: nil, plan: nil, planTier: nil,
                windows: [window].compactMap { $0 })
        ]
        return [ProviderSlice(id: ProviderID.claudeCode, tokens: 1, cost: 1, signals: signals)]
    }

    private func forgeReading(readAt: TimeInterval) -> ForgeActivityReading {
        ForgeActivityReading(
            id: "connection", kind: .gitHub, host: "github.com", login: nil,
            activity: ForgeActivity(
                contributions: [:], merged: [:], issues: [:], comments: [:],
                contributionsBoundedToOneYear: true),
            readAt: Date(timeIntervalSince1970: readAt), failure: nil)
    }

    func testAFrameThatChangesNothingTheMenuBarDrawsDoesNotWakeIt() {
        let model = SissyModel()
        model.applyFrame(frame())

        let moving = (2...6).map { frame(tokens: $0) }

        XCTAssertEqual(fires(across: moving, on: model) { _ = model.menuSnapshot }, 0)
    }

    func testTheFirstFrameWakesTheMenuBar() {
        let model = SissyModel()

        XCTAssertEqual(fires(across: [frame()], on: model) { _ = model.menuSnapshot }, 1)
        XCTAssertFalse(model.menuSnapshot.statusIcon.isAsleep)
    }

    func testAHoldTakenWakesTheMenuBar() {
        let model = SissyModel()
        model.applyFrame(frame())
        let held = frame(keepAwake: KeepAwakeState(mode: .on, active: true))

        XCTAssertEqual(fires(across: [held], on: model) { _ = model.menuSnapshot }, 1)
        XCTAssertTrue(model.menuSnapshot.statusIcon.isHolding)
    }

    func testTheMacLevelMovingWakesTheMenuBar() {
        let model = SissyModel()
        model.applyFrame(frame(pressure: .normal))
        let pressed = frame(pressure: .critical)

        XCTAssertEqual(fires(across: [pressed], on: model) { _ = model.menuSnapshot }, 1)
        XCTAssertEqual(model.menuSnapshot.statusIcon.macLevel, .critical)
    }

    /// Settings' account rows read the same frames: the account's reading
    /// moves them, and a token counted elsewhere does not.
    func testAnAccountRowWakesOnlyForItsAccountsReading() {
        let model = SissyModel()
        model.applyFrame(frame(providers: accounts(10)))

        let sameReading = (2...4).map { frame(tokens: $0, providers: accounts(10)) }
        XCTAssertEqual(fires(across: sameReading, on: model) { _ = model.accountSignals }, 0)

        let moved = frame(providers: accounts(20))
        XCTAssertEqual(fires(across: [moved], on: model) { _ = model.accountSignals }, 1)
    }

    func testAForgeRowWakesOnlyWhenAReadingChanges() {
        let model = SissyModel()
        model.applyFrame(frame(forge: [forgeReading(readAt: 1)]))

        let sameReading = (2...4).map { frame(tokens: $0, forge: [forgeReading(readAt: 1)]) }
        XCTAssertEqual(fires(across: sameReading, on: model) { _ = model.forgeReadings }, 0)

        let moved = frame(forge: [forgeReading(readAt: 2)])
        XCTAssertEqual(fires(across: [moved], on: model) { _ = model.forgeReadings }, 1)
    }

    /// Dropping a reading puts the menu bar back to sleep, so the stored
    /// fields cannot outlive the frame they came off.
    func testClearingTheFrameClearsWhatWasReadOffIt() {
        let model = SissyModel()
        model.applyFrame(
            frame(
                keepAwake: KeepAwakeState(mode: .on, active: true), pressure: .critical,
                providers: accounts(10)))

        model.clearFrame()

        XCTAssertTrue(model.menuSnapshot.statusIcon.isAsleep)
        XCTAssertNil(model.macLevel)
        XCTAssertNil(model.reportedKeepAwake)
        XCTAssertTrue(model.accountSignals.isEmpty)
    }
}
