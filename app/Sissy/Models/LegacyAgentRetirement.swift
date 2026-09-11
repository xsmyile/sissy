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
        /// Whether this run settled the question. False when a lookup or an
        /// unregister failed, which is the one case worth trying again: the
        /// alternative is an agent that starts at login forever because a
        /// single bad launch spent the one shot.
        var conclusive: Bool = true
    }

    private static func liveStatus(_ label: String) -> SMAppService.Status {
        SMAppService.agent(plistName: "\(label).plist").status
    }

    private static func liveUnregister(_ label: String) throws {
        try SMAppService.agent(plistName: "\(label).plist").unregister()
    }

    /// Runs once per install, where "once" means once *conclusively* —
    /// `markRan` is only called when the question was actually settled.
    /// `alreadyRan` and `markRan` carry the flag so the caller owns where it
    /// is stored and a test can run this against nothing persistent.
    @MainActor
    static func run(
        alreadyRan: Bool,
        agentStatus: (String) -> SMAppService.Status = Self.liveStatus,
        unregisterAgent: (String) throws -> Void = Self.liveUnregister,
        loginItem: LoginItemController = LoginItemController(),
        markRan: () -> Void
    ) -> Outcome {
        guard !alreadyRan else { return Outcome() }

        var outcome = unregisterAll(agentStatus: agentStatus, unregisterAgent: unregisterAgent)
        if outcome.conclusive { markRan() }
        guard !outcome.retired.isEmpty else { return outcome }

        // Only now, and only because something was retired: the agent held a
        // login item the app has to take over, or the user stops counting.
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

    private static func unregisterAll(
        agentStatus: (String) -> SMAppService.Status,
        unregisterAgent: (String) throws -> Void
    ) -> Outcome {
        var outcome = Outcome()
        for label in labels {
            switch agentStatus(label) {
            case .notRegistered:
                // launchd does not know it. Nothing to undo, and nothing
                // will register it again — the app no longer can.
                continue
            case .notFound:
                // The plist is not in this bundle, so `unregister()` has
                // nothing to resolve and a registration launchd may still
                // hold cannot be reached from here. Never spend the one shot
                // on that answer: it is the shape of a packaging mistake,
                // not of a clean machine.
                daemonLog(
                    "sissy: \(label) is not resolvable from this bundle; "
                        + "leaving it for the next launch")
                outcome.conclusive = false
            default:
                retire(label, using: unregisterAgent, into: &outcome)
            }
        }
        return outcome
    }

    private static func retire(
        _ label: String,
        using unregisterAgent: (String) throws -> Void,
        into outcome: inout Outcome
    ) {
        do {
            try unregisterAgent(label)
            outcome.retired.append(label)
        } catch {
            // Already gone is the state we wanted.
            guard (error as NSError).code == kSMErrorJobNotFound else {
                daemonLog("sissy: could not retire the \(label) agent: \(error)")
                outcome.conclusive = false
                return
            }
            outcome.retired.append(label)
        }
    }
}
