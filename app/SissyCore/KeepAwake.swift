import Foundation
import IOKit.pwr_mgt

/// What the user asked Sissy to do about sleep.
///
/// Persisted in `server.json` rather than held in memory: a mode is a setting,
/// not a transient hold, and someone who switched their Mac to never sleep
/// expects it to still be that way the next time Sissy launches.
enum KeepAwakeMode: String, Sendable, Codable {
    case off
    case on
}

/// The mode together with whether the Mac is actually being held awake right
/// now. They come apart when power management refuses the assertion, which is
/// the reason for carrying both: the mode stays where the user put it and
/// `active` says what came of it, so a refusal is visible instead of silent.
struct KeepAwakeState: Sendable, Equatable {
    let mode: KeepAwakeMode
    let active: Bool

    static let off = Self(mode: .off, active: false)
}

/// Owns the power assertion that stops the Mac idling to sleep.
///
/// The hold dies with the process, deliberately: a Mac held awake by
/// something with no icon in the menu bar is a battery complaint with no path
/// back to its cause. The *mode* survives in `server.json`, so the next launch
/// resumes the hold the user asked for.
actor KeepAwake {
    private var assertion: IOPMAssertionID?

    /// Prevents the *idle* system sleep, which is the one that interrupts a
    /// running agent. The display is left to sleep on its own: a run needs no
    /// lit screen, and holding one awake would drain a laptop for nothing.
    ///
    /// Neither assertion survives the lid closing, which is why the app says so
    /// next to the control rather than leaving it to be discovered by a lost
    /// run.
    private static let assertionType = kIOPMAssertionTypePreventUserIdleSystemSleep
    private static let assertionName = "Sissy is keeping this Mac awake"

    /// Drives the assertion to `holding` and reports what it ended up as.
    ///
    /// Reporting rather than throwing is what keeps the engine honest: power
    /// management refusing the assertion is nothing this layer can act on, but
    /// it is something the user has to see — the panel then shows the mode they
    /// chose and a Mac that is not being held.
    ///
    /// Serialising every change through this actor is also what makes two mode
    /// switches in the same instant safe: they arrive in order and the last one
    /// decides.
    func apply(holding: Bool) -> Bool {
        if holding {
            hold()
        } else {
            release()
        }
        return assertion != nil
    }

    private func hold() {
        guard assertion == nil else { return }
        var id = IOPMAssertionID(0)
        let status = IOPMAssertionCreateWithName(
            Self.assertionType as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.assertionName as CFString,
            &id
        )
        guard status == kIOReturnSuccess else {
            sissyLog(
                "sissy: power management refused the keep-awake assertion "
                    + "(IOReturn \(status)) — the Mac will sleep as usual")
            return
        }
        assertion = id
    }

    /// Releasing what is not held is not an error: `stop()` runs on every exit
    /// path, including the ones where nothing was ever held.
    private func release() {
        guard let id = assertion else { return }
        assertion = nil
        let status = IOPMAssertionRelease(id)
        if status != kIOReturnSuccess {
            sissyLog("sissy: keep-awake release returned IOReturn \(status)")
        }
    }
}
