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

/// Owns the power assertions that stop the Mac, and its screen, idling off.
///
/// The hold dies with the process, deliberately: a Mac held awake by
/// something with no icon in the menu bar is a battery complaint with no path
/// back to its cause. The *mode* survives in `server.json`, so the next launch
/// resumes the hold the user asked for.
actor KeepAwake {
    private var system: IOPMAssertionID?
    private var display: IOPMAssertionID?

    /// Two assertions, not the display one alone — which already keeps the
    /// system up for as long as the screen is lit. A screen blanked by hand,
    /// from a hot corner or ⌃⇧⏻, takes that effect away with it, and the Mac
    /// would idle to sleep under a switch the user left on. Holding both makes
    /// the screen the addition it reads as and never the whole hold.
    ///
    /// A lit screen is also a Mac that does not lock itself, which is the one
    /// consequence here a user would not predict; the panel's control says so
    /// rather than leaving it to be discovered.
    ///
    /// Neither assertion survives the lid closing. macOS sleeps a laptop on
    /// clamshell whoever is asserting what, unless it is on power with an
    /// external display attached — which is its own feature and not one Sissy
    /// can grant.
    private static let systemType = kIOPMAssertionTypePreventUserIdleSystemSleep
    private static let displayType = kIOPMAssertionTypePreventUserIdleDisplaySleep
    private static let systemName = "Sissy is keeping this Mac awake"
    private static let displayName = "Sissy is keeping this screen on"

    /// Drives the hold to `holding` and reports whether the Mac is being kept
    /// awake.
    ///
    /// Reporting rather than throwing is what keeps the engine honest: power
    /// management refusing an assertion is nothing this layer can act on, but
    /// it is something the user has to see — the panel then shows the mode they
    /// chose and a Mac that is not being held. The answer follows the system
    /// assertion, which is what that claim is about: a refused display
    /// assertion leaves a Mac that stays up behind a screen that dims, and says
    /// so in the log rather than retracting the hold that did take.
    ///
    /// The reverse is not survivable the same way, so it is not survived: a
    /// false answer has to mean nothing is held, or the panel would report a
    /// Mac free to sleep while a screen assertion quietly kept it up. A system
    /// assertion that could not be taken therefore drops the display one with
    /// it.
    ///
    /// Serialising every change through this actor is also what makes two mode
    /// switches in the same instant safe: they arrive in order and the last one
    /// decides.
    func apply(holding: Bool) -> Bool {
        guard holding else {
            releaseAll()
            return false
        }
        if system == nil { system = create(Self.systemType, named: Self.systemName) }
        if display == nil { display = create(Self.displayType, named: Self.displayName) }
        if system == nil { releaseAll() }
        return system != nil
    }

    private func releaseAll() {
        release(&display, named: Self.displayName)
        release(&system, named: Self.systemName)
    }

    private func create(_ type: String, named name: String) -> IOPMAssertionID? {
        var id = IOPMAssertionID(0)
        let status = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &id
        )
        guard status == kIOReturnSuccess else {
            sissyLog(
                "sissy: power management refused the \(type) assertion "
                    + "(IOReturn \(status)) — that half of the hold is not in effect")
            return nil
        }
        return id
    }

    /// Releasing what is not held is not an error: `stop()` runs on every exit
    /// path, including the ones where nothing was ever held.
    private func release(_ assertion: inout IOPMAssertionID?, named name: String) {
        guard let id = assertion else { return }
        assertion = nil
        let status = IOPMAssertionRelease(id)
        if status != kIOReturnSuccess {
            sissyLog("sissy: releasing \"\(name)\" returned IOReturn \(status)")
        }
    }
}
