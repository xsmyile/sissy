import Foundation

// MARK: Mac

extension UsageFormat {
    /// A level as the Mac page and the Overview's line word it, in the
    /// kernel's own three steps, and the panel's dash where the kernel would
    /// not say: an unread pressure is not a normal one.
    static func macLevel(_ level: MacHealthLevel?) -> String {
        switch level {
        case .normal: "normal"
        case .warn: "warn"
        case .critical: "critical"
        case nil: "—"
        }
    }

    /// `Memory normal`, the lead of the Overview's line and the page's
    /// headline.
    static func macMemory(_ pressure: MacHealthLevel?) -> String {
        "Memory " + macLevel(pressure)
    }

    /// `75% free`, the kernel's own share, under the headline.
    static func macFreeMemory(_ percent: Int) -> String {
        "\(percent)% free"
    }

    /// Bytes at the grain a disk and a swap file are read at: terabytes to
    /// one decimal from one up, whole gigabytes from ten, one decimal under
    /// that, whole megabytes under one, whole kilobytes under that, and bytes
    /// under one kilobyte, so `0 B` is none at all and only that.
    ///
    /// Not `bytes`, whose two decimals are for a footprint sitting beside
    /// Activity Monitor's: `77.00 GB free` claims a precision a volume that
    /// moves by the gigabyte as swap grows does not have, and `0 KB swap`
    /// reads as a small amount rather than none. Base ten for `bytes`'s
    /// reason, which is also Finder's. Each step is taken on the figure as it
    /// will be printed, `networkRate`'s rule, so a volume never reads
    /// `1000 GB` and a free space just short of ten never reads `10.0 GB`.
    static func storage(_ bytes: UInt64) -> String {
        UnitStep.format(Double(bytes), storageSteps) ?? "\(bytes) B"
    }

    private static let storageSteps = [
        UnitStep("%.1f TB", per: UnitStep.tera, once: .whole, of: UnitStep.giga),
        UnitStep(
            "%.0f GB", per: UnitStep.giga, once: .oneDecimal, of: UnitStep.giga,
            reaches: storageWholeGigabytes),
        UnitStep("%.1f GB", per: UnitStep.giga, once: .whole, of: UnitStep.mega),
        UnitStep("%.0f MB", per: UnitStep.mega, once: .whole, of: UnitStep.kilo),
        UnitStep("%.0f KB", per: UnitStep.kilo, once: .exact, of: 1),
    ]

    /// `1.2 GB`, the swap in use, and a dash where the kernel would not say.
    static func macSwap(_ swap: MacSwapUsage?) -> String {
        swap.map { storage($0.used) } ?? "—"
    }

    /// `3.0 on 12 cores`: the one-minute average beside what it is out of,
    /// because a load means nothing without the cores it is spread over and
    /// Sissy puts no threshold on it.
    static func macLoad(_ load: MacLoadAverage?, cores: Int) -> String {
        guard let load else { return "—" }
        return String(format: "%.1f", load.one) + " on \(cores) "
            + (cores == 1 ? "core" : "cores")
    }

    /// What the Mac page's header says under its title: when the figures on
    /// it were sampled.
    static func macReading(observedAt: Date, now: Date) -> String {
        "sampled " + age(now.timeIntervalSince(observedAt))
    }

    private static let storageWholeGigabytes: Double = 10
}

// MARK: Disk

extension UsageFormat {
    /// `77 GB free`, the Disk tab's headline and a volume row's figure.
    static func diskFree(_ free: Int64) -> String {
        storage(clampedBytes(free)) + " free"
    }

    /// `of 494 GB · Macintosh HD`, what the headline's free space is out of.
    static func diskVolume(total: Int64, name: String) -> String {
        "of " + storage(clampedBytes(total)) + " · " + name
    }

    /// `812 GB free of 2.0 TB`, one volume's row.
    static func diskVolumeFree(_ volume: DiskVolume) -> String {
        diskFree(volume.free) + " of " + storage(clampedBytes(volume.total))
    }

    /// `warn under 52 GB · critical under 26 GB`, where the bar's two marks
    /// are, in the same base-ten bytes as the free space above it: a legend
    /// in RAM's own gibibytes would read `48 GB` over a volume graded warn at
    /// `51 GB free`.
    static func diskThresholds(physicalMemory: UInt64) -> String {
        "warn under " + storage(physicalMemory * MacHealthLevel.diskWarnMultiple)
            + " · critical under " + storage(physicalMemory * MacHealthLevel.diskCriticalMultiple)
    }

    /// The hover on what macOS can free: what it is, and why the free space
    /// above leaves it out.
    static let diskPurgeableHelp =
        "Snapshots and caches macOS deletes on its own when space runs low. "
        + "Not counted as free: a large write can fail before macOS gets to it."

    /// `9.4 GB`, the purgeable space, and a dash where it could not be read.
    static func diskPurgeable(_ purgeable: Int64?) -> String {
        purgeable.map { storage(clampedBytes($0)) } ?? "—"
    }

    /// `read 12s ago`: the disk is read once a minute, so its age is its own
    /// and not the memory's.
    static func diskReading(observedAt: Date, now: Date) -> String {
        "read " + age(now.timeIntervalSince(observedAt))
    }

    private static func clampedBytes(_ bytes: Int64) -> UInt64 {
        UInt64(max(bytes, 0))
    }
}

// MARK: Disk activity

extension UsageFormat {
    /// `Read 42 MB/s`, what came off the disks, in the grain `networkRate`
    /// keeps every byte rate to.
    static func diskRead(_ bytesPerSecond: Double?) -> String {
        "Read " + (bytesPerSecond.map(networkRate) ?? "—")
    }

    /// `Write 3.1 MB/s`, what went onto them.
    static func diskWrite(_ bytesPerSecond: Double?) -> String {
        "Write " + (bytesPerSecond.map(networkRate) ?? "—")
    }
}

// MARK: Network

extension UsageFormat {
    /// A rate at the grain a person reads one at: whole kilobytes under a
    /// megabyte, one decimal under ten megabytes, whole megabytes to a
    /// gigabyte and one decimal above. Base ten for `bytes`'s reason, which is
    /// also Activity Monitor's for its network figures.
    ///
    /// Each step is taken on the figure as it will be printed, so a rate
    /// never reads `1000 KB/s` or `10.0 MB/s`: that keeps every figure to
    /// three digits and a unit, which is what lets the headline fit without
    /// shrinking, see `PanelNetwork`.
    static func networkRate(_ bytesPerSecond: Double) -> String {
        let value = max(bytesPerSecond, 0)
        return UnitStep.format(value, rateSteps)
            ?? String(format: "%.0f KB/s", (value / UnitStep.kilo).rounded())
    }

    private static let rateSteps = [
        UnitStep("%.1f GB/s", per: UnitStep.giga, once: .whole, of: UnitStep.mega),
        UnitStep(
            "%.0f MB/s", per: UnitStep.mega, once: .oneDecimal, of: UnitStep.mega,
            reaches: rateWholeMegabytes),
        UnitStep("%.1f MB/s", per: UnitStep.mega, once: .whole, of: UnitStep.kilo),
    ]

    /// `↓ 2.4 MB/s`, what came in.
    static func networkDown(_ bytesPerSecond: Double?) -> String {
        "↓ " + (bytesPerSecond.map(networkRate) ?? "—")
    }

    /// `↑ 310 KB/s`, what went out.
    static func networkUp(_ bytesPerSecond: Double?) -> String {
        "↑ " + (bytesPerSecond.map(networkRate) ?? "—")
    }

    /// `Wi-Fi · now` under the headline: which link the rate is read on, and
    /// that it is the current second rather than an average.
    static func networkCaption(_ interface: NetworkInterfaceName?) -> String {
        (interface.map(networkLinkName) ?? "Not connected") + " · now"
    }

    /// `Wi-Fi (en0)`. System Settings already carries the BSD name in some of
    /// its own names, `Ethernet Adapter (en4)`, and a VPN's interface has no
    /// name there at all, so the BSD name is added only where it is missing.
    static func networkInterface(_ interface: NetworkInterfaceName?) -> String {
        guard let interface else { return "—" }
        guard let display = interface.displayName else { return interface.bsdName }
        let tag = "(\(interface.bsdName))"
        return display.contains(tag) ? display : display + " " + tag
    }

    /// `-59 dBm · 286 Mbps`, the signal and the rate the link last sent at.
    static func networkSignal(_ link: WiFiLink) -> String {
        "\(link.rssi) dBm · " + String(format: "%.0f Mbps", link.transmitRate)
    }

    /// `↓ 1.4 GB · ↑ 3.0 GB`, what the physical links carried, and the dash
    /// before the first sample.
    static func networkTotals(_ totals: NetworkTotals?) -> String {
        guard let bytes = totals?.bytes else { return "—" }
        return "↓ " + storage(bytes.received) + " · ↑ " + storage(bytes.sent)
    }

    /// What that figure is over: `Since boot` only while nothing counted has
    /// changed since the Mac booted, and otherwise the latest such change,
    /// `Since 08:43` today and `Since 27 Sept` before it, since a label must
    /// not claim more than the counters hold. See `NetworkTotals`.
    static func networkTotalsLabel(
        _ totals: NetworkTotals?, now: Date = Date(), calendar: Calendar = .current
    ) -> String {
        guard let since = totals?.since else { return "Since boot" }
        let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(since, inSameDayAs: now) {
            return "Since " + since.formatted(style.hour().minute())
        }
        return "Since " + since.formatted(style.day().month(.abbreviated))
    }

    /// The link's own name without its BSD tag, which the caption has no
    /// room to repeat.
    private static func networkLinkName(_ interface: NetworkInterfaceName) -> String {
        interface.displayName ?? interface.bsdName
    }

    private static let rateWholeMegabytes: Double = 10
}
