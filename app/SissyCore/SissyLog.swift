import Foundation

let logFile: FileHandle? = {
    let logsURL = SissyPaths.logsDir
    do {
        try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
        let url = logsURL.appendingPathComponent("sissy.err.log")
        // Rotate the previous run's log if it grew past the cap. Single
        // generation kept (`sissy.err.1.log`) — enough to grep for last
        // boot's stderr after a crash, small enough to never need manual
        // cleanup. A lazy global, so the check runs once on the first line
        // written rather than at process start.
        rotateLogIfNeeded(at: url, maxBytes: 2 * 1024 * 1024)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    } catch {
        return nil
    }
}()

private func rotateLogIfNeeded(at url: URL, maxBytes: UInt64) {
    let fm = FileManager.default
    guard let attrs = try? fm.attributesOfItem(atPath: url.path),
        let size = (attrs[.size] as? NSNumber)?.uint64Value,
        size > maxBytes
    else { return }
    let rotated = url.deletingLastPathComponent()
        .appendingPathComponent("sissy.err.1.log")
    try? fm.removeItem(at: rotated)
    try? fm.moveItem(at: url, to: rotated)
}

func sissyLog(_ message: String) {
    let line = message.hasSuffix("\n") ? message : "\(message)\n"
    let data = Data(line.utf8)
    FileHandle.standardError.write(data)
    logFile?.write(data)
}
