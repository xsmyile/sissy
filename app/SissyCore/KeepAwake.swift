import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import notify

/// What the user asked Sissy to do about sleep.
///
/// Persisted in `server.json` rather than held in memory: a mode is a setting,
/// not a transient hold, and someone who switched their Mac to never sleep
/// expects it to still be that way the next time Sissy launches.
/// `CaseIterable` because three surfaces now offer the choice — the panel's
/// button, the right-click menu and Settings — and a mode listed by hand in
/// each of them is a mode that reaches two and misses the third. Declaration
/// order is the order they read in: least holding first.
enum KeepAwakeMode: String, Sendable, Codable, CaseIterable {
    case off
    /// Held only while agents are demonstrably working. The signal is Sissy's
    /// own: a day total that grew is a turn that landed, which is the thing no
    /// generic `caffeinate` can know.
    case auto
    case on
}

/// How long `on` holds before switching itself off, as the user chose it.
///
/// `auto` has no ceiling on purpose: its idle window already bounds it, and
/// cutting a hold out from under agents that are demonstrably still working
/// is the exact failure the automatic mode exists to prevent. A manual hold
/// has no such evidence behind it, which is why it has one by default.
///
/// A choice rather than a constant, decided 2026-10-03: a fixed eight hours
/// was a limit nobody had set, and a hold that let go in the middle of a
/// night's run was the surprise it caused. `never` is in the list for the
/// same reason `caffeinate` without `-t` exists, and it costs nothing the
/// other rules depend on: the hold still dies with Sissy, and the lit eye and
/// the menu's running count still say it is there. Eight hours stays the
/// default, so a `server.json` written before the choice existed holds the
/// way it always did.
enum KeepAwakeCeiling: String, Sendable, Codable, CaseIterable {
    case oneHour = "1h"
    case twoHours = "2h"
    case fourHours = "4h"
    case eightHours = "8h"
    case twelveHours = "12h"
    case never

    /// How many hours the hold lasts, and `nil` for the one ceiling that
    /// sets no deadline.
    var hours: Int? {
        switch self {
        case .oneHour: return 1
        case .twoHours: return 2
        case .fourHours: return 4
        case .eightHours: return 8
        case .twelveHours: return 12
        case .never: return nil
        }
    }
}

/// How long each mode's hold survives without help.
///
/// Values rather than constants so a test can run a whole idle window, or a
/// whole ceiling, inside a test run; `default` is what ships.
struct KeepAwakePolicy: Sendable, Equatable {
    /// Silence that ends an automatic hold.
    ///
    /// Comfortably wider than the tail's own coalescing
    /// (`UsageReaderShared.pollEmitThrottle`) because the two measure different
    /// things: that throttle is how finely arrivals are reported, this is how
    /// long a gap between turns is allowed to be. Turns are minutes apart —
    /// a model thinking, a build running, a diff being read — and a window
    /// near the throttle would let go in the middle of an exchange.
    let idleWindow: TimeInterval

    /// How long one hour of a `KeepAwakeCeiling` lasts.
    let ceilingHour: TimeInterval

    static let `default` = Self(idleWindow: 10 * 60, ceilingHour: 60 * 60)
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
    /// Whether closing the lid leaves the Mac working, for the same reason and
    /// on the same terms as `coversScreen`: `keepAwakeWithLidClosed` is the
    /// setting, and this is whether the kernel took the switch.
    let coversLid: Bool
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
    /// and a screen or a lid held behind a Mac that is not is the state
    /// `apply` refuses to leave behind.
    init(
        mode: KeepAwakeMode, active: Bool, since: Date? = nil, coversScreen: Bool = false,
        coversLid: Bool = false
    ) {
        self.mode = mode
        self.active = active
        self.since = active ? since : nil
        self.coversScreen = active && coversScreen
        self.coversLid = active && coversLid
    }

    static let off = Self(mode: .off, active: false)
}

/// What the hold actually got, which is not always what was asked for.
///
/// One flag per half because they fail apart: power management can refuse
/// the display half and grant the system half, leaving a Mac that stays up
/// behind a screen that dims, and the kernel can refuse the lid while both
/// assertions take.
///
/// `lid` is whether the clamshell switch is still set by this process, which
/// can outlast the rest: a release the kernel refused leaves it set with
/// nothing else held, and the engine keeps its record of the switch for as
/// long as this says so.
struct KeepAwakeHold: Sendable, Equatable {
    let system: Bool
    let screen: Bool
    let lid: Bool

    init(system: Bool, screen: Bool, lid: Bool = false) {
        self.system = system
        self.screen = screen
        self.lid = lid
    }

    static let none = Self(system: false, screen: false)
}

/// The switch that keeps a closed lid from sleeping the Mac: the root domain's
/// `kPMSetClamshellSleepState`, the same one Amphetamine's closed-display mode
/// sets.
///
/// No public assertion does this. The idle-sleep assertion `KeepAwake` takes
/// is documented to let the lid sleep the Mac, the system-sleep one is "not
/// supported in any OS X releases", and the assertion property that would
/// apply on lid close is refused by powerd to any caller without a private
/// Apple entitlement. This switch needs neither root nor an entitlement: read
/// in xnu's root domain user client and in powerd's assertion code on
/// 2026-10-03, and the call answered success to an ordinary user on macOS
/// 27.0.1 the same day.
///
/// Three properties follow from where it lives, and the rest of the lid
/// design answers for each of them:
///
/// - **It is kernel state, not the process's.** Closing the connection does
///   not clear it, so a crash or a `kill -9` leaves the Mac ignoring its lid
///   until something clears it or the Mac restarts. `UsageEngine` records the
///   switch in `server.json` before setting it, and the next launch clears
///   what that record says was left.
/// - **It is one bit shared with powerd**, which writes it on its own
///   transitions, an external display coming or going above all. A switch
///   powerd cleared under a running hold is set again by `KeepAwake`, on
///   every change of power source and on a backstop interval.
/// - **It is one bit for every caller.** Clearing it clears it for another
///   app that set it too, which is why Sissy clears it only when it set it.
///
/// A value rather than a function so a test can hold a closed lid without
/// touching the machine's.
struct ClamshellSleepSwitch: Sendable {
    /// Sets the switch when `disabled` is true and clears it otherwise, and
    /// answers whether the kernel took the call.
    let set: @Sendable (_ disabled: Bool) -> Bool

    static let rootDomain = Self { disabled in
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else {
            sissyLog("sissy: no IOPMrootDomain to set the clamshell switch on")
            return false
        }
        defer { IOObjectRelease(service) }
        var connection = io_connect_t(IO_OBJECT_NULL)
        let opened = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard opened == kIOReturnSuccess else {
            sissyLog("sissy: opening IOPMrootDomain returned IOReturn \(opened)")
            return false
        }
        defer { IOServiceClose(connection) }
        var input: UInt64 = disabled ? 1 : 0
        let status = IOConnectCallScalarMethod(
            connection, UInt32(kPMSetClamshellSleepState), &input, 1, nil, nil)
        guard status == kIOReturnSuccess else {
            sissyLog(
                "sissy: the clamshell switch refused \(disabled ? "set" : "clear") "
                    + "(IOReturn \(status))")
            return false
        }
        return true
    }

    /// Whether this Mac has a lid at all, which the root domain answers by
    /// publishing its state. A desktop has none, and a switch for a lid it
    /// does not have is a row Settings does not draw.
    static var machineHasLid: Bool {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(
            service, kAppleClamshellStateKey as CFString, kCFAllocatorDefault, 0) != nil
    }
}

/// Owns the power assertions that stop the Mac, and optionally its screen,
/// idling off, and the clamshell switch that stops its lid sleeping it.
///
/// The assertions die with the process, deliberately: a Mac held awake by
/// something with no icon in the menu bar is a battery complaint with no path
/// back to its cause. The *mode* survives in `server.json`, so the next launch
/// resumes the hold the user asked for. The clamshell switch is the one part
/// that does not die with it, for the reasons `ClamshellSleepSwitch` gives.
actor KeepAwake {
    private var system: IOPMAssertionID?
    private var display: IOPMAssertionID?
    /// Whether this process set the clamshell switch and has not cleared it.
    private var lid = false
    private let clamshell: ClamshellSleepSwitch
    /// How often a held lid is set again with nothing prompting it, which is
    /// the backstop for a powerd write no notification announced.
    private let lidReassertInterval: TimeInterval
    /// Sets the switch again on the backstop interval while the lid is held.
    private var lidKeeper: Task<Void, Never>?
    /// The power-source registration that sets the switch again when the
    /// source changes, held only while the lid is.
    private var powerSourceToken: Int32?

    /// How long after a change of power source the switch is set a second
    /// time. powerd re-evaluates the lid on the same notification this
    /// answers, and which of the two runs first is not Sissy's to choose, so
    /// the second write lands after powerd's has.
    private static let powerSourceSettle: Duration = .seconds(2)

    init(clamshell: ClamshellSleepSwitch = .rootDomain, lidReassertInterval: TimeInterval = 60) {
        self.clamshell = clamshell
        self.lidReassertInterval = lidReassertInterval
    }

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
    /// external display attached, which is its own feature. The lid half is
    /// what covers the rest, and it rides on the system half the way the
    /// screen does: a closed lid kept working by a Mac that is free to idle
    /// to sleep would be a switch that promised a run and kept nothing.
    private static let systemType = kIOPMAssertionTypePreventUserIdleSystemSleep
    private static let displayType = kIOPMAssertionTypePreventUserIdleDisplaySleep
    private static let systemName = "Sissy is keeping this Mac awake"
    private static let displayName = "Sissy is keeping this screen on"

    /// Drives the hold to `holding`, with the screen half included only when
    /// `includingScreen` and the lid half only when `includingLid`, and
    /// reports what is actually in force.
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
    /// system assertion that could not be taken therefore drops the display
    /// one and the lid with it.
    ///
    /// Serialising every change through this actor is also what makes two mode
    /// switches in the same instant safe: they arrive in order and the last one
    /// decides. It is also what lets the screen and the lid be switched under
    /// a running hold — the releases below are reached with the system
    /// assertion untouched, so the Mac never blinks awake to change its mind.
    ///
    /// A lid already held is set again rather than skipped, so every call that
    /// keeps it is also a repair of a switch powerd may have cleared.
    func apply(holding: Bool, includingScreen: Bool, includingLid: Bool = false) -> KeepAwakeHold {
        guard holding else {
            releaseAll()
            return KeepAwakeHold(system: false, screen: false, lid: lid)
        }
        if system == nil { system = create(Self.systemType, named: Self.systemName) }
        if includingScreen {
            if display == nil { display = create(Self.displayType, named: Self.displayName) }
        } else {
            release(&display, named: Self.displayName)
        }
        if includingLid, system != nil {
            takeLid()
        } else {
            releaseLid()
        }
        if system == nil { releaseAll() }
        return KeepAwakeHold(system: system != nil, screen: display != nil, lid: lid)
    }

    /// Takes over a switch a previous run set and never cleared, which the
    /// engine knows from its own record and the kernel cannot be asked.
    ///
    /// Nothing is written here: the next `apply` either keeps the lid, which
    /// sets the switch again, or releases it, which clears it. Adopting it
    /// rather than clearing it at once is what keeps a relaunch under a hold
    /// that still wants the lid from clearing a switch it is about to set.
    func adoptStrandedLid() {
        lid = true
    }

    private func releaseAll() {
        releaseLid()
        release(&display, named: Self.displayName)
        release(&system, named: Self.systemName)
    }

    private func takeLid() {
        guard clamshell.set(true) else { return }
        guard !lid else { return }
        lid = true
        keepLid()
    }

    /// A clear the kernel refused leaves `lid` set, so the engine keeps its
    /// record and the next `apply`, or the next launch, goes back for it.
    private func releaseLid() {
        guard lid else { return }
        stopKeepingLid()
        if clamshell.set(false) { lid = false }
    }

    private func reassertLid() {
        guard lid else { return }
        _ = clamshell.set(true)
    }

    private func powerSourceChanged() async {
        reassertLid()
        try? await Task.sleep(for: Self.powerSourceSettle)
        reassertLid()
    }

    private func keepLid() {
        let interval = lidReassertInterval
        lidKeeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self?.reassertLid()
            }
        }
        var token: Int32 = 0
        let handler: notify_handler_t = { [weak self] _ in
            Task { await self?.powerSourceChanged() }
        }
        let status = notify_register_dispatch(
            kIOPSNotifyPowerSource, &token, .global(qos: .utility), handler)
        if status == NOTIFY_STATUS_OK {
            powerSourceToken = token
        } else {
            sissyLog("sissy: no power-source notification (\(status)); the lid relies on the backstop")
        }
    }

    private func stopKeepingLid() {
        lidKeeper?.cancel()
        lidKeeper = nil
        if let token = powerSourceToken { notify_cancel(token) }
        powerSourceToken = nil
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
