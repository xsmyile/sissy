import Combine
import Foundation
import SwiftUI

@MainActor
final class PairingViewModel: ObservableObject {
    @Published var availablePorts: [SerialPort] = []
    @Published var selectedPort: SerialPort? = nil

    @Published var ssid: String = ""
    @Published var wifiPassword: String = ""
    @Published var serverHost: String = ""
    @Published var serverPort: Int = 8787
    @Published var authToken: String = ""
    @Published var revealToken: Bool = false
    @Published var otaPassword: String = Preferences.makeSecret()

    @Published var status: Status = .idle
    @Published var lastInfo: String? = nil

    let wifiScanner = WiFiScanner()

    private var wifiScannerCancellable: AnyCancellable?

    enum Status: Equatable {
        case idle
        case sendingConfiguration
        case waitingForDevice(serverConfigurationChanged: Bool)
        case failure(String)
    }

    init() {
        // Forward WiFiScanner updates so SwiftUI views observing this view
        // model re-render when the scanner's @Published values change. Without
        // this bridge, nested ObservableObjects don't propagate change
        // notifications past the immediate parent.
        wifiScannerCancellable = wifiScanner.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        refreshPorts()
        // `prefillFromHost` shells out to `/usr/sbin/networksetup` twice
        // (once for the hardware port list, once per Wi-Fi interface for the
        // current SSID). Both are synchronous `Process.waitUntilExit()` calls
        // and add up to a few hundred ms on a cold path. Running them in
        // `init()` froze the main thread long enough that the `activate(from:)`
        // focus transfer couldn't complete before `makeKeyAndOrderFront`, so
        // the Pair window opened behind the frontmost app and the Dock policy
        // change never rendered. Offload to a detached Task so the window
        // paints first and the fields populate a beat later.
        Task { [weak self] in
            await self?.prefillFromHostAsync()
        }
    }

    func applyPreferences(_ preferences: Preferences) {
        if authToken.isEmpty {
            authToken = preferences.authToken
        }
        serverPort = preferences.serverPort
    }

    func refreshPorts() {
        availablePorts = SerialPortDiscovery.list()
        if selectedPort == nil || availablePorts.contains(selectedPort!) == false {
            selectedPort = availablePorts.first
        }
    }

    private func prefillFromHostAsync() async {
        let ip = await Task.detached(priority: .utility) { LANAddress.first() }.value
        let ssid = await Task.detached(priority: .utility) { WiFiInfo.currentSSID() }.value
        if let ip {
            serverHost = ip
        }
        // Try the cheap networksetup-based detection first; CoreWLAN's
        // version needs a Location prompt the user hasn't seen yet.
        if let ssid, self.ssid.isEmpty {
            self.ssid = ssid
        }
    }

    func scanWiFi() async {
        await wifiScanner.scan()
        if ssid.isEmpty, let current = wifiScanner.currentSSID {
            ssid = current
        }
    }

    func pickSSID(_ value: String) {
        ssid = value
    }

    var canSend: Bool {
        if case .sendingConfiguration = status { return false }
        return selectedPort != nil
            && !ssid.isEmpty
            && !wifiPassword.isEmpty
            && isHostValid
            && !authToken.isEmpty
            && isOtaPasswordValid
    }

    var isOtaPasswordValid: Bool {
        otaPassword.count >= Preferences.minimumSecretLength
    }

    var isHostValid: Bool {
        Self.isValidProvisioningHost(serverHost)
    }

    var hostValidationMessage: String? {
        Self.provisioningHostError(serverHost)
    }

    /// Provisioning host validator. Empty values and loopback addresses are
    /// rejected so the ESP32 never gets pointed at itself or at a placeholder
    /// — both produce a silent "ws down" with no remediation path for the
    /// user. Returns true when the value looks routable from the device.
    /// `nonisolated` so tests and other off-main callers can use it as a pure
    /// function without hopping onto the MainActor.
    nonisolated static func isValidProvisioningHost(_ raw: String) -> Bool {
        provisioningHostError(raw) == nil
    }

    /// Returns a UI-ready error string when `raw` is unfit as a server host
    /// for the firmware to connect to. nil means the value passes validation.
    nonisolated static func provisioningHostError(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter your Mac's LAN IP or hostname." }
        let lower = trimmed.lowercased()
        if lower == "localhost" || lower == "::1" || lower == "0.0.0.0" || lower == "::" {
            return "Device can't reach \(trimmed). Use your Mac's LAN IP."
        }
        // Full 127.0.0.0/8 loopback range.
        let octets = trimmed.split(separator: ".")
        if octets.count == 4, octets[0] == "127", octets.allSatisfy({ UInt8($0) != nil }) {
            return "Device can't reach \(trimmed). Use your Mac's LAN IP."
        }
        return nil
    }

    func generateToken() {
        authToken = Preferences.makeSecret()
        revealToken = true
        // Don't auto-copy. The user gets an explicit "Copy" button after
        // the reveal toggle flips — avoids silently planting a freshly
        // generated secret in the pasteboard where a clipboard manager
        // could keep a history.
    }

    func generateOTAPassword() {
        otaPassword = Preferences.makeSecret()
        lastInfo = "OTA password regenerated."
    }

    func copyTokenToPasteboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(authToken, forType: .string)
        lastInfo = "Token copied to clipboard."
    }

    /// Writes the daemon-facing `server.json` with the confirmed bearer token
    /// and port. The SwiftUI view has already saved the same values into the
    /// shared `SissyModel.preferences`; this method keeps direct `send()` callers
    /// safe and surfaces the daemon-restart hint after pairing.
    func persistServerCredentials() {
        var prefs = Preferences.load()
        prefs.authToken = authToken
        prefs.serverPort = serverPort
        prefs.save()
        prefs.writeServerConfig()
        lastInfo = "Token and port saved."
    }

    func send(serverConfigurationChanged: Bool) {
        guard let port = selectedPort else { return }
        guard isOtaPasswordValid else {
            status = .failure("OTA password must be at least \(Preferences.minimumSecretLength) characters.")
            return
        }
        if let hostErr = hostValidationMessage {
            status = .failure(hostErr)
            return
        }
        status = .sendingConfiguration
        persistServerCredentials()

        let trimmedHost = serverHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = ProvisionRequest.make(
            ssid: ssid,
            password: wifiPassword,
            host: trimmedHost,
            port: serverPort,
            token: authToken,
            otaPassword: otaPassword
        )

        Task {
            do {
                try await Provisioner.shared.send(request, to: port)
                await MainActor.run {
                    self.status = .waitingForDevice(
                        serverConfigurationChanged: serverConfigurationChanged
                    )
                }
            } catch {
                await MainActor.run {
                    self.status = .failure(error.localizedDescription)
                }
            }
        }
    }
}

/// Returns the host's primary IPv4 LAN address by querying getifaddrs and
/// preferring `en0` / `en1`. Avoids `127.0.0.1` and link-local 169.x.
enum LANAddress {
    static func first() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0, let start = ifaddr else { return nil }
        defer { freeifaddrs(start) }

        var candidates: [(name: String, ip: String)] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = start
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = cur.pointee.ifa_addr else { continue }
            guard addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            // macOS 26 deprecated both `String(cString:)` and
            // `String(validatingCString:)` in favor of the truncated-buffer
            // overload. `decodeCString` does the strnlen + rebind dance once.
            let ip = Self.decodeCString(host, capacity: Int(NI_MAXHOST))
            if ip.hasPrefix("169.254.") { continue }
            let name = Self.decodeCString(cur.pointee.ifa_name, capacity: 256)
            candidates.append((name, ip))
        }

        if let preferred = candidates.first(where: { ["en0", "en1"].contains($0.name) }) {
            return preferred.ip
        }
        return candidates.first?.ip
    }

    /// Decode a null-terminated C string into Swift via the macOS 26
    /// recommended path: rebind to `UInt8`, slice off the trailing NUL with
    /// `strnlen`, decode UTF-8. Invalid bytes become U+FFFD — acceptable
    /// for hostname/IP display which never carries arbitrary user input.
    private static func decodeCString(_ ptr: UnsafePointer<CChar>, capacity: Int) -> String {
        let len = strnlen(ptr, capacity)
        return ptr.withMemoryRebound(to: UInt8.self, capacity: capacity) { rebound in
            String(decoding: UnsafeBufferPointer(start: rebound, count: len), as: UTF8.self)
        }
    }
}
