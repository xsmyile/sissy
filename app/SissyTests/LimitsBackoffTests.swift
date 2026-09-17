import XCTest

@testable import Sissy

/// What a vendor's refusal is worth once the process that met it has gone.
final class LimitsBackoffTests: XCTestCase {
    private var directory: URL!
    private var url: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-backoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = LimitsBackoffLedger.defaultURL(in: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The whole point of the file: a refusal one run met is a wait the next
    /// one serves, rather than a request spent on a vendor still saying no.
    func testARefusalIsAnsweredByTheNextRun() async {
        let until = Date().addingTimeInterval(900)
        await LimitsBackoffStore(url: url).record(until, for: LimitsBackoffLedger.claudeCLIKey)

        let next = await LimitsBackoffStore(url: url)
            .deadline(for: LimitsBackoffLedger.claudeCLIKey)

        XCTAssertEqual(next?.timeIntervalSince1970 ?? 0, until.timeIntervalSince1970, accuracy: 1)
    }

    /// A deadline that has passed is not a block, so a reader that was refused
    /// yesterday asks today without being told to wait.
    func testADeadlineThatHasPassedBlocksNothing() async {
        let store = LimitsBackoffStore(url: url)
        await store.record(Date().addingTimeInterval(-60), for: LimitsBackoffLedger.claudeCLIKey)

        let deadline = await store.deadline(for: LimitsBackoffLedger.claudeCLIKey)

        XCTAssertNil(deadline)
    }

    /// The file is input like any other. A date further out than a live
    /// refusal could have earned is not something this build wrote, and
    /// honouring it would silence the reader for as long as it said.
    func testADeadlineBeyondTheCeilingIsClamped() async {
        let store = LimitsBackoffStore(url: url)
        await store.record(Date().addingTimeInterval(86_400), for: LimitsBackoffLedger.claudeCLIKey)

        let deadline = await store.deadline(for: LimitsBackoffLedger.claudeCLIKey)

        XCTAssertEqual(
            deadline?.timeIntervalSinceNow ?? 0, UsageRequestError.retryAfterCeiling, accuracy: 5)
    }

    /// A reading answers the question the block was standing in for, so the
    /// entry goes rather than being left to expire on its own.
    func testAReadingTakesTheEntryOut() async {
        let store = LimitsBackoffStore(url: url)
        await store.record(Date().addingTimeInterval(900), for: LimitsBackoffLedger.claudeCLIKey)

        await store.record(nil, for: LimitsBackoffLedger.claudeCLIKey)

        let deadline = await LimitsBackoffStore(url: url)
            .deadline(for: LimitsBackoffLedger.claudeCLIKey)
        XCTAssertNil(deadline)
    }

    /// One credential's entry is not another's: the vendor refuses a token,
    /// and a Mac with two accounts has one of each.
    func testEachCredentialKeepsItsOwnDeadline() async {
        let store = LimitsBackoffStore(url: url)
        await store.record(
            Date().addingTimeInterval(900), for: LimitsBackoffLedger.claudeWebKey(account: "a"))

        let other = await store.deadline(for: LimitsBackoffLedger.claudeWebKey(account: "b"))

        XCTAssertNil(other)
        let own = await store.deadline(for: LimitsBackoffLedger.claudeWebKey(account: "a"))
        XCTAssertNotNil(own)
    }

    /// A file this build cannot decode blocks nothing, which costs one request
    /// the vendor may refuse — where quarantining it would cost every request
    /// until somebody deleted it by hand.
    func testAFileThisBuildCannotReadBlocksNothing() async throws {
        try Data("{\"schemaVersion\":999}".utf8).write(to: url)

        let deadline = await LimitsBackoffStore(url: url)
            .deadline(for: LimitsBackoffLedger.claudeCLIKey)

        XCTAssertNil(deadline)
    }
}
