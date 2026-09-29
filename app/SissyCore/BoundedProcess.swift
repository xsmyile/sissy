import Foundation

/// One child process run to completion under a deadline, and killed if it
/// will not end.
///
/// The one runner every tool Sissy spawns goes through (`security`, `git`
/// and `sh -n`), because the rules are the same for all of them and a copy that
/// dropped one is a caller held for the life of the app. The deadline sends
/// `SIGTERM` and, `killGraceSeconds` later, `SIGKILL`. Every stream is either
/// drained or the null device: a pipe nobody reads blocks the child once the
/// kernel buffer fills, and standard error is drained on a queue of its own,
/// because reading two pipes in sequence is the same deadlock with a longer
/// fuse.
///
/// It blocks the calling thread until the child has exited, so a caller on
/// the cooperative pool hops off it first.
enum BoundedProcess {
    /// What a child gets to exit in after `SIGTERM` before it is killed.
    ///
    /// Terminating is a request, and a process wedged on a network mount or a
    /// disk that has stopped answering does not get to read it, while the
    /// caller is inside a blocking read of its output. A child that never
    /// dies takes that caller with it for the life of the app.
    static let killGraceSeconds: TimeInterval = 2

    /// How a run ended and what it wrote. A stream that was not captured is
    /// empty.
    struct Outcome {
        let status: Int32
        let reason: Process.TerminationReason
        let output: Data
        let errors: Data
    }

    /// Runs `tool` and waits for it, throwing only when it could not be
    /// started.
    ///
    /// `input` is written to the child's standard input and closed; nil gives
    /// it the null device. `captureOutput` and `captureErrors` say which of
    /// its two output streams the caller reads, the others going to the null
    /// device.
    static func run(
        _ tool: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        directory: URL? = nil,
        input: Data? = nil,
        captureOutput: Bool = true,
        captureErrors: Bool = false,
        timeout: TimeInterval
    ) throws -> Outcome {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }
        let stdin = input.map { _ in Pipe() }
        let stdout = captureOutput ? Pipe() : nil
        let stderr = captureErrors ? Pipe() : nil
        process.standardInput = stdin ?? FileHandle.nullDevice
        process.standardOutput = stdout ?? FileHandle.nullDevice
        process.standardError = stderr ?? FileHandle.nullDevice
        try process.run()
        let queue = DispatchQueue.global(qos: .utility)
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        let executioner = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        queue.asyncAfter(deadline: .now() + timeout, execute: watchdog)
        queue.asyncAfter(deadline: .now() + timeout + killGraceSeconds, execute: executioner)
        defer {
            watchdog.cancel()
            executioner.cancel()
        }
        if let stdin, let input {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }
        let errors = LockedValue(Data())
        let draining = DispatchGroup()
        if let stderr {
            queue.async(group: draining) {
                let data = stderr.fileHandleForReading.readDataToEndOfFile()
                errors.update { $0 = data }
            }
        }
        let output = stdout?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        process.waitUntilExit()
        draining.wait()
        return Outcome(
            status: process.terminationStatus, reason: process.terminationReason,
            output: output, errors: errors.load())
    }
}
