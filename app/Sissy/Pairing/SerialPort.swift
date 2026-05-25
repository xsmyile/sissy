import Foundation

struct SerialPort: Identifiable, Hashable {
    let path: String
    var id: String { path }

    /// Human-friendly label. /dev/cu.usbserial-10 → "usbserial-10"
    var displayName: String {
        let base = (path as NSString).lastPathComponent
        if base.hasPrefix("cu.") {
            return String(base.dropFirst(3))
        }
        return base
    }
}

enum SerialPortDiscovery {
    private static let blocklist = [
        "Bluetooth-Incoming-Port",
        "debug-console",
        "wireless-debug",
    ]

    /// The microcontroller USB-UART chips you almost certainly want: FTDI,
    /// Silicon Labs CP210x, WCH CH340/CH9102 — what the ESP32, RP2040, and
    /// Arduino dev boards ship with.
    private static let usbSerialHints = [
        "usbserial",
        "wchusbserial",
        "SLAB_USBtoUART",
        "CP210",
        "CH9102",
    ]

    static func list() -> [SerialPort] {
        let dev = "/dev"
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dev) else {
            return []
        }

        let entries =
            contents
            .filter { $0.hasPrefix("cu.") }
            .filter { !blocklist.contains(where: $0.contains) }
            .filter { isLikelyMicrocontroller($0) }
            .sorted(by: priorityCompare)

        return entries.map { SerialPort(path: "\(dev)/\($0)") }
    }

    /// Keep USB-UART converters always; allow `cu.usbmodem*` only when its
    /// suffix looks like an Arduino-style short numeric tag. iPhone tethering
    /// shows up as `cu.usbmodem<serial>` with 10+ alphanumeric characters and
    /// is what users mistakenly select first when it sorts before the ESP32.
    private static func isLikelyMicrocontroller(_ name: String) -> Bool {
        if usbSerialHints.contains(where: name.contains) { return true }
        if name.hasPrefix("cu.usbmodem") {
            let suffix = String(name.dropFirst("cu.usbmodem".count))
            // Heuristic: Arduino-style devices end with a short numeric id
            // (e.g. usbmodem21101). iPhone tethering uses a long alphanumeric
            // serial like usbmodem204NTBK8C3412.
            if suffix.count <= 6, suffix.allSatisfy(\.isNumber) {
                return true
            }
            return false
        }
        // Conservative default: anything else cu.* is not what we're after.
        return false
    }

    /// Sort `usbserial-*` first because that's the overwhelmingly common ESP32
    /// path, then fall back to alphabetical.
    private static func priorityCompare(_ a: String, _ b: String) -> Bool {
        let aIsUsbSerial = a.contains("usbserial")
        let bIsUsbSerial = b.contains("usbserial")
        if aIsUsbSerial != bIsUsbSerial {
            return aIsUsbSerial
        }
        return a < b
    }
}
