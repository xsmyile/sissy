import XCTest

@testable import Sissy

/// Which Claude Code credentials were filed for a config home Sissy does not
/// read, decided from service names alone.
final class ClaudeUnsupportedHomesTests: XCTestCase {
    private static let defaultHome = AccountDefaults.claudeHome
    private static let otherHome = URL(fileURLWithPath: "/tmp/sissy-tests/.claude-work")

    /// A `claude` started with `CLAUDE_CONFIG_DIR` files its credential under
    /// the hash of that directory, which is not a name Sissy ever reads.
    func testAScopedItemForAnotherHomeIsFound() {
        let foreign = ClaudeKeychainCLI.scopedClaudeService(for: Self.otherHome.path)

        let found = ClaudeUnsupportedHomes.services(
            in: [ClaudeKeychainCLI.claudeService, foreign], reading: Self.defaultHome)

        XCTAssertEqual(found, [foreign])
    }

    /// The default home keeps a scoped sibling of its own, which Sissy reads.
    func testTheDefaultHomesOwnScopedItemIsNotFound() {
        let sibling = ClaudeKeychainCLI.scopedClaudeService(for: Self.defaultHome.path)

        let found = ClaudeUnsupportedHomes.services(
            in: [ClaudeKeychainCLI.claudeService, sibling], reading: Self.defaultHome)

        XCTAssertTrue(found.isEmpty)
    }

    /// A home Sissy was pointed at is one it reads, under its own scoped name.
    func testTheHomeSissyReadsIsNotFound() {
        let own = ClaudeKeychainCLI.claudeService(for: Self.otherHome)

        let found = ClaudeUnsupportedHomes.services(in: [own], reading: Self.otherHome)

        XCTAssertTrue(found.isEmpty)
    }

    /// Only the CLI's own shape counts: the prefix and eight hex characters.
    /// Anything else sharing the prefix is somebody else's item.
    func testANameThatOnlySharesThePrefixIsNotFound() {
        let found = ClaudeUnsupportedHomes.services(
            in: ["\(ClaudeKeychainCLI.claudeService)-backup", "Claude Code-credentials-XYZ12345"],
            reading: Self.defaultHome)

        XCTAssertTrue(found.isEmpty)
    }

    /// One item per home, however many times the listing names it.
    func testAHomeIsCountedOnce() {
        let foreign = ClaudeKeychainCLI.scopedClaudeService(for: Self.otherHome.path)

        let found = ClaudeUnsupportedHomes.services(
            in: [foreign, foreign], reading: Self.defaultHome)

        XCTAssertEqual(found, [foreign])
    }

    /// The scan asks only the listing it is handed, so the rule is provable
    /// without the login keychain taking part.
    func testTheScanReadsTheListingItIsGiven() {
        let foreign = ClaudeKeychainCLI.scopedClaudeService(for: Self.otherHome.path)

        let found = ClaudeUnsupportedHomes.scan(reading: Self.defaultHome) { [foreign] }

        XCTAssertEqual(found, [foreign])
    }

    /// The notice names the variable and the folder, which is what a user who
    /// set one needs to recognise the other.
    func testTheNoticeNamesTheVariableItDoesNotFollow() {
        let message = ClaudeUnsupportedHomesCopy.message(reading: Self.defaultHome)
        XCTAssertTrue(message.contains("CLAUDE_CONFIG_DIR"), message)
        XCTAssertTrue(message.contains(".claude"), message)
    }
}
