import Foundation
import IOKit

/// Bytes read from and written to a disk, as a pair every activity figure is
/// carried in.
struct DiskByteCounts: Sendable, Equatable {
    var read: UInt64
    var written: UInt64

    static let zero = Self(read: 0, written: 0)
}

/// One storage driver's byte counters, as the kernel has kept them since the
/// driver attached.
struct DiskDriverCounters: Sendable, Equatable {
    /// The driver's registry entry ID, which names it for as long as it stays
    /// attached and is never handed to another one while the Mac is up.
    let id: UInt64
    let bytes: DiskByteCounts
}

/// A driver as the registry answers it: its counters, and what its provider
/// says it is connected through, see `DiskActivityReader`.
struct DiskDriver: Sendable, Equatable {
    let counters: DiskDriverCounters
    /// The provider's `Physical Interconnect`, nil where it has none.
    let interconnect: String?
}

/// Bytes a second in each direction, over the gap between two samples.
struct DiskRate: Sendable, Equatable {
    let read: Double
    let written: Double
}

/// What the Disk tab's activity platter draws, as one sample publishes it.
///
/// **Only while that tab is on screen, and in memory only**, for the reason
/// `NetworkReading` gives: a rate needs two readings and none were taken while
/// nobody was looking, so a gap would be a guess drawn as a line.
struct DiskActivityReading: Sendable, Equatable {
    let observedAt: Date
    /// Oldest first, one a sample and at most `DiskActivityMonitor.historyLength`
    /// of them. Empty on the first sample, which has nothing to measure from.
    let rates: [DiskRate]

    var current: DiskRate? { rates.last }
}

/// The arithmetic between two samples of the counters.
enum DiskRates {
    /// The counters by driver, which is what the next sample's rate is
    /// measured against.
    static func byID(_ counters: [DiskDriverCounters]) -> [UInt64: DiskByteCounts] {
        Dictionary(counters.map { ($0.id, $0.bytes) }, uniquingKeysWith: { _, latest in latest })
    }

    /// Bytes a second between two samples, or nil where nothing can be
    /// measured: no time has passed, or no driver is in both samples.
    ///
    /// **Per driver rather than from the sum**, because a sum can go down: an
    /// external disk that is unplugged takes its counters with it, and a
    /// driver that attaches brings a counter with a history nobody sampled. A
    /// driver the previous sample did not have, and a counter below its
    /// previous value, contribute nothing to this sample rather than an
    /// unsigned difference that wraps to eighteen exabytes, and a sample with
    /// no driver in common answers nil rather than a rate of zero, since
    /// zero is a measurement.
    static func rate(
        from previous: [UInt64: DiskByteCounts], to current: [UInt64: DiskByteCounts],
        seconds: TimeInterval
    ) -> DiskRate? {
        guard seconds > 0 else { return nil }
        var read: UInt64 = 0
        var written: UInt64 = 0
        var shared = 0
        for (id, now) in current {
            guard let before = previous[id] else { continue }
            shared += 1
            read &+= delta(from: before.read, to: now.read)
            written &+= delta(from: before.written, to: now.written)
        }
        guard shared > 0 else { return nil }
        return DiskRate(read: Double(read) / seconds, written: Double(written) / seconds)
    }

    private static func delta(from before: UInt64, to now: UInt64) -> UInt64 {
        now >= before ? now - before : 0
    }
}

/// Reads the storage drivers' byte counters, which needs no permission.
///
/// Each `IOBlockStorageDriver` in the registry carries a `Statistics`
/// dictionary with `Bytes (Read)` and `Bytes (Write)`, 64-bit and counted
/// since the driver attached. Measured 2026-09-28 on a Mac16,8 running macOS
/// 27.0, one read of every driver costs 0.046 ms of CPU.
///
/// **Only drivers backed by physical media are summed.** A disk image is its
/// own `IOBlockStorageDriver`, and a read it serves is read again from the
/// disk holding its file, so summing every driver counted such a byte twice.
/// What tells them apart is the driver's provider, the `IOBlockStorageDevice`
/// under it, whose `Protocol Characteristics` name a `Physical Interconnect`.
/// Measured 2026-09-28 on a Mac16,8 running macOS 27.0, the registry held five
/// drivers: the internal disk (`IOEmbeddedNVMeBlockDevice`, `Apple Fabric`),
/// the empty SD card reader (`AppleSDXCBlockStorageDevice`, `Secure Digital`,
/// no bytes moved), and three disk images, `AppleDiskImageDevice` and two
/// `IODiskImageBlockStorageDeviceInKernel`, all `Virtual Interface`; the
/// busiest image had read 139 GB since boot against the disk's 1.7 TB. A
/// driver whose provider says nothing is kept, since an answer that is
/// missing is not an image.
enum DiskActivityReader {
    static let driverClass = "IOBlockStorageDriver"
    static let statisticsKey = "Statistics"
    static let readKey = "Bytes (Read)"
    static let writeKey = "Bytes (Write)"

    static let interconnectKey = "Protocol Characteristics"
    static let interconnectName = "Physical Interconnect"
    static let virtualInterconnect = "Virtual Interface"

    /// The counters of every driver on physical media, or none where the
    /// registry would not answer.
    static func counters() -> [DiskDriverCounters] {
        physical(drivers())
    }

    /// Drops the drivers whose provider is a disk image, see the type's note.
    static func physical(_ drivers: [DiskDriver]) -> [DiskDriverCounters] {
        drivers.filter { $0.interconnect != virtualInterconnect }.map(\.counters)
    }

    private static func drivers() -> [DiskDriver] {
        var iterator = io_iterator_t()
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching(driverClass), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var drivers: [DiskDriver] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if let driver = driver(entry) { drivers.append(driver) }
        }
        return drivers
    }

    private static func driver(_ entry: io_registry_entry_t) -> DiskDriver? {
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS,
            let statistics = IORegistryEntryCreateCFProperty(
                entry, statisticsKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                as? [String: Any],
            let bytes = parse(statistics: statistics)
        else { return nil }
        return DiskDriver(
            counters: DiskDriverCounters(id: id, bytes: bytes), interconnect: interconnect(of: entry))
    }

    /// The `Physical Interconnect` of the driver's provider, nil where the
    /// driver has none or the registry does not say.
    private static func interconnect(of driver: io_registry_entry_t) -> String? {
        var provider = io_registry_entry_t()
        guard IORegistryEntryGetParentEntry(driver, kIOServicePlane, &provider) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(provider) }
        let characteristics =
            IORegistryEntryCreateCFProperty(
                provider, interconnectKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            as? [String: Any]
        return characteristics?[interconnectName] as? String
    }

    /// The two counters out of a `Statistics` dictionary, nil unless both are
    /// numbers: a driver that answers one has not told us what it did.
    static func parse(statistics: [String: Any]) -> DiskByteCounts? {
        guard let read = (statistics[readKey] as? NSNumber)?.uint64Value,
            let written = (statistics[writeKey] as? NSNumber)?.uint64Value
        else { return nil }
        return DiskByteCounts(read: read, written: written)
    }
}
