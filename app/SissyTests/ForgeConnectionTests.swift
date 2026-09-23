import XCTest

@testable import Sissy

/// The index a forge connection is recorded in, and the tokens it is
/// reconciled against.
///
/// Pure or on a temporary directory: no keychain and no network.
final class ForgeConnectionTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("forge-connection-tests-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private var index: ForgeConnectionIndex {
        ForgeConnectionIndex(url: ForgeConnectionIndex.defaultURL(in: directory))
    }

    // MARK: The index

    func testAnAbsentIndexIsEmpty() throws {
        XCTAssertEqual(try index.load(), [])
    }

    func testAnUnreadableIndexThrowsRatherThanReadingEmpty() throws {
        try Data("{\"connections\":[".utf8).write(to: index.url)
        XCTAssertThrowsError(try index.load())
    }

    /// The defect this whole half is for: the next connection used to write
    /// over a file that would not read, and the tokens it named were orphaned.
    func testAnUnreadableIndexIsNeverOverwritten() throws {
        let garbled = Data("{\"connections\":[".utf8)
        try garbled.write(to: index.url)
        XCTAssertThrowsError(try index.remember(ForgeConnection.gitHub()))
        XCTAssertThrowsError(try index.forget(id: ForgeConnection.gitHub().id))
        XCTAssertEqual(try Data(contentsOf: index.url), garbled)
    }

    func testAnEmptyIndexFileIsUnreadable() throws {
        try Data().write(to: index.url)
        XCTAssertThrowsError(try index.load())
    }

    func testAnUnreadableIndexIsMovedAsideWithItsBytes() throws {
        let garbled = Data("{\"connections\":[".utf8)
        try garbled.write(to: index.url)
        XCTAssertEqual(try index.loadSettingAside(), [])
        let aside = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(ForgeConnectionIndex.setAsidePrefix) }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent(try XCTUnwrap(aside.first))),
            garbled)
        XCTAssertTrue(index.hasSetAside())
    }

    /// Once the unreadable file is aside, a new connection starts a fresh one
    /// rather than being refused for ever.
    func testAConnectionAfterTheSetAsideStartsAFreshIndex() throws {
        try Data("{\"connections\":[".utf8).write(to: index.url)
        _ = try index.loadSettingAside()
        try index.remember(ForgeConnection.gitHub())
        XCTAssertEqual(try index.load(), [ForgeConnection.gitHub()])
    }

    func testAReadableIndexIsNotSetAside() throws {
        try index.remember(ForgeConnection.gitHub())
        XCTAssertEqual(try index.loadSettingAside(), [ForgeConnection.gitHub()])
        XCTAssertFalse(index.hasSetAside())
    }

    // MARK: Reconciliation

    func testATokenNoConnectionNamesIsAnOrphan() {
        let gitLab = ForgeConnection(kind: .gitLab, host: "gitlab.example.com")
        XCTAssertEqual(
            ForgeConnectionIndex.orphans(
                stored: [gitLab.id, "gitlab:old.example.com", ForgeConnection.gitHub().id],
                connected: [ForgeConnection.gitHub(), gitLab]),
            ["gitlab:old.example.com"])
    }
}
