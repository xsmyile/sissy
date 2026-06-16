import AppKit
import CoreLocation
import CoreWLAN
import Foundation
import Observation

/// Async wrapper around CoreWLAN. On macOS 11+, both `scanForNetworks` and
/// even reading a `CWNetwork.ssid` return nil/throw unless the app holds
/// Location authorization — so this class doubles as the location-permission
/// gatekeeper. The Pair window asks the user once on first scan; subsequent
/// scans skip the prompt.
@MainActor
@Observable
final class WiFiScanner: NSObject {
    var networks: [String] = []
    var currentSSID: String? = nil
    var isScanning: Bool = false
    var errorMessage: String? = nil
    var locationAuthorized: Bool = false
    var permissionState: PermissionState = .unknown

    enum PermissionState {
        case unknown  // never asked
        case authorized
        case denied  // user said no, or auth restricted — prompt won't reappear
        case awaitingUser  // request fired, waiting for the prompt result
    }

    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private var pendingAuthContinuation: CheckedContinuation<Bool, Never>? = nil

    override init() {
        super.init()
        locationManager.delegate = self
        let status = locationManager.authorizationStatus
        locationAuthorized = isAuthorized(status)
        permissionState = mapState(status)
        refreshCurrentSSID()
    }

    private func mapState(_ status: CLAuthorizationStatus) -> PermissionState {
        switch status {
        case .notDetermined: return .unknown
        case .authorizedAlways, .authorizedWhenInUse: return .authorized
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    func scan() async {
        isScanning = true
        defer { isScanning = false }
        errorMessage = nil

        // CoreWLAN's cached scan can return in <100 ms on a Mac that has
        // recently joined the network — too fast for SwiftUI to even render
        // the spinner. Hold the indicator visible for at least this long so
        // the user can tell a scan actually happened.
        let minVisible: UInt64 = 700_000_000  // 700 ms
        let started = DispatchTime.now().uptimeNanoseconds

        if !locationAuthorized {
            let granted = await requestLocation()
            if !granted {
                errorMessage = "Location permission denied — Apple requires it to read Wi-Fi SSIDs."
                return
            }
        }

        guard let iface = CWWiFiClient.shared().interface() else {
            errorMessage = "No Wi-Fi interface on this Mac."
            return
        }

        // CoreWLAN's scanForNetworks blocks for several seconds. Running it on
        // the main actor would freeze the UI — the spinner never gets a chance
        // to render. Bounce to a detached task and bring the SSIDs back here
        // for a single @MainActor publish.
        let scanned: ScanOutcome = await Task.detached(priority: .userInitiated) {
            do {
                let networks = try iface.scanForNetworks(withSSID: nil)
                let ssids = Array(Set(networks.compactMap { $0.ssid }))
                    .filter { !$0.isEmpty }
                    .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                return .success(ssids: ssids, current: iface.ssid())
            } catch {
                return .failure(error.localizedDescription)
            }
        }.value

        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        if elapsed < minVisible {
            try? await Task.sleep(nanoseconds: minVisible - elapsed)
        }

        switch scanned {
        case .success(let ssids, let current):
            self.networks = ssids
            self.currentSSID = current
        case .failure(let message):
            errorMessage = "Scan failed: \(message)"
        }
    }

    private enum ScanOutcome {
        case success(ssids: [String], current: String?)
        case failure(String)
    }

    /// Reads the joined SSID without forcing a scan. Useful as an initial
    /// pre-fill once Location has already been granted in a previous run.
    func refreshCurrentSSID() {
        guard locationAuthorized,
            let iface = CWWiFiClient.shared().interface()
        else { return }
        currentSSID = iface.ssid()
    }

    private func requestLocation() async -> Bool {
        let status = locationManager.authorizationStatus
        if isAuthorized(status) {
            return true
        }
        if status == .denied || status == .restricted {
            // macOS won't show the prompt again — surface this to the UI so it
            // can offer "Open System Settings" rather than appearing broken.
            return false
        }
        permissionState = .awaitingUser
        locationManager.requestWhenInUseAuthorization()

        // Timeout guards against the prompt being dismissed by a session
        // reload or never delivered (delegate misfire). Without it, scan()
        // would hang on the continuation forever.
        let timeoutNs: UInt64 = 30 * 1_000_000_000
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNs)
            self?.resumePendingAuthIfStuck()
        }
        let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            pendingAuthContinuation = cont
        }
        timeoutTask.cancel()
        return granted
    }

    private func resumePendingAuthIfStuck() {
        guard let cont = pendingAuthContinuation else { return }
        pendingAuthContinuation = nil
        cont.resume(returning: isAuthorized(locationManager.authorizationStatus))
    }

    /// Returns true when the user has previously denied permission so the UI
    /// can route them to System Settings instead of trying to re-prompt.
    var permissionPermanentlyDenied: Bool {
        return permissionState == .denied
    }

    /// Opens the macOS Privacy & Security → Location Services pane.
    static func openSystemLocationSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
        {
            NSWorkspace.shared.open(url)
        }
    }

    private func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        default:
            return false
        }
    }
}

extension WiFiScanner: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            let determined = status != .notDetermined
            self.locationAuthorized = isAuthorized(status)
            self.permissionState = mapState(status)
            self.refreshCurrentSSID()
            NSLog(
                "[Sissy] LocationManager status=\(status.rawValue) determined=\(determined) authorized=\(self.locationAuthorized)"
            )
            if determined, let cont = self.pendingAuthContinuation {
                self.pendingAuthContinuation = nil
                cont.resume(returning: self.locationAuthorized)
            }
        }
    }
}
