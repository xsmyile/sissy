import Foundation
import Observation
import ServiceManagement

/// Whether macOS opens Sissy at login, through `SMAppService.mainApp`.
///
/// Deliberately separate from `ServerServiceController`: the daemon's agent
/// carries `RunAtLoad`, so once the Server is on it starts at login and keeps
/// counting whether or not the app is running. This decides one thing only,
/// whether the menu bar icon comes back with it.
///
/// `SMAppService` is the state, and no copy of it lands in
/// `preferences.json`: someone who removes Sissy from System Settings' Login
/// Items would leave a mirrored flag behind, and the switch would then claim
/// something the system had already undone.
@MainActor
@Observable
final class LoginItemController {
    private(set) var status: SMAppService.Status = .notRegistered

    @ObservationIgnored private let service: SMAppService

    /// `service` is injected so a test can point the controller at a service
    /// that is definitely not registered. Left to its default it asks about
    /// the running app.
    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    var isEnabled: Bool { status == .enabled }

    /// macOS keeps the registration but has it switched off in Login Items,
    /// which only the user can undo — a `register()` from here would not.
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = service.status
    }

    func setEnabled(_ enabled: Bool) throws {
        defer { refresh() }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            let nsError = error as NSError
            guard Self.isAlreadyInRequestedState(nsError, enabling: enabled) else { throw error }
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// launchd reports "already registered" and "no such job" as failures.
    /// Both mean the login item is in the state that was asked for, which is
    /// success as far as the switch is concerned.
    nonisolated static func isAlreadyInRequestedState(_ error: NSError, enabling: Bool) -> Bool {
        enabling ? error.code == kSMErrorAlreadyRegistered : error.code == kSMErrorJobNotFound
    }
}
