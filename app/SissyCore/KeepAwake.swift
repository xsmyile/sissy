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
    /// Whether the screen is being held lit alongside the Mac.
    ///
    /// The effect and not the setting: `keepScreenAwake` is what the user
    /// asked for, and this is what power management granted. The panel words
    /// its control from this, so a screen assertion that was refused stops the
    /// tooltip promising a screen that is about to dim.
    let coversScreen: Bool
    /// When the hold in force right now was taken, and `nil` whenever nothing
    /// is being held.
    ///
    /// In memory only, like the assertions it describes. A hold does not
    /// survive the process, so neither does its instant: a relaunch that
    /// resumes the mode takes a fresh hold and this says so. It reads as
    /// "held since", never as "switched on since", which is the same
    /// distinction `active` already draws against `mode`.
    let since: Date?

    /// Normalises against `active` rather than trusting callers to: an instant
    /// without a hold is a stopwatch running on a Mac that is free to sleep,
    /// and a screen held on behind a Mac that is not is the state `apply`
    /// refuses to leave behind.
    init(mode: KeepAwakeMode, active: Bool, since: Date? = nil, coversScreen: Bool = false) {
        self.mode = mode
        self.active = active
        self.since = active ? since : nil
        self.coversScreen = active && coversScreen
    }

    static let off = Self(mode: .off, active: false)
}

/// What the assertions actually got, which is not always what was asked for.
///
/// Two flags rather than one because they fail apart: power management can
/// refuse the display half and grant the system half, leaving a Mac that stays
/// up behind a screen that dims.
struct KeepAwakeHold: Sendable, Equatable {
    let system: Bool
    let screen: Bool

    static let none = Self(system: false, screen: false)
}

/// Owns the power assertions that stop the Mac, and optionally its screen,
/// idling off.
///
/// The hold dies with the process, deliberately: a Mac held awake by
/// something with no icon in the menu bar is a battery complaint with no path
/// back to its cause. The *mode* survives in `server.json`, so the next launch
/// resumes the hold the user asked for.
actor KeepAwake {
    private var system: IOPMAssertionID?
    private var display: IOPMAssertionID?

    /// The system assertion is the hold; the display one is an addition on
    /// top of it, never a substitute. Taking the display assertion alone would
    /// keep the system up only for as long as the screen stayed lit, and a
    /// screen blanked by hand — a hot corner, ⌃⇧⏻ — takes that effect away
    /// with it, leaving the Mac free to idle to sleep under a switch the user
    /// had left on. That asymmetry is why `keepScreenAwake` can drop the
    /// display half and nothing can drop the system half.
    ///
    /// A lit screen is also a Mac that does not lock itself, which is the one
    /// consequence here a user would not predict, and the reason the screen
    /// half is a setting at all: someone leaving agents running on a Mac they
    /// walk away from wants the hold without the unlocked screen. The panel's
    /// control says which of the two is in force rather than leaving it to be
    /// discovered.
    ///
    /// Neither assertion survives the lid closing. macOS sleeps a laptop on
    /// clamshell whoever is asserting what, unless it is on power with an
    /// external display attached — which is its own feature and not one Sissy
    /// can grant.
    private static let systemType = kIOPMAssertionTypePreventUserIdleSystemSleep
    private static let displayType = kIOPMAssertionTypePreventUserIdleDisplaySleep
    private static let systemName = "Sissy is keeping this Mac awake"
    private static let displayName = "Sissy is keeping this screen on"

    /// Drives the hold to `holding`, with the screen half included only when
    /// `includingScreen`, and reports what is actually in force.
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
    /// `system` of false has to mean nothing is held, or the panel would report
    /// a Mac free to sleep while a screen assertion quietly kept it up. A
    /// system assertion that could not be taken therefore drops the display one
    /// with it.
    ///
    /// Serialising every change through this actor is also what makes two mode
    /// switches in the same instant safe: they arrive in order and the last one
    /// decides. It is also what lets the screen half be switched under a
    /// running hold — the release below is reached with the system assertion
    /// untouched, so the Mac never blinks awake to change its mind about the
    /// screen.
    func apply(holding: Bool, includingScreen: Bool) -> KeepAwakeHold {
        guard holding else {
            releaseAll()
            return .none
        }
        if system == nil { system = create(Self.systemType, named: Self.systemName) }
        if includingScreen {
            if display == nil { display = create(Self.displayType, named: Self.displayName) }
        } else {
            release(&display, named: Self.displayName)
        }
        if system == nil { releaseAll() }
        return KeepAwakeHold(system: system != nil, screen: display != nil)
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
