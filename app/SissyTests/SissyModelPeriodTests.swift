import XCTest

@testable import Sissy

/// The panel's period as the model resolves and retires it: at the instant a
/// render hands in, and written back once it has aged out.
@MainActor
final class SissyModelPeriodTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SissyModelPeriodTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func pastDay(_ now: Date) throws -> UsageDaySpan {
        let day = now.addingTimeInterval(-2 * 86_400)
        return try XCTUnwrap(UsageDaySpan(from: day, to: day, now: now))
    }

    /// The period is read at the instant handed in, never at the model's own
    /// clock, so the render that builds the snapshot and the one that draws
    /// the control agree across the 24 h mark.
    func testThePeriodIsResolvedAtTheInstantHandedIn() throws {
        let pickedAt = Date()
        let model = SissyModel(supportDirectory: directory)
        let span = try pastDay(pickedAt)
        model.setUsagePeriod(.days(span), now: pickedAt)

        let lifetime = Preferences.pickedPeriodLifetime
        XCTAssertEqual(model.usagePeriod(now: pickedAt.addingTimeInterval(lifetime - 1)), .days(span))
        XCTAssertEqual(model.usagePeriod(now: pickedAt.addingTimeInterval(lifetime)), .preset(.today))
    }

    /// Once observed, the retirement is written, so the file says what the
    /// panel reads and a relaunch does not bring the window back.
    func testAnExpiredWindowIsRetiredInTheFile() throws {
        let pickedAt = Date()
        let model = SissyModel(supportDirectory: directory)
        let span = try pastDay(pickedAt)
        model.setUsagePeriod(.days(span), now: pickedAt)

        model.retireExpiredUsagePeriod(now: pickedAt.addingTimeInterval(1))
        XCTAssertEqual(Preferences.load(from: directory).usagePeriod, .days(span))

        model.retireExpiredUsagePeriod(now: pickedAt.addingTimeInterval(Preferences.pickedPeriodLifetime))
        XCTAssertEqual(model.preferences.usagePeriod, .preset(.today))
        XCTAssertNil(model.preferences.pickedPeriodExpiry(now: pickedAt))
        XCTAssertEqual(Preferences.load(from: directory).usagePeriod, .preset(.today))
        XCTAssertNil(Preferences.load(from: directory).usagePeriodPickedAt)
    }
}
