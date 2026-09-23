import Foundation

/// What `SissyLogFile` writes through: a `FileHandle` in the app, and in the
/// tests a handle that fails the way a real disk does.
protocol SissyLogHandle: AnyObject {
    func append(_ data: Data) throws
    func offset() throws -> UInt64
    func truncate(atOffset offset: UInt64) throws
    func close() throws
}

extension FileHandle: SissyLogHandle {
    func append(_ data: Data) throws {
        try write(contentsOf: data)
    }
}

/// The stderr log file, capped while it is being written to.
///
/// The cap used to be checked when the handle was opened, which happens once
/// per process: a Sissy left running for weeks never looked again, so the size
/// it enforced was the one the *previous* launch had left behind. The size is
/// tracked as the lines go out instead, and one generation is kept
/// (`sissy.err.1.log`) — enough to grep the last boot's stderr after a crash,
/// small enough never to need manual cleanup.
final class SissyLogFile: @unchecked Sendable {
    private let url: URL
    private let rotatedURL: URL
    private let maxBytes: UInt64
    private let open: @Sendable (URL) throws -> any SissyLogHandle
    private let lock = NSLock()
    private var handle: (any SissyLogHandle)?
    private var written: UInt64 = 0
    private var failed = 0

    /// `open` hands back a handle positioned at the end of the file it was
    /// given; tests pass one that refuses every write.
    init(
        directory: URL,
        name: String = "sissy.err.log",
        maxBytes: UInt64 = 2 * 1024 * 1024,
        open: @escaping @Sendable (URL) throws -> any SissyLogHandle = SissyLogFile.openForAppending
    ) {
        let url = directory.appendingPathComponent(name)
        self.url = url
        self.rotatedURL = url.deletingPathExtension()
            .appendingPathExtension("1")
            .appendingPathExtension(url.pathExtension)
        self.maxBytes = maxBytes
        self.open = open
    }

    /// Lines this log could not write, because the file would not open or
    /// the write itself failed.
    var failures: Int {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }

    /// Appends `data`, rotating first when it would not fit. A line is never
    /// split across generations: the cap is a bound on the file, not on what
    /// a reader has to reassemble.
    ///
    /// A failed write is counted and dropped, and so is the handle, so the
    /// next line opens the file again. It is never logged: the log is the
    /// thing that just failed, and `sissyLog` from here would recurse.
    func write(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard var handle = opened() else {
            failed += 1
            return
        }
        if written + UInt64(data.count) > maxBytes {
            rotate()
            guard let fresh = opened() else {
                failed += 1
                return
            }
            handle = fresh
        }
        do {
            try handle.append(data)
            written += UInt64(data.count)
        } catch {
            failed += 1
            try? handle.close()
            self.handle = nil
        }
    }

    /// The handle `init` opens by default: the directory and the file created
    /// when missing, and the offset at the end of what is already there.
    static func openForAppending(_ url: URL) throws -> FileHandle {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let opened = try FileHandle(forWritingTo: url)
        try opened.seekToEnd()
        return opened
    }

    /// The open handle, opening it on first use. `written` starts from what is
    /// already on disk, which is how a log the last run left over the cap is
    /// rotated by the first line of this one rather than grown further.
    private func opened() -> (any SissyLogHandle)? {
        if let handle { return handle }
        guard let opened = try? open(url) else { return nil }
        written = (try? opened.offset()) ?? 0
        handle = opened
        return opened
    }

    /// Moves the current log aside. The handle goes with it, so the next write
    /// opens a fresh file.
    ///
    /// A move that fails — a logs directory that has stopped being writable —
    /// leaves the open handle alone rather than dropping it: the line still has
    /// somewhere to go, and the next one asks again instead of closing and
    /// reopening a file it could not rotate.
    private func rotate() {
        let fm = FileManager.default
        try? fm.removeItem(at: rotatedURL)
        guard (try? fm.moveItem(at: url, to: rotatedURL)) != nil else { return }
        try? handle?.close()
        handle = nil
        written = 0
    }
}

/// A handle every log line is also copied to, standard error in the app.
///
/// Same rule as `SissyLogFile`: a write the handle refuses is counted and
/// dropped, never raised and never logged.
final class SissyLogStream: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var failed = 0

    init(handle: FileHandle) {
        self.handle = handle
    }

    /// Lines the handle refused.
    var failures: Int {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }

    func write(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failed += 1
        }
    }
}

/// What a log message is allowed to be by the time it reaches the file.
enum SissyLogLine {
    /// Longest line written. Nothing Sissy composes itself comes near it; the
    /// cap is there for the parts of a message it did not compose.
    static let maxCharacters = 4_096

    /// `message` as one line: control characters escaped, and the rest cut at
    /// `maxCharacters`.
    ///
    /// Messages carry text Sissy never wrote — a model name read off a
    /// third-party JSONL is the live example — and a newline in one of those
    /// would otherwise forge a second log line. Escaping rather than stripping
    /// keeps the value legible as the thing that arrived.
    static func single(_ message: String) -> String {
        var out = ""
        for scalar in message.unicodeScalars {
            switch scalar {
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out.unicodeScalars.append(scalar)
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\x%02x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out.count > maxCharacters ? String(out.prefix(maxCharacters)) + "…" : out
    }
}

let logFile = SissyLogFile(directory: SissyPaths.logsDir)
let standardErrorLog = SissyLogStream(handle: .standardError)

func sissyLog(_ message: String) {
    let data = Data((SissyLogLine.single(message) + "\n").utf8)
    standardErrorLog.write(data)
    logFile.write(data)
}
