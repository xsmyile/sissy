import Foundation

/// One mounted volume, in the figures Finder shows for it.
struct DiskVolume: Sendable, Equatable, Identifiable {
    /// The volume's UUID where it has one, which is what tells the home
    /// volume apart from `/` through the firmlink between them, and the mount
    /// path otherwise.
    let id: String
    let name: String
    let total: Int64
    /// What an important write could have, purgeable space included, or the
    /// plain available capacity on a volume that answers no such figure.
    let free: Int64

    var used: Int64 { max(total - free, 0) }
}

/// What a mounted volume answers before anything dear is read about it.
///
/// Apart from Foundation's resource values, whose volume fields cannot be
/// set, so the choice of which volumes the page lists can be asserted
/// without mounting one.
struct DiskVolumeAttributes: Sendable, Equatable {
    let path: String
    let uuid: String?
    let name: String?
    let isLocal: Bool
    let isBrowsable: Bool
    let total: Int?
    let available: Int?

    var id: String { uuid ?? path }
}

/// What the disks on this Mac answer right now.
///
/// **In memory and nowhere else**, on `MacHealthReading`'s terms: a reading
/// from before a relaunch describes a disk that has moved on.
struct DiskReading: Sendable, Equatable {
    /// Sissy's clock at the read, which dates every figure below.
    let observedAt: Date
    /// The volume holding the home directory, nil where it would not answer.
    let home: DiskVolume?
    /// What the system would hand back from the home volume under pressure:
    /// the important-usage figure less the plain available one. Measured
    /// 2026-09-28 on a 494 GB volume, 9.5 GB.
    let purgeable: Int64?
    /// On the disk's reading as well as the Mac's, because swap is the file
    /// that eats the free space the level grades.
    let swap: MacSwapUsage?
    /// What the level is graded against.
    let physicalMemory: UInt64
    /// Every other local, browsable volume, by name. The home volume is left
    /// out because the headline is that volume.
    let volumes: [DiskVolume]

    /// The home volume graded against RAM, nil where it was not read: no
    /// reading is not a reading of normal.
    var level: MacHealthLevel? {
        home.map { MacHealthLevel.disk(free: $0.free, physicalMemory: physicalMemory) }
    }
}

extension FrameData {
    /// The level the menu bar's dot wears: the worse of the kernel's memory
    /// pressure and the disk's grade, each only while its own switch is on.
    /// Nil where neither was read.
    var macLevel: MacHealthLevel? {
        [mac?.pressure, disk?.level].compactMap { $0 }.max()
    }
}

/// Which volumes the page lists and what it says about each.
enum DiskVolumes {
    /// The important-usage figure less the plain available one, and nil
    /// unless both were read: a volume answering only the plain figure has
    /// not said it holds no purgeable space.
    static func purgeable(important: Int64?, available: Int?) -> Int64? {
        guard let important, let available else { return nil }
        return max(important - Int64(available), 0)
    }

    /// A volume the user could open in Finder and that is not on the network,
    /// other than the home volume, which the headline already answers for.
    static func isListed(_ volume: DiskVolumeAttributes, homeID: String?) -> Bool {
        volume.isLocal && volume.isBrowsable && volume.id != homeID
    }

    /// The volume as the page reads it, preferring the important-usage figure
    /// Finder shows to the plain available one.
    static func volume(_ attributes: DiskVolumeAttributes, importantFree: Int64?) -> DiskVolume? {
        guard let total = attributes.total, total > 0,
            let free = importantFree ?? attributes.available.map(Int64.init)
        else { return nil }
        let name = attributes.name ?? (attributes.path as NSString).lastPathComponent
        return DiskVolume(id: attributes.id, name: name, total: Int64(total), free: free)
    }

    /// By name, so two sweeps list the same volumes in the same order
    /// whichever mounted first.
    static func ordered(_ volumes: [DiskVolume]) -> [DiskVolume] {
        volumes.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}

/// Reads the disks, with no permission: every figure is a resource value of
/// a volume the user can already open.
enum DiskReader {
    /// One read of everything the Disk tab shows.
    ///
    /// **The important-usage figure is the dear one.** Measured 2026-09-28,
    /// it costs 6.7 ms of CPU per volume where every other key here together
    /// costs 0.07 ms for the whole mount list, so the list is read with the
    /// cheap keys first and the dear one is asked only of the volumes kept.
    static func read(now: Date = Date()) -> DiskReading {
        let home = homeVolume()
        let homeVolume = home.flatMap { DiskVolumes.volume($0.attributes, importantFree: $0.important) }
        let volumes = mountedVolumes()
            .filter { DiskVolumes.isListed($0, homeID: home?.attributes.id) }
            .compactMap {
                DiskVolumes.volume($0, importantFree: importantFree(at: URL(fileURLWithPath: $0.path)))
            }
        return DiskReading(
            observedAt: now,
            home: homeVolume,
            purgeable: home.flatMap {
                DiskVolumes.purgeable(important: $0.important, available: $0.attributes.available)
            },
            swap: SystemHealthReader.swap(),
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            volumes: DiskVolumes.ordered(volumes))
    }

    private static let cheapKeys: Set<URLResourceKey> = [
        .volumeUUIDStringKey, .volumeLocalizedNameKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
        .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
    ]

    /// A new `URL` on every call, because a `URL` caches the resource values
    /// it has answered and a reused one would report the first reading for
    /// the life of the process.
    private static func homeVolume() -> (attributes: DiskVolumeAttributes, important: Int64?)? {
        let url = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        guard let attributes = attributes(at: url) else { return nil }
        return (attributes, importantFree(at: url))
    }

    private static func mountedVolumes() -> [DiskVolumeAttributes] {
        let urls =
            FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: Array(cheapKeys), options: [.skipHiddenVolumes])
            ?? []
        return urls.compactMap(attributes(at:))
    }

    private static func attributes(at url: URL) -> DiskVolumeAttributes? {
        guard let values = try? url.resourceValues(forKeys: cheapKeys) else { return nil }
        return DiskVolumeAttributes(
            path: url.path, uuid: values.volumeUUIDString, name: values.volumeLocalizedName,
            isLocal: values.volumeIsLocal ?? false, isBrowsable: values.volumeIsBrowsable ?? false,
            total: values.volumeTotalCapacity, available: values.volumeAvailableCapacity)
    }

    private static func importantFree(at url: URL) -> Int64? {
        try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }
}
