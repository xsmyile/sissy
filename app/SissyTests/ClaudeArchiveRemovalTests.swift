import XCTest

@testable import Sissy

/// The removal of the saved Claude sign-ins, against a stand-in keychain.
final class ClaudeArchiveRemovalTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-removal-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private final class Keychain: @unchecked Sendable {
        private let lock = NSLock()
        private var items: Int
        private var calls = 0
        private var failure: Error?

        init(items: Int, failure: Error? = nil) {
            self.items = items
            self.failure = failure
        }

        var remaining: Int { lock.withLock { items } }
        var callCount: Int { lock.withLock { calls } }
        func heal() { lock.withLock { failure = nil } }

        func deleteOne() throws -> Bool {
            try lock.withLock {
                calls += 1
                if let failure { throw failure }
                guard items > 0 else { return false }
                items -= 1
                return true
            }
        }
    }

    private func removal(_ keychain: Keychain) -> ClaudeArchiveRemoval {
        ClaudeArchiveRemoval(
            recordURL: directory.appendingPathComponent(ClaudeArchiveRemoval.recordFileName),
            deleteOne: { try keychain.deleteOne() })
    }

    func testEveryItemGoesAndTheRecordIsWritten() {
        let keychain = Keychain(items: 3)
        XCTAssertEqual(removal(keychain).run(), .finished(removed: 3, recorded: true))
        XCTAssertEqual(keychain.remaining, 0)
    }

    func testASecondRunNeverAsksTheKeychain() {
        let keychain = Keychain(items: 2)
        removal(keychain).run()
        let calls = keychain.callCount
        XCTAssertEqual(removal(keychain).run(), .alreadyDone)
        XCTAssertEqual(keychain.callCount, calls)
    }

    func testAMacWithNothingFiledStillRecordsIt() {
        let keychain = Keychain(items: 0)
        XCTAssertEqual(removal(keychain).run(), .finished(removed: 0, recorded: true))
        XCTAssertEqual(removal(keychain).run(), .alreadyDone)
    }

    func testARefusalLeavesTheRecordUnsetAndTheNextLaunchFinishes() {
        let keychain = Keychain(items: 2, failure: ClaudeKeychainCLI.Failure.tool(51))
        XCTAssertEqual(removal(keychain).run(), .willRetry(removed: 0))
        XCTAssertEqual(keychain.remaining, 2)
        keychain.heal()
        XCTAssertEqual(removal(keychain).run(), .finished(removed: 2, recorded: true))
        XCTAssertEqual(keychain.remaining, 0)
    }

    func testAKeychainThatDoesNotAnswerAlsoRetries() {
        let keychain = Keychain(items: 1, failure: ClaudeKeychainCLI.Failure.unavailable)
        XCTAssertEqual(removal(keychain).run(), .willRetry(removed: 0))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(ClaudeArchiveRemoval.recordFileName).path))
    }

    func testADeleteThatNeverRunsOutStopsAtTheLimitWithoutARecord() {
        let keychain = Keychain(items: ClaudeArchiveRemoval.itemLimit + 5)
        XCTAssertEqual(
            removal(keychain).run(), .willRetry(removed: ClaudeArchiveRemoval.itemLimit))
        XCTAssertEqual(keychain.callCount, ClaudeArchiveRemoval.itemLimit)
    }

    func testARecordThatWillNotWriteStillFinishes() throws {
        try Data().write(to: directory)
        let keychain = Keychain(items: 1)
        XCTAssertEqual(removal(keychain).run(), .finished(removed: 1, recorded: false))
    }

    func testTheOldIndexFieldsDecodeAsNothingAndTheNextSaveDropsThem() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ClaudeAccountStore(indexURL: ClaudeAccountStore.defaultURL(in: directory))
        let old = """
            {"accounts":[{"uuid":"u-1","email":"a@example.com"}],
            "activeUUID":"u-1","refreshExpiries":{"u-1":800000000},
            "lineage":{"u-1":["abc"]}}
            """
        try Data(old.utf8).write(to: store.indexURL)
        let index = try store.loadIndex()
        XCTAssertEqual(index.accounts.map(\.uuid), ["u-1"])
        XCTAssertEqual(index.activeUUID, "u-1")
        try store.saveIndex(index)
        let written = try String(contentsOf: store.indexURL, encoding: .utf8)
        for field in ["refreshExpiries", "lineage"] {
            XCTAssertFalse(written.contains(field), field)
        }
    }
}
