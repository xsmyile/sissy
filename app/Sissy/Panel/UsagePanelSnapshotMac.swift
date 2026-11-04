import Foundation

extension UsagePanelSnapshot {
    /// One reading with the level that colours it, nil where the reading
    /// carries no level of its own.
    struct MacFigure: Equatable {
        let text: String
        let level: MacHealthLevel?
    }

    /// The Mac's reading, worded for the Overview's line and the page behind
    /// it.
    ///
    /// Only the memory carries a level, the kernel's; the disk's is on the
    /// Disk tab. Swap, load and uptime are words with no colour, on the rule
    /// `MacHealthReading` already holds to, because neither has a threshold
    /// that is not a guess.
    struct MacBlock: Equatable {
        let observedAt: Date
        /// `Memory normal`, or the dash where the kernel would not say.
        let memory: MacFigure
        /// The kernel's own step, which the page's track is filled up to.
        let pressure: MacHealthLevel?
        let freeMemory: String?
        /// `1.2 GB`, the swap in use.
        let swap: String
        let load: String
        let uptime: String
        /// Empty until the agent sweep has measured them once, and the page
        /// then leaves the section out rather than heading an empty list.
        let heaviest: [MacApp]
    }

    /// The disks' reading, worded for the Disk tab.
    ///
    /// One level, the home volume's against RAM, and it colours the headline
    /// and the bar. The other volumes carry no level: what fills them is not
    /// swap, so a multiple of RAM says nothing about them.
    struct DiskBlock: Equatable {
        let observedAt: Date
        /// `77 GB free` in the level's colour, or the dash where the home
        /// volume would not answer.
        let free: MacFigure
        /// `of 494 GB · Macintosh HD`, nil with the home volume unread.
        let volume: String?
        /// The home volume's used share, which the bar fills to.
        let used: Double
        /// Where warn and critical begin along the bar, as used shares.
        let warnMark: Double?
        let criticalMark: Double?
        /// `warn under 52 GB · critical under 26 GB`.
        let thresholds: String
        /// `9.4 GB`. Swap stays on the Mac tab, which samples it with the
        /// memory, so the panel never shows two swap figures read a minute
        /// apart.
        let purgeable: String
        /// Empty with no volume but the home one, and the page then leaves
        /// the section out rather than heading an empty list.
        let volumes: [DiskVolumeRow]
    }

    /// One volume besides the home one.
    struct DiskVolumeRow: Equatable, Identifiable {
        let id: String
        let name: String
        /// `812 GB free of 2.0 TB`.
        let free: String
        let used: Double
    }

    /// One of the heaviest apps, keyed by the path its processes were grouped
    /// by.
    struct MacApp: Equatable, Identifiable {
        let id: String
        let name: String
        let footprint: String
    }

    static func makeMac(_ reading: MacHealthReading) -> MacBlock {
        MacBlock(
            observedAt: reading.observedAt,
            memory: MacFigure(text: UsageFormat.macMemory(reading.pressure), level: reading.pressure),
            pressure: reading.pressure,
            freeMemory: reading.freeMemoryPercent.map(UsageFormat.macFreeMemory),
            swap: UsageFormat.macSwap(reading.swap),
            load: UsageFormat.macLoad(reading.loadAverage, cores: reading.activeCores),
            uptime: UsageFormat.uptime(reading.uptime),
            heaviest: (reading.heaviest?.apps ?? []).map {
                MacApp(id: $0.path, name: $0.name, footprint: UsageFormat.bytes($0.footprint))
            }
        )
    }

    static func makeDisk(_ reading: DiskReading) -> DiskBlock {
        let home = reading.home
        let memory = reading.physicalMemory
        return DiskBlock(
            observedAt: reading.observedAt,
            free: MacFigure(
                text: home.map { UsageFormat.diskFree($0.free) } ?? UsageFormat.macLevel(nil),
                level: reading.level),
            volume: home.map { UsageFormat.diskVolume(total: $0.total, name: $0.name) },
            used: home.map(usedShare) ?? 0,
            warnMark: home.map { mark(freeUnder: memory * MacHealthLevel.diskWarnMultiple, on: $0) },
            criticalMark: home.map {
                mark(freeUnder: memory * MacHealthLevel.diskCriticalMultiple, on: $0)
            },
            thresholds: UsageFormat.diskThresholds(physicalMemory: memory),
            purgeable: UsageFormat.diskPurgeable(reading.purgeable),
            volumes: reading.volumes.map {
                DiskVolumeRow(
                    id: $0.id, name: $0.name, free: UsageFormat.diskVolumeFree($0),
                    used: usedShare($0))
            }
        )
    }

    private static func usedShare(_ volume: DiskVolume) -> Double {
        guard volume.total > 0 else { return 0 }
        return min(max(Double(volume.used) / Double(volume.total), 0), 1)
    }

    /// The used share at which the free space drops under `threshold`, so a
    /// fill that has passed the mark is a volume graded at that step.
    private static func mark(freeUnder threshold: UInt64, on volume: DiskVolume) -> Double {
        guard volume.total > 0 else { return 0 }
        let share = 1 - Double(threshold) / Double(volume.total)
        return min(max(share, 0), 1)
    }
}
