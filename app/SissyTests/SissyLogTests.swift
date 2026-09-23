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

    func testAWriteThatFailsPartWayLeavesNoFragmentBehind() throws {
        let opens = OpenSequence(first: try PartialWriteHandle(url: logURL))
        let log = SissyLogFile(directory: directory, open: opens.next)

        log.write(Data("lost\n".utf8))
        log.write(Data("kept\n".utf8))

        XCTAssertEqual(try contents(), "kept\n")
    }

    func testAFragmentTheLogCouldNotTruncateIsRemovedOnReopen() throws {
        FileManager.default.createFile(atPath: logURL.path, contents: Data("earlier\n".utf8))
        let opens = OpenSequence(first: try PartialWriteHandle(url: logURL, truncates: false))
        let log = SissyLogFile(directory: directory, open: opens.next)

        log.write(Data("lost\n".utf8))
        log.write(Data("kept\n".utf8))

        XCTAssertEqual(try contents(), "earlier\nkept\n")
    }

    func testALineIsDroppedWhileTheFragmentCannotBeRemoved() throws {
        FileManager.default.createFile(atPath: logURL.path, contents: Data("earlier\n".utf8))
        let opens = OpenSequence(
            first: try PartialWriteHandle(url: logURL, truncates: false),
            try UntruncatableHandle(url: logURL)
        )
        let log = SissyLogFile(directory: directory, open: opens.next)

        log.write(Data("lost\n".utf8))
        log.write(Data("dropped\n".utf8))
        log.write(Data("kept\n".utf8))

        XCTAssertEqual(try contents(), "earlier\nkept\n")
        XCTAssertEqual(log.failures, 2)
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

/// An opener that hands out the given handles in order and the real file after.
private final class OpenSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [any SissyLogHandle]

    init(first: any SissyLogHandle, _ rest: any SissyLogHandle...) {
        queued = [first] + rest
    }

    func next(_ url: URL) throws -> any SissyLogHandle {
        lock.lock()
        defer { lock.unlock() }
        if !queued.isEmpty {
            return queued.removeFirst()
        }
        return try SissyLogFile.openForAppending(url)
    }
}

/// A handle that writes the first half of a line to the real file and then
/// fails, the way a disk that fills mid-line does.
///
/// With `truncates` false the truncation that should remove the fragment
/// fails as well, which a disk refusing every change does.
private final class PartialWriteHandle: SissyLogHandle, @unchecked Sendable {
    private let file: FileHandle
    private let truncates: Bool

    init(url: URL, truncates: Bool = true) throws {
        file = try SissyLogFile.openForAppending(url)
        self.truncates = truncates
    }

    func append(_ data: Data) throws {
        try file.write(contentsOf: data.prefix(data.count / 2))
        throw CocoaError(.fileWriteOutOfSpace)
    }

    func offset() throws -> UInt64 {
        try file.offset()
    }

    func truncate(atOffset offset: UInt64) throws {
        guard truncates else { throw CocoaError(.fileWriteNoPermission) }
        try file.truncate(atOffset: offset)
    }

    func close() throws {
        try file.close()
    }
}

/// A handle on the real file that writes but refuses to truncate it.
private final class UntruncatableHandle: SissyLogHandle, @unchecked Sendable {
    private let file: FileHandle

    init(url: URL) throws {
        file = try SissyLogFile.openForAppending(url)
    }

    func append(_ data: Data) throws {
        try file.write(contentsOf: data)
    }

    func offset() throws -> UInt64 {
        try file.offset()
    }

    func truncate(atOffset offset: UInt64) throws {
        throw CocoaError(.fileWriteNoPermission)
    }

    func close() throws {
        try file.close()
    }
}
