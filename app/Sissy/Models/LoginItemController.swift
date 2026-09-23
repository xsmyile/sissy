import Foundation
import Observation
import ServiceManagement

/// Whether macOS opens Sissy at login, through `SMAppService.mainApp`.
///
/// The only login item Sissy has. It used to be the second of two — the
/// retired agent carried `RunAtLoad` and counted whether or not the app was
/// running — which is why `LegacyAgentRetirement` claims this one on behalf
/// of a user whose counting used to come from the agent.
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

    /// Where the running copy lives, read once: a bundle does not move while
    /// it runs, and what it says decides whether the switch can turn on.
    @ObservationIgnored let location: BundleLocation

    /// `service` is injected so a test can point the controller at a service
    /// that is definitely not registered, and `location` so a test can stand
    /// the app on a copy that is about to vanish. Left to their defaults they
    /// ask about the running app.
    init(service: SMAppService = .mainApp, location: BundleLocation = .current()) {
        self.service = service
        self.location = location
    }

    var isEnabled: Bool { status == .enabled }

    /// macOS keeps the registration but has it switched off in Login Items,
    /// which only the user can undo — a `register()` from here would not.
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = service.status
    }

    /// Turning the login item on from a transient copy throws
    /// `BundleLocation.Refusal` before launchd is asked: the registration
    /// would name a bundle that is gone by the next login. Turning it off is
    /// always passed through, since a registration made from an earlier copy
    /// is one the user has every reason to take back.
    func setEnabled(_ enabled: Bool) throws {
        if enabled, location.isTransient { throw BundleLocation.Refusal(location) }
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
