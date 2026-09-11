import Foundation

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
    private let lock = NSLock()
    private var handle: FileHandle?
    private var written: UInt64 = 0

    init(directory: URL, name: String = "sissy.err.log", maxBytes: UInt64 = 2 * 1024 * 1024) {
        let url = directory.appendingPathComponent(name)
        self.url = url
        self.rotatedURL = url.deletingPathExtension()
            .appendingPathExtension("1")
            .appendingPathExtension(url.pathExtension)
        self.maxBytes = maxBytes
    }

    /// Appends `data`, rotating first when it would not fit. A line is never
    /// split across generations: the cap is a bound on the file, not on what
    /// a reader has to reassemble.
    func write(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard var handle = opened() else { return }
        if written + UInt64(data.count) > maxBytes {
            rotate()
            guard let fresh = opened() else { return }
            handle = fresh
        }
        handle.write(data)
        written += UInt64(data.count)
    }

    /// The open handle, opening it on first use. `written` starts from what is
    /// already on disk, which is how a log the last run left over the cap is
    /// rotated by the first line of this one rather than grown further.
    private func opened() -> FileHandle? {
        if let handle { return handle }
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            let opened = try FileHandle(forWritingTo: url)
            written = try opened.seekToEnd()
            handle = opened
            return opened
        } catch {
            return nil
        }
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

func sissyLog(_ message: String) {
    let data = Data((SissyLogLine.single(message) + "\n").utf8)
    FileHandle.standardError.write(data)
    logFile.write(data)
}
