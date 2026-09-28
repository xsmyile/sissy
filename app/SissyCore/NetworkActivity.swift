import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

/// Bytes received and sent, as a pair every network figure is carried in.
struct NetworkByteCounts: Sendable, Equatable {
    var received: UInt64
    var sent: UInt64

    static let zero = Self(received: 0, sent: 0)
}

/// One interface's byte counters, as the kernel has kept them since the
/// interface last attached, which is boot for most of them.
struct NetworkInterfaceCounters: Sendable, Equatable {
    /// The BSD name, `en0`.
    let name: String
    let bytes: NetworkByteCounts
    /// `IFF_LOOPBACK`, which the kernel sets whatever the interface is named.
    let isLoopback: Bool
    /// `ifi_lastchange`, the last time the link went up or down, nil where
    /// the kernel left it at zero. See `NetworkTotals` for what it bounds.
    var lastChange: Date?
}

/// What the physical links have carried, and since when the figure can be
/// vouched for.
///
/// **An interface's counters start again when it attaches**, which a USB
/// adapter plugged back in or a Wi-Fi interface reset both do, so a sum of
/// today's counters is not a figure since boot unless nothing counted has
/// attached since. The kernel does not date a reset; it dates the last time
/// the link changed, `ifi_lastchange`, and a reset only happens on a change,
/// so a counter holds everything since its interface's last change at the
/// least. `since` is the latest such change among the interfaces that carried
/// anything, and nil when every one of them last changed while the Mac was
/// booting, which is what lets the row say `Since boot` and nothing more.
///
/// It is a bound and not a reset: a link that went down and up again without
/// detaching, which is what a Wi-Fi interface does on every wake, keeps its
/// counters and still moves the date. Measured 2026-09-28 on a Mac16,8
/// running macOS 27.0, booted at 15:31:51 the day before: every interface that
/// had not moved read 8 to 65 s after boot, and `en0` read 08:43:57, 17.2 h
/// after it, the wake from that night's sleep. So the row names the wake and
/// claims less than the counters may hold, which is the side a label that
/// cannot know is allowed to err on. An interface that detached and has not
/// come back is not listed at all, and nothing can bound what it took with
/// it.
///
/// **What `Since boot` can still overstate**, and by how much: an interface
/// that carried traffic in the first `NetworkRates.bootSettling` seconds and
/// detached and came back inside them restarted its counters, and its date
/// falls in the window the label ignores. An interface that first appeared
/// there loses nothing, because a link carries no traffic before it exists;
/// only a reattach does, and the missing figure is bounded by what the Mac
/// moved while it was still starting up.
struct NetworkTotals: Sendable, Equatable {
    let bytes: NetworkByteCounts
    /// Nil for since boot.
    let since: Date?
}

/// Bytes a second in each direction, over the gap between two samples.
struct NetworkRate: Sendable, Equatable {
    let received: Double
    let sent: Double
}

/// The interface carrying the default route, named the way System Settings
/// names it.
struct NetworkInterfaceName: Sendable, Equatable {
    /// The BSD name, `en0`.
    let bsdName: String
    /// `Wi-Fi`, or nil for an interface System Settings does not list, which
    /// is every virtual one a VPN puts the default route on.
    let displayName: String?
}

/// What CoreWLAN answers for the Wi-Fi link, without the network's name.
struct WiFiLink: Sendable, Equatable {
    /// Received signal strength, in dBm.
    let rssi: Int
    /// The rate the link last transmitted at, in Mbps.
    let transmitRate: Double
}

/// What the Network tab draws, as one sample publishes it.
///
/// **Published only while that tab is on screen, and in memory only.** The
/// series is what the monitor logged over the last `LiveCadence.window`, in
/// the background as well as for the tab, and never across a gap, which
/// would be a guess drawn as a line. The totals are the kernel's own counters
/// and need no history at all, see `NetworkTotals` for since when.
struct NetworkReading: Sendable, Equatable {
    let observedAt: Date
    /// Nil while the Mac has no default route.
    let interface: NetworkInterfaceName?
    /// Nil unless the interface carrying the default route is the Wi-Fi one.
    let wifi: WiFiLink?
    /// Summed across the physical interfaces, see `NetworkInterfaceFilter`.
    let totals: NetworkTotals
    /// Oldest first, dated, and none older than `LiveCadence.window` before
    /// `observedAt`. Empty on the first sample, which has nothing to measure
    /// from.
    let rates: [RatePoint<NetworkRate>]

    var current: NetworkRate? { rates.last?.rate }
}

/// Which interfaces are the Mac's own links and which are the system's
/// plumbing on top of them.
///
/// **By name, the way `netstat` users read them**: the kernel types Wi-Fi and
/// Ethernet alike as `IFT_ETHER`, and a VPN's `utun` counts the same bytes its
/// physical link already carried, so summing it in would count a tunnelled
/// download twice. Measured 2026-09-28 on a Mac16,8 running macOS 27.0, the
/// kernel listed 27 interfaces, of which `en0` carried 3.1 GB and every other
/// with traffic was `lo0`, `awdl0`, `nan0` or a `utun`.
enum NetworkInterfaceFilter {
    /// The name with its unit number taken off: `utun` for `utun4`.
    static let virtualFamilies: Set<String> = [
        "lo", "gif", "stf", "awdl", "llw", "utun", "bridge", "anpi", "ap", "nan", "ipsec", "ppp",
        "vmenet", "feth",
    ]

    static func isPhysical(_ interface: NetworkInterfaceCounters) -> Bool {
        !interface.isLoopback && !virtualFamilies.contains(family(of: interface.name))
    }

    static func family(of name: String) -> String {
        String(name.prefix { !$0.isNumber })
    }
}

/// The arithmetic between two samples of the counters.
enum NetworkRates {
    /// How long after boot an interface may still come up and count as
    /// having been there since boot. Measured 2026-09-28, the last interface
    /// to come up after boot did so 65 s in; five minutes leaves room for a
    /// slow Wi-Fi join without mistaking a later reattach for the boot.
    static let bootSettling: TimeInterval = 300

    /// What the physical interfaces have carried, summed, and the moment
    /// that figure is vouched for since, see `NetworkTotals`. An interface
    /// that has carried nothing adds no bytes and no date. With no boot time
    /// to measure against, no change counts as the boot's.
    static func totals(_ counters: [NetworkInterfaceCounters], bootedAt: Date?) -> NetworkTotals {
        let counted = counters.filter(NetworkInterfaceFilter.isPhysical)
        let bytes = counted.reduce(NetworkByteCounts.zero) {
            NetworkByteCounts(
                received: $0.received &+ $1.bytes.received, sent: $0.sent &+ $1.bytes.sent)
        }
        let settled = bootedAt?.addingTimeInterval(bootSettling) ?? .distantPast
        let since =
            counted
            .filter { $0.bytes != .zero }
            .compactMap(\.lastChange)
            .filter { $0 > settled }
            .max()
        return NetworkTotals(bytes: bytes, since: since)
    }

    /// The physical interfaces' counters by name, which is what the next
    /// sample's rate is measured against.
    static func byName(_ counters: [NetworkInterfaceCounters]) -> [String: NetworkByteCounts] {
        Dictionary(
            counters.filter(NetworkInterfaceFilter.isPhysical).map { ($0.name, $0.bytes) },
            uniquingKeysWith: { _, latest in latest })
    }

    /// Bytes a second between two samples, or nil where no time has passed.
    ///
    /// **Per interface rather than from the totals**, because a total can go
    /// down: an interface that detaches takes its counters with it, and one
    /// that comes back starts again from zero. A counter below its previous
    /// value, and an interface the previous sample did not have, contribute
    /// nothing to this sample rather than an unsigned difference that wraps
    /// to eighteen exabytes.
    static func rate(
        from previous: [String: NetworkByteCounts], to current: [String: NetworkByteCounts],
        seconds: TimeInterval
    ) -> NetworkRate? {
        guard seconds > 0 else { return nil }
        var received: UInt64 = 0
        var sent: UInt64 = 0
        for (name, now) in current {
            guard let before = previous[name] else { continue }
            received &+= delta(from: before.received, to: now.received)
            sent &+= delta(from: before.sent, to: now.sent)
        }
        return NetworkRate(received: Double(received) / seconds, sent: Double(sent) / seconds)
    }

    private static func delta(from before: UInt64, to now: UInt64) -> UInt64 {
        now >= before ? now - before : 0
    }
}

/// Reads the network's figures, none of which needs a permission.
///
/// **What is never read is the network's name.** `CWInterface.ssid()` and
/// `bssid()` need Location, and the user ruled the name out of the tab on
/// 2026-09-28 in any case: the signal and the link rate are what say whether
/// the link is the problem, and neither needs to know which network it is.
enum NetworkReader {
    /// Every interface's counters, from one `NET_RT_IFLIST2` sysctl.
    ///
    /// Not `getifaddrs`, whose `if_data` counters are 32-bit and wrap every
    /// 4 GiB, a figure a download reaches in minutes. Measured 2026-09-28 on
    /// a Mac16,8 running macOS 27.0, the sysctl and the parse cost 0.069 ms
    /// of CPU a read in a release build and 0.095 to 0.15 ms in a Debug one. Both report counters rounded to
    /// 1 KiB on that release, which is below anything a rate is read at.
    static func counters() -> [NetworkInterfaceCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [] }
        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: length, alignment: MemoryLayout<if_msghdr2>.alignment)
        defer { buffer.deallocate() }
        guard sysctl(&mib, u_int(mib.count), buffer.baseAddress, &length, nil, 0) == 0 else {
            return []
        }
        return parse(UnsafeRawBufferPointer(rebasing: buffer[..<min(length, buffer.count)]))
    }

    /// The `RTM_IFINFO2` messages in a `NET_RT_IFLIST2` answer, each an
    /// `if_msghdr2` followed by the `sockaddr_dl` that names it, left out when
    /// that name is not UTF-8, since it could not be matched. Every other
    /// message is an address and is stepped over by its own length; one whose
    /// length would run past the buffer ends the walk rather than reading
    /// beyond it.
    static func parse(_ buffer: UnsafeRawBufferPointer) -> [NetworkInterfaceCounters] {
        var interfaces: [NetworkInterfaceCounters] = []
        var offset = 0
        while offset + messagePrefix <= buffer.count {
            let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            guard length >= messagePrefix, offset + length <= buffer.count else { break }
            let type = buffer.loadUnaligned(fromByteOffset: offset + typeOffset, as: UInt8.self)
            if Int32(type) == RTM_IFINFO2, length >= headerSize + linkNameOffset,
                let interface = interface(in: buffer, at: offset, length: length)
            {
                interfaces.append(interface)
            }
            offset += length
        }
        return interfaces
    }

    private static func interface(
        in buffer: UnsafeRawBufferPointer, at offset: Int, length: Int
    ) -> NetworkInterfaceCounters? {
        let header = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
        let link = offset + headerSize
        let nameLength = Int(
            buffer.loadUnaligned(fromByteOffset: link + linkNameLengthOffset, as: UInt8.self))
        let nameStart = link + linkNameOffset
        guard nameLength > 0, nameStart + nameLength <= offset + length,
            let name = String(bytes: buffer[nameStart..<nameStart + nameLength], encoding: .utf8)
        else { return nil }
        return NetworkInterfaceCounters(
            name: name,
            bytes: NetworkByteCounts(
                received: header.ifm_data.ifi_ibytes, sent: header.ifm_data.ifi_obytes),
            isLoopback: header.ifm_flags & IFF_LOOPBACK != 0,
            lastChange: lastChange(header.ifm_data.ifi_lastchange))
    }

    /// Wall-clock seconds, which is what the field holds on macOS 27.0,
    /// measured 2026-09-28 against `kern.boottime` on the same clock.
    private static func lastChange(_ time: timeval32) -> Date? {
        guard time.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec))
    }

    /// `ifm_msglen`, `ifm_version` and `ifm_type`: enough to step over a
    /// message of any kind.
    private static let messagePrefix = 4
    private static let typeOffset = 3
    private static let headerSize = MemoryLayout<if_msghdr2>.size
    /// Where `sdl_nlen` and `sdl_data` sit in a `sockaddr_dl`.
    private static let linkNameLengthOffset = 5
    private static let linkNameOffset = 8

    /// The BSD name of the interface carrying the IPv4 default route, from
    /// the dynamic store System Settings itself reads.
    ///
    /// A store made per read rather than one held: it is not `Sendable`, and
    /// measured 2026-09-28 a fresh one and the read together cost 0.026 ms of
    /// CPU against 0.009 ms reusing one.
    static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, storeName as CFString, nil, nil),
            let value = SCDynamicStoreCopyValue(store, primaryKey as CFString) as? [String: Any]
        else { return nil }
        return value[kSCDynamicStorePropNetPrimaryInterface as String] as? String
    }

    /// What System Settings calls an interface, `Wi-Fi` for `en0`.
    ///
    /// Measured 2026-09-28, the listing costs 1.6 ms of CPU, which is why the
    /// monitor asks it only when the interface carrying the default route
    /// changes.
    static func displayName(bsdName: String) -> String? {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return nil }
        let match = all.first { SCNetworkInterfaceGetBSDName($0) as String? == bsdName }
        return match.flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? }
    }

    /// The Wi-Fi link's signal and rate, when the Wi-Fi interface is the one
    /// named. An RSSI of zero is CoreWLAN's answer for an interface that is
    /// not associated, which is no reading rather than a perfect one.
    ///
    /// Measured 2026-09-28, the two calls cost 0.085 ms of CPU and 2.8 ms of
    /// wall time, spent waiting on the Wi-Fi daemon: off the main actor that
    /// is a wait and not work.
    static func wifi(bsdName: String) -> WiFiLink? {
        guard let interface = CWWiFiClient.shared().interface(), interface.interfaceName == bsdName
        else { return nil }
        let rssi = interface.rssiValue()
        guard rssi != 0 else { return nil }
        return WiFiLink(rssi: rssi, transmitRate: interface.transmitRate())
    }

    /// When the Mac booted, from `kern.boottime`, on the wall clock
    /// `ifi_lastchange` is read against. Nil where the sysctl would not answer.
    static func bootedAt() -> Date? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))
    }

    private static let storeName = "Sissy"
    private static let primaryKey = "State:/Network/Global/IPv4"
}
