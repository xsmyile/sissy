import Foundation

/// Best-effort lookup of the SSID the Mac is currently joined to.
///
/// Modern macOS makes this unreasonably hard: CoreWLAN requires Location
/// permission since 10.15, and `networksetup -getairportnetwork` can return
/// any of half a dozen failure strings depending on which interface is which
/// on a given Mac. We try every hardware port the system advertises as
/// "Wi-Fi" and bail to nil the moment we see an error pattern — better to
/// leave the SSID field blank than to autofill garbage like the "Error
/// obtaining wireless information." message itself.
enum WiFiInfo {
    static func currentSSID() -> String? {
        for iface in wifiInterfaces() {
            if let ssid = try? ssid(on: iface) {
                return ssid
            }
        }
        return nil
    }

    /// Returns the Wi-Fi BSD interfaces (`en0`, `en1`, …) reported by
    /// `networksetup -listallhardwareports`. Falls back to a hardcoded list
    /// if parsing fails.
    private static func wifiInterfaces() -> [String] {
        let output = run("/usr/sbin/networksetup", ["-listallhardwareports"]) ?? ""
        var results: [String] = []
        var nextIsDevice = false
        for line in output.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("Hardware Port:") {
                nextIsDevice = l.lowercased().contains("wi-fi") || l.lowercased().contains("wifi")
                continue
            }
            if nextIsDevice, l.hasPrefix("Device:") {
                let dev = l.replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
                if !dev.isEmpty { results.append(dev) }
                nextIsDevice = false
            }
        }
        if results.isEmpty { return ["en0", "en1", "en2"] }
        return results
    }

    private static func ssid(on iface: String) throws -> String {
        let output = run("/usr/sbin/networksetup", ["-getairportnetwork", iface]) ?? ""
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeError(trimmed) { throw NSError(domain: "sissy.wifi", code: 1) }

        // Expected: "Current Wi-Fi Network: <SSID>"
        guard let colon = trimmed.range(of: "Network:") else {
            throw NSError(domain: "sissy.wifi", code: 2)
        }
        let ssid = trimmed[colon.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if ssid.isEmpty { throw NSError(domain: "sissy.wifi", code: 3) }
        return ssid
    }

    /// Treat anything we can't confidently parse as a usable SSID as an error.
    private static func looksLikeError(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.contains("error")
            || lower.contains("not associated")
            || lower.contains("not a wi-fi interface")
            || lower.contains("not a wifi interface")
            || s.isEmpty
    }

    private static func run(_ exe: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}
