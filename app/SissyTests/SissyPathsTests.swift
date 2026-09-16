import XCTest

@testable import Sissy

/// What a suite hosted inside `Sissy.app` has to be able to say about its own
/// paths: that they are not the install's.
///
/// Every default location in the app resolves through `SissyPaths`, and the
/// host bundle carries the dev app's id — so before the harness check, a run
/// of this suite appended its stderr to the log file of the Sissy the
/// developer was running.
final class SissyPathsTests: XCTestCase {
    func testTheHarnessIsRecognised() {
        XCTAssertTrue(
            SissyPaths.isTestHarness,
            "the runner exported no XCTestConfigurationFilePath, so every path below is the install's")
    }

    func testNeitherTreeIsTheInstalls() {
        let library = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        for directory in [SissyPaths.appSupportDir, SissyPaths.logsDir] {
            XCTAssertFalse(
                directory.path.hasPrefix(library.path),
                "\(directory.path) is inside the tree an installed Sissy owns")
        }
    }
}
