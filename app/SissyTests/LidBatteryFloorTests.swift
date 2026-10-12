import XCTest

@testable import Sissy

/// When the floor lets the lid go: only on battery, only below it, and never
/// on a reading that is not there.
final class LidBatteryFloorTests: XCTestCase {
    func testAChargeBelowTheFloorOnBatteryReachesIt() {
        let reading = PowerSourceReading(onBattery: true, batteryPercent: 14)

        XCTAssertTrue(LidBatteryFloor.fifteenPercent.isReached(by: reading))
    }

    func testAChargeAtTheFloorDoesNotReachIt() {
        let reading = PowerSourceReading(onBattery: true, batteryPercent: 15)

        XCTAssertFalse(LidBatteryFloor.fifteenPercent.isReached(by: reading))
    }

    func testAMacOnPowerNeverReachesIt() {
        let reading = PowerSourceReading(onBattery: false, batteryPercent: 1)

        XCTAssertFalse(LidBatteryFloor.thirtyPercent.isReached(by: reading))
    }

    func testABatteryThatCouldNotBeReadNeverReachesIt() {
        XCTAssertFalse(LidBatteryFloor.fifteenPercent.isReached(by: nil))
        XCTAssertFalse(
            LidBatteryFloor.fifteenPercent.isReached(
                by: PowerSourceReading(onBattery: true, batteryPercent: nil)))
    }

    func testNeverIsNeverReached() {
        let reading = PowerSourceReading(onBattery: true, batteryPercent: 0)

        XCTAssertFalse(LidBatteryFloor.never.isReached(by: reading))
    }
}
