import Darwin
import Foundation

enum ProvisioningError: LocalizedError {
    case openFailed(String)
    case configFailed(String)
    case writeFailed(String)
    case readFailed(String)
    case ackTimeout
    case deviceError(String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let s): return "open: \(s)"
        case .configFailed(let s): return "tcsetattr: \(s)"
        case .writeFailed(let s): return "write: \(s)"
        case .readFailed(let s): return "read: \(s)"
        case .ackTimeout: return "device did not respond in time"
        case .deviceError(let s): return "device error: \(s)"
        case .badResponse(let s): return "unexpected response: \(s)"
        }
    }
}

/// Sends a ProvisionRequest down the wire and waits for the firmware's
/// `OK:` or `ERR:` reply. All POSIX calls run on a background thread —
/// the actor isolates state so concurrent `send` calls serialise instead
/// of stomping a shared fd.
actor Provisioner {
    static let shared = Provisioner()

    func send(
        _ request: ProvisionRequest,
        to port: SerialPort,
        ackTimeout: TimeInterval = 5
    ) async throws {
        let line = try request.encodedLine()

        // The POSIX layer is synchronous; run it off the actor's executor so
        // the rest of the app doesn't stall while waiting for the device.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try Self.exchange(line: line, with: port, ackTimeout: ackTimeout)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func exchange(
        line: Data,
        with port: SerialPort,
        ackTimeout: TimeInterval
    ) throws {
        let fd = Darwin.open(port.path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        if fd < 0 {
            throw ProvisioningError.openFailed(errnoString())
        }
        defer { _ = Darwin.close(fd) }

        // Clear non-blocking; we want blocking reads/writes for the actual exchange.
        _ = fcntl(fd, F_SETFL, 0)

        try configure(fd: fd)
        try writeAll(fd: fd, data: line)
        let response = try readLine(fd: fd, timeout: ackTimeout)

        if response.hasPrefix("OK:") { return }
        if response.hasPrefix("ERR:") {
            throw ProvisioningError.deviceError(String(response.dropFirst(4)))
        }
        throw ProvisioningError.badResponse(response)
    }

    private static func configure(fd: Int32) throws {
        var tio = termios()
        if tcgetattr(fd, &tio) != 0 {
            throw ProvisioningError.configFailed(errnoString())
        }
        cfmakeraw(&tio)
        let speed = speed_t(B115200)
        if cfsetspeed(&tio, speed) != 0 {
            throw ProvisioningError.configFailed(errnoString())
        }
        let cs8 = tcflag_t(CS8)
        let csize = tcflag_t(CSIZE)
        let parenb = tcflag_t(PARENB)
        let cstopb = tcflag_t(CSTOPB)
        let clocal = tcflag_t(CLOCAL)
        let cread = tcflag_t(CREAD)

        tio.c_cflag &= ~csize
        tio.c_cflag |= cs8
        tio.c_cflag &= ~parenb
        tio.c_cflag &= ~cstopb
        tio.c_cflag |= (clocal | cread)

        // VMIN=0, VTIME=10 → read returns after up to 1s with whatever's available.
        // We loop on top of this for an overall timeout.
        withUnsafeMutablePointer(to: &tio.c_cc) {
            $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { buf in
                buf[Int(VMIN)] = 0
                buf[Int(VTIME)] = 10
            }
        }

        if tcsetattr(fd, TCSANOW, &tio) != 0 {
            throw ProvisioningError.configFailed(errnoString())
        }
        _ = tcflush(fd, TCIOFLUSH)
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var p = raw.baseAddress else { return }
            var remaining = data.count
            while remaining > 0 {
                let n = Darwin.write(fd, p, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ProvisioningError.writeFailed(errnoString())
                }
                remaining -= n
                p = p.advanced(by: n)
            }
        }
    }

    /// Firmware `OK:`/`ERR:` replies are short; cap the in-progress line so a
    /// device that never frames a newline can't grow the buffer without bound
    /// before the deadline fires.
    private static let maxLineBytes = 4096

    private static func readLine(fd: Int32, timeout: TimeInterval) throws -> String {
        var buffer = [UInt8]()
        let deadline = Date().addingTimeInterval(timeout)
        var chunk = [UInt8](repeating: 0, count: 256)

        while Date() < deadline {
            let n = chunk.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw ProvisioningError.readFailed(errnoString())
            }
            if n == 0 { continue }
            for i in 0..<n {
                let byte = chunk[i]
                if byte == 0x0D { continue }
                if byte == 0x0A {
                    if !buffer.isEmpty {
                        let line = String(decoding: buffer, as: UTF8.self)
                        if line.hasPrefix("OK:") || line.hasPrefix("ERR:") {
                            return line
                        }
                        buffer.removeAll(keepingCapacity: true)
                    }
                    continue
                }
                buffer.append(byte)
                if buffer.count > maxLineBytes {
                    buffer.removeAll(keepingCapacity: true)
                }
            }
        }
        throw ProvisioningError.ackTimeout
    }

    private static func errnoString() -> String {
        return String(cString: strerror(errno))
    }
}
