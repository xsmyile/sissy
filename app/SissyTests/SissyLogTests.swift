import XCTest

@testable import Sissy

/// A log line that cannot be written is a line lost, never a process lost.
///
/// `FileHandle.write(_:)` raises an Objective-C exception on a failed write,
/// which Swift cannot catch: a full disk turned the first `sissyLog` after a
/// failed save into a crash, and the relaunch into the next one. These hand
/// the log a handle that refuses every write and ask it what it counted.
final class SissyLogTests: XCTestCase {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("sissy-log-tests-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private var logURL: URL { directory.appendingPathComponent("sissy.err.log") }

    private func contents() throws -> String {
        try String(contentsOf: logURL, encoding: .utf8)
    }

    private func closedHandle() throws -> FileHandle {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.close()
        return handle
    }

    private func readOnlyHandle() throws -> FileHandle {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        return try FileHandle(forReadingFrom: logURL)
    }

    func testAWriteThroughAClosedHandleIsCounted() throws {
        let handle = try closedHandle()
        let log = SissyLogFile(directory: directory, open: { _ in handle })

        log.write(Data("lost\n".utf8))

        XCTAssertEqual(log.failures, 1)
    }

    func testAWriteThroughAReadOnlyHandleIsCounted() throws {
        let handle = try readOnlyHandle()
        let log = SissyLogFile(directory: directory, open: { _ in handle })

        log.write(Data("lost\n".utf8))

        XCTAssertEqual(log.failures, 1)
    }

    func testAFailedWriteLetsTheNextLineReopenTheFile() throws {
        let closed = try closedHandle()
        let opens = OpenSequence(first: closed)
        let log = SissyLogFile(directory: directory, open: opens.next)

        log.write(Data("lost\n".utf8))
        log.write(Data("kept\n".utf8))

        XCTAssertEqual(try contents(), "kept\n")
    }

    func testAWrittenLineLandsAndCountsNoFailure() throws {
        let log = SissyLogFile(directory: directory)

        log.write(Data("one\n".utf8))
        log.write(Data("two\n".utf8))

        XCTAssertEqual(try contents(), "one\ntwo\n")
        XCTAssertEqual(log.failures, 0)
    }

    func testAStreamCountsAWriteItsHandleRefuses() throws {
        let stream = SissyLogStream(handle: try readOnlyHandle())

        stream.write(Data("lost\n".utf8))

        XCTAssertEqual(stream.failures, 1)
    }

    func testAStreamWriteLands() throws {
        let pipe = Pipe()
        let stream = SissyLogStream(handle: pipe.fileHandleForWriting)

        stream.write(Data("line\n".utf8))
        try pipe.fileHandleForWriting.close()

        let read = try pipe.fileHandleForReading.readToEnd()
        XCTAssertEqual(read.flatMap { String(bytes: $0, encoding: .utf8) }, "line\n")
        XCTAssertEqual(stream.failures, 0)
    }
}

/// An opener that hands out one given handle first and the real file after.
private final class OpenSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var first: FileHandle?

    init(first: FileHandle) {
        self.first = first
    }

    func next(_ url: URL) throws -> FileHandle {
        lock.lock()
        defer { lock.unlock() }
        if let handle = first {
            first = nil
            return handle
        }
        return try SissyLogFile.openForAppending(url)
    }
}
