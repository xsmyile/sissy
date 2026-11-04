import XCTest

@testable import Sissy

final class VersionedJSONFileTests: XCTestCase {
    private struct Document: Codable, Equatable {
        var schemaVersion = 1
        var at = Date(timeIntervalSince1970: 0)
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VersionedJSONFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private var url: URL { directory.appendingPathComponent("doc.json") }

    private func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    func testAMissingFileIsNilUnderEveryPolicy() throws {
        for policy: VersionedJSONFile<Document>.BadFilePolicy in [.replace, .setAside, .refuse] {
            XCTAssertNil(try VersionedJSONFile<Document>(url: url, policy: policy).load())
        }
    }

    func testReplaceAnswersNilAndTheNextSaveWritesOver() throws {
        try Data("not json".utf8).write(to: url)
        let file = VersionedJSONFile<Document>(url: url, policy: .replace)
        XCTAssertNil(try file.load())
        try file.save(Document())
        XCTAssertEqual(try file.load(), Document())
    }

    func testRefuseThrowsAndLeavesTheBytes() throws {
        let garbled = Data("not json".utf8)
        try garbled.write(to: url)
        XCTAssertThrowsError(try VersionedJSONFile<Document>(url: url, policy: .refuse).load())
        XCTAssertEqual(try Data(contentsOf: url), garbled)
    }

    func testSetAsideMovesAFileThatDoesNotDecodeAndThrows() throws {
        try Data("not json".utf8).write(to: url)
        let file = VersionedJSONFile<Document>(
            url: url, policy: .setAside, setAsidePrefix: "doc.json.corrupt-",
            namesFailureInSetAside: true)
        XCTAssertThrowsError(try file.load())
        let aside = try XCTUnwrap(try names().first)
        XCTAssertEqual(try names().count, 1)
        XCTAssertTrue(aside.hasPrefix("doc.json.corrupt-decode-"), aside)
    }

    func testASchemaMismatchIsAFailureOfItsOwn() throws {
        try VersionedJSONFile<Document>(url: url, policy: .replace).save(Document(schemaVersion: 9))
        let file = VersionedJSONFile<Document>(
            url: url, policy: .refuse, schema: (1, \.schemaVersion))
        XCTAssertThrowsError(try file.load()) {
            XCTAssertEqual($0 as? JSONFileFailure, .unsupportedSchema(found: 9, expected: 1))
        }
    }

    func testAFileThatCannotBeReadIsNeverMoved() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let file = VersionedJSONFile<Document>(
            url: url, policy: .setAside, setAsidePrefix: "doc.corrupt-")
        XCTAssertThrowsError(try file.load())
        XCTAssertThrowsError(try file.loadSettingAside(named: "doc"))
        XCTAssertEqual(try names(), ["doc.json"])
    }

    func testDatesStayInTheEncodingTheStoreChose() throws {
        let plain = VersionedJSONFile<Document>(url: url, policy: .replace)
        try plain.save(Document())
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("\"at\":-978307200"))
        let iso = VersionedJSONFile<Document>(url: url, policy: .replace, iso8601Dates: true)
        try iso.save(Document())
        XCTAssertTrue(
            try String(contentsOf: url, encoding: .utf8).contains("1970-01-01T00:00:00Z"))
    }

    /// The defect: three stores wrote into a directory they assumed was there,
    /// so a first save on a fresh install threw.
    func testTheStoresThatAssumedTheirDirectoryNowCreateIt() throws {
        let fresh = directory.appendingPathComponent("fresh", isDirectory: true)
        let accounts = ClaudeAccountStore(indexURL: ClaudeAccountStore.defaultURL(in: fresh))
        try accounts.saveIndex(ClaudeAccountStore.Index())
        XCTAssertEqual(try accounts.loadIndex(), ClaudeAccountStore.Index())
        let forges = ForgeConnectionIndex(url: ForgeConnectionIndex.defaultURL(in: fresh))
        try forges.remember(ForgeConnection.gitHub())
        XCTAssertEqual(try forges.load(), [ForgeConnection.gitHub()])
    }

    /// Existing installs hold these names, and Settings words the prefix.
    func testSetAsideNamesAreTheOnesAlreadyOnDisk() throws {
        let now = Date(timeIntervalSince1970: 100)
        let web = ClaudeWebSessionIndex(url: ClaudeWebSessionIndex.defaultURL(in: directory))
        try Data("{".utf8).write(to: web.url)
        _ = try web.loadSettingAside(now: now)
        let forge = ForgeConnectionIndex(url: ForgeConnectionIndex.defaultURL(in: directory))
        try Data("{".utf8).write(to: forge.url)
        _ = try forge.loadSettingAside(now: now)
        let accounts = ClaudeAccountStore(indexURL: ClaudeAccountStore.defaultURL(in: directory))
        try Data("{".utf8).write(to: accounts.indexURL)
        _ = try accounts.loadIndexSettingAside(now: now)
        XCTAssertEqual(
            try names(),
            [
                "claude-accounts.unreadable-100.json",
                "claude-web-sessions.unreadable-100.json",
                "forge-connections.unreadable-100.json",
            ])
    }
}
