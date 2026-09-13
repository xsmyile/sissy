import XCTest

@testable import Sissy

/// The inbox is the one input to the ledger that Sissy did not write, so these
/// are boundary tests: everything a file dropped in that directory could be
/// other than the pair it claims to be.
final class ProjectLedgerInboxTests: XCTestCase {
    private var root: URL!
    private var stateDir: URL!
    private var inbox: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sissy-inbox-\(UUID().uuidString)")
        stateDir = root.appendingPathComponent("state")
        inbox = ProjectLedger.inboxURL(in: stateDir)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The whole point: a checkout nothing on this machine can still walk to,
    /// answered by what the session wrote down before it went.
    func testADeletedCheckoutTheSessionWroteDownIsStillAnswered() throws {
        let repository = root.appendingPathComponent("sissy").standardizedFileURL
        let worktree = root.appendingPathComponent("grampus").standardizedFileURL
        try write(entry: "gone", directory: worktree.path, project: repository.path)

        let ledger = makeLedger()
        XCTAssertEqual(ledger.ingestInbox().learned, 1)

        XCTAssertEqual(ledger.project(under: worktree.path), repository.path)
    }

    /// The measurement the inbox has to earn: an entry already dead on arrival
    /// is one the tail could not have learned, because there was nothing left
    /// to walk to by the time it looked.
    func testAnEntryWhoseDirectoryIsAlreadyGoneIsCountedApart() throws {
        let alive = root.appendingPathComponent("alive").standardizedFileURL
        try FileManager.default.createDirectory(at: alive, withIntermediateDirectories: true)
        try write(entry: "alive", directory: alive.path, project: alive.path)
        try write(
            entry: "dead", directory: root.appendingPathComponent("dead").path,
            project: root.appendingPathComponent("sissy").path)

        let report = makeLedger().ingestInbox()

        XCTAssertEqual(report.read, 2)
        XCTAssertEqual(report.learned, 2)
        XCTAssertEqual(report.arrivedDeleted, 1)
    }

    /// Read once and gone, which is what bounds the directory without a
    /// retention setting to get wrong.
    func testAnEntryIsConsumed() throws {
        try write(entry: "one", directory: "/a/b", project: "/a")
        let ledger = makeLedger()

        XCTAssertEqual(ledger.ingestInbox().read, 1)
        XCTAssertEqual(ledger.ingestInbox().read, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path), [])
    }

    /// Evidence Sissy did not see itself goes behind what it did. The cap drops
    /// from the tail, so the order is also the order things are forgotten in.
    func testWhatASessionWroteRanksBehindWhatSissyWalked() throws {
        let ledger = makeLedger()
        ledger.remember(ProjectCheckout(directory: "/a/walked", project: "/a"))
        try write(entry: "told", directory: "/a/told", project: "/a")

        ledger.ingestInbox()

        XCTAssertEqual(ledger.all().map(\.directory), ["/a/walked", "/a/told"])
    }

    func testAnEntryAlreadyKnownIsNotLearnedTwice() throws {
        let ledger = makeLedger()
        ledger.remember(ProjectCheckout(directory: "/a/b", project: "/a"))
        try write(entry: "again", directory: "/a/b", project: "/a")

        let report = ledger.ingestInbox()

        XCTAssertEqual(report.read, 1)
        XCTAssertEqual(report.learned, 0)
        XCTAssertEqual(ledger.all().count, 1)
    }

    func testMalformedEntriesAreRejected() throws {
        let cases: [String: String] = [
            "one-line": "/a/b\n",
            "three-lines": "/a/b\n/a\n/c\n",
            "empty": "",
            "relative-directory": "a/b\n/a\n",
            "relative-project": "/a/b\na\n",
            "control-character": "/a/\u{7}b\n/a\n",
            "newline-only": "\n\n",
            "root-directory": "/\n/\n",
            "single-component-directory": "/tmp\n/tmp\n",
            "traversal": "/a/../../etc\n/a\n",
        ]
        for (name, body) in cases {
            try body.write(
                to: inbox.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        }

        let ledger = makeLedger()
        let report = ledger.ingestInbox()

        XCTAssertEqual(report.read, cases.count)
        XCTAssertEqual(report.rejected, cases.count)
        XCTAssertEqual(report.learned, 0)
        XCTAssertTrue(ledger.all().isEmpty)
    }

    /// A path that standardizes to something real is still a real path. The
    /// traversal test above rejects one that cannot; this one keeps one that
    /// can, so the check does not quietly refuse ordinary directories.
    func testATraversalThatResolvesIsKeptAtWhatItResolvesTo() throws {
        try write(entry: "dots", directory: "/a/b/../c", project: "/a")

        let ledger = makeLedger()
        ledger.ingestInbox()

        XCTAssertEqual(ledger.all().first?.directory, "/a/c")
    }

    /// An entry pointed at something else is not read through. Without
    /// `O_NOFOLLOW` this is how a private key reaches a log line.
    func testASymlinkedEntryIsNotFollowed() throws {
        let secret = root.appendingPathComponent("secret")
        try "/a/b\n/a\n".write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: inbox.appendingPathComponent("link.txt"), withDestinationURL: secret)

        let report = makeLedger().ingestInbox()

        XCTAssertEqual(report.read, 0)
        XCTAssertEqual(report.learned, 0)
    }

    /// A named pipe holds `open(2)` open until someone writes. This runs inside
    /// the provider's actor, so blocking here stops metering outright.
    func testAFifoEntryDoesNotBlockTheIngest() throws {
        let fifo = inbox.appendingPathComponent("pipe.txt")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)

        let report = makeLedger().ingestInbox()

        XCTAssertEqual(report.read, 0)
    }

    func testAnOversizedEntryIsNotRead() throws {
        let body = String(repeating: "/a/b\n/a\n", count: 4096)
        try body.write(
            to: inbox.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)

        XCTAssertEqual(makeLedger().ingestInbox().read, 0)
    }

    func testAPassIsCapped() throws {
        for index in 0...ProjectLedger.maxInboxEntriesPerPass {
            try write(entry: "e\(index)", directory: "/a/\(index)", project: "/a")
        }

        XCTAssertEqual(makeLedger().ingestInbox().read, ProjectLedger.maxInboxEntriesPerPass)
    }

    /// A ledger with no file of its own has no inbox either — there is nowhere
    /// for one to be, and a `sissy-cli` run must not invent one.
    func testALedgerWithNoFileHasNoInbox() {
        XCTAssertEqual(ProjectLedger().ingestInbox(), InboxIngest())
    }

    private func makeLedger() -> ProjectLedger {
        ProjectLedger(url: ProjectLedger.defaultURL(in: stateDir))
    }

    private func write(entry: String, directory: String, project: String) throws {
        try "\(directory)\n\(project)\n".write(
            to: inbox.appendingPathComponent("\(entry).txt"), atomically: true, encoding: .utf8)
    }
}
