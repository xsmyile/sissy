import Foundation
import ServiceManagement

/// Removes the `sissy-serverd` LaunchAgent left behind by an install that
/// predates the app metering in-process.
///
/// Two steps, not one. Until this version the Server switch and "Start at
/// login" were independent, and Server on with the app *not* at login was a
/// legitimate way to run Sissy: the agent counted whether or not the menu bar
/// icon came back. Unregistering the agent alone would silently stop counting
/// for exactly those users, so the app takes over the login item the agent
/// used to hold.
///
/// The one-shot flag is not a mirror of the login state — `SMAppService`
/// stays the record for that. It records that the *migration* ran, so a user
/// who later removes Sissy from Login Items does not get it put back on the
/// next launch.
enum LegacyAgentRetirement {
    /// Agent labels this has to look for. The release build registered the
    /// first, a locally built dev bundle the second, and a machine can carry
    /// both.
    static let labels = ["com.radonforge.sissy.server", "com.radonforge.sissy.server.dev"]

    struct Outcome: Equatable {
        /// Labels whose agent was registered and has now been unregistered.
        var retired: [String] = []
        /// Whether the app claimed the login item the agent used to hold.
        var claimedLoginItem: Bool = false
    }

    private static func liveStatus(_ label: String) -> SMAppService.Status {
        SMAppService.agent(plistName: "\(label).plist").status
    }

    private static func liveUnregister(_ label: String) throws {
        try SMAppService.agent(plistName: "\(label).plist").unregister()
    }

    /// Runs once per install. `alreadyRan` and `markRan` carry the flag so
    /// the caller owns where it is stored and a test can run this against
    /// nothing persistent.
    @MainActor
    static func run(
        alreadyRan: Bool,
        agentStatus: (String) -> SMAppService.Status = Self.liveStatus,
        unregisterAgent: (String) throws -> Void = Self.liveUnregister,
        loginItem: LoginItemController = LoginItemController(),
        markRan: () -> Void
    ) -> Outcome {
        guard !alreadyRan else { return Outcome() }
        defer { markRan() }

        var outcome = Outcome()
        for label in labels {
            // `.notFound` is the answer for a plist this bundle no longer
            // ships, which is every machine that installed after the agent
            // was removed. Only a registration launchd still knows about is
            // worth undoing.
            guard agentStatus(label) != .notFound, agentStatus(label) != .notRegistered else { continue }
            do {
                try unregisterAgent(label)
                outcome.retired.append(label)
            } catch {
                let nsError = error as NSError
                // Already gone is the state we wanted.
                guard nsError.code == kSMErrorJobNotFound else {
                    daemonLog("sissy: could not retire the \(label) agent: \(error)")
                    continue
                }
                outcome.retired.append(label)
            }
        }

        guard !outcome.retired.isEmpty else { return outcome }
        loginItem.refresh()
        guard !loginItem.isEnabled, !loginItem.requiresApproval else { return outcome }
        do {
            try loginItem.setEnabled(true)
            outcome.claimedLoginItem = true
        } catch {
            daemonLog("sissy: retired the server agent but could not claim the login item: \(error)")
        }
        return outcome
    }
}
