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

    /// The services every linked account is filed under, in a namespace no
    /// install has. Compared rather than read, because reading an install's
    /// items is what this keeps a suite from doing.
    func testEveryKeychainServiceIsThisRunsOwn() {
        let namespace = ".tests-\(ProcessInfo.processInfo.processIdentifier)."
        for service in [
            ClaudeWebSessionStore.keychainService, CodexAccountStore.keychainService,
            ForgeTokenStore.keychainService, ClaudeArchiveRemoval.service,
        ] {
            XCTAssertTrue(service.contains(namespace), "\(service) is an install's")
        }
    }

    /// A run's namespace starts empty and its tests clean up after themselves,
    /// so a linked account seen here is one the developer linked.
    func testARunListsNoLinkedAccountOfItsOwn() {
        XCTAssertEqual(ClaudeWebSessionStore.storedAccounts().count, 0)
        XCTAssertEqual(CodexAccountStore.storedAccounts().count, 0)
        XCTAssertEqual(ForgeTokenStore.storedConnections().count, 0)
    }
}
