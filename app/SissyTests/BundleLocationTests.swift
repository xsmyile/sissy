import XCTest

@testable import Sissy

/// A login item names a bundle by where it is, so one registered from a copy
/// that is about to vanish opens nothing at the next login.
///
/// Two such copies exist: the randomized, read-only one macOS runs a
/// quarantined app from when it was opened where it was downloaded, and the
/// app inside a mounted disk image, which is gone once the image is ejected.
@MainActor
final class BundleLocationTests: XCTestCase {
    private static let translocatedPath =
        "/private/var/folders/ab/cdef/T/AppTranslocation/6D1E5C5E-1111-2222-3333-444455556666/d/Sissy.app"
    private static let diskImagePath = "/Volumes/Sissy 0.2.4/Sissy.app"
    private static let installedPath = "/Applications/Sissy.app"
    private static let absentPlist = "com.radonforge.sissy.tests.absent.plist"

    func testACopyMacOSTranslocatedIsTranslocated() {
        XCTAssertEqual(
            BundleLocation.classify(path: Self.translocatedPath, volumeIsReadOnly: true),
            .translocated)
    }

    func testAnAppOnAReadOnlyVolumeIsOnAReadOnlyVolume() {
        XCTAssertEqual(
            BundleLocation.classify(path: Self.diskImagePath, volumeIsReadOnly: true),
            .readOnlyVolume)
    }

    func testAnAppOnAWritableVolumeIsInstalled() {
        XCTAssertEqual(
            BundleLocation.classify(path: Self.installedPath, volumeIsReadOnly: false),
            .installed)
    }

    /// A directory whose name merely contains the word is not a translocation.
    func testOnlyAWholePathComponentNamesATranslocation() {
        XCTAssertEqual(
            BundleLocation.classify(
                path: "/Users/someone/AppTranslocationNotes/Sissy.app", volumeIsReadOnly: false),
            .installed)
    }

    func testAnInstalledCopyCarriesNoNotice() {
        XCTAssertNil(BundleLocation.installed.notice)
    }

    func testATransientCopyCarriesANotice() {
        XCTAssertNotNil(BundleLocation.translocated.notice)
        XCTAssertNotNil(BundleLocation.readOnlyVolume.notice)
    }

    func testABundleInAWritableFolderReadsAsInstalled() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Sissy.app", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let bundle = try XCTUnwrap(Bundle(url: folder))

        XCTAssertEqual(BundleLocation.current(bundle: bundle), .installed)
    }

    func testATransientCopyRefusesToRegisterTheLoginItem() {
        let controller = LoginItemController(
            service: .agent(plistName: Self.absentPlist), location: .readOnlyVolume)

        XCTAssertThrowsError(try controller.setEnabled(true)) { error in
            XCTAssertEqual(error as? BundleLocation.Refusal, BundleLocation.Refusal(.readOnlyVolume))
        }
    }

    /// Turning it off is still allowed: a registration made before the copy
    /// moved is one the user has every reason to take back.
    func testATransientCopyStillLetsTheLoginItemBeSwitchedOff() {
        let controller = LoginItemController(
            service: .agent(plistName: Self.absentPlist), location: .translocated)

        do {
            try controller.setEnabled(false)
        } catch {
            XCTAssertFalse(error is BundleLocation.Refusal, "launchd may refuse; the copy must not")
        }
    }
}
