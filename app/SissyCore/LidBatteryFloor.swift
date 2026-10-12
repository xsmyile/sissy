import Foundation
import IOKit.ps
import notify

/// The charge below which a lid hold on battery lets the lid go, so a closed
/// Mac sleeps before it runs flat.
///
/// Decided 2026-10-12 as a guard: a Mac on battery that nothing lets sleep
/// runs until macOS's own Low Power Sleep, which took one at 1% on 2026-10-10
/// 05:54. That night it was stuck xcodebuild assertions holding it rather
/// than the lid, which is why this is a guard and not a fix. Only the lid half
/// lets go: on a closed Mac that is the half keeping it running, so
/// the kernel sleeps it the moment the switch clears, and on an open one
/// nothing changes until it is closed. The hold, the screen and the mode stay
/// where the user put them, and the lid comes back once the Mac is on power
/// again. `never` is in the list for the reason `KeepAwakeCeiling.never` is:
/// macOS still sleeps a battery that is nearly empty.
enum LidBatteryFloor: Int, Sendable, Codable, CaseIterable {
    case never = 0
    case tenPercent = 10
    case fifteenPercent = 15
    case twentyPercent = 20
    case thirtyPercent = 30

    /// The percentage the floor sits at, and `nil` for the one that sets none.
    var percent: Int? { self == .never ? nil : rawValue }

    /// Whether `reading` has gone below this floor. Only a Mac drawing from its
    /// battery can: one on power, or one whose battery could not be read, is
    /// never below it, because releasing the lid on no evidence would be a
    /// switch that quietly stopped working.
    func isReached(by reading: PowerSourceReading?) -> Bool {
        guard let floor = percent, let reading, reading.onBattery,
            let charge = reading.batteryPercent
        else { return false }
        return charge < floor
    }
}

/// Where the Mac's power comes from right now, and how full its battery is.
struct PowerSourceReading: Sendable, Equatable {
    let onBattery: Bool
    /// The internal battery's charge in percent, and `nil` on a Mac with none.
    let batteryPercent: Int?
}

/// Reads the power source. A value rather than a function so a test can run a
/// lid hold on a battery that is not the machine's.
struct PowerSourceGauge: Sendable {
    let read: @Sendable () -> PowerSourceReading?

    /// IOKit's power-source snapshot, which answers an ordinary process with no
    /// entitlement and no prompt: it is what the menu bar's battery reads.
    static let ioKit = Self {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let sources = (IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]) ?? []
        let battery = sources.lazy
            .compactMap {
                IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
            }
            .first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
        var percent: Int?
        if let current = battery?[kIOPSCurrentCapacityKey] as? Int,
            let maximum = battery?[kIOPSMaxCapacityKey] as? Int, maximum > 0
        {
            percent = current * 100 / maximum
        }
        return PowerSourceReading(
            onBattery: providing == kIOPSBatteryPowerValue, batteryPercent: percent)
    }
}

/// Calls `onChange` whenever any attribute of any power source changes, the
/// battery's charge and the source it is drawing from included, until it is
/// dropped.
///
/// `kIOPSNotifyAnyPowerSource` rather than the quieter source and
/// time-remaining keys, because neither of those is documented to fire on a
/// change of charge, which is the one this exists to see. Measured 2026-10-12
/// on AC power over three minutes: this key fired every 60 s and the other two
/// not once. Its cost is one read of the snapshot a minute, paid only while a
/// lid hold with a floor is wanted, which is the only time anything listens.
final class PowerSourceWatch: Sendable {
    private let token: Int32?

    init(onChange: @escaping @Sendable () -> Void) {
        var token: Int32 = 0
        let status = notify_register_dispatch(
            kIOPSNotifyAnyPowerSource, &token, .global(qos: .utility)
        ) { _ in onChange() }
        if status == NOTIFY_STATUS_OK {
            self.token = token
        } else {
            sissyLog(
                "sissy: no power-source notification (\(status)); "
                    + "the battery floor is read only when the hold changes")
            self.token = nil
        }
    }

    deinit {
        if let token { notify_cancel(token) }
    }
}
