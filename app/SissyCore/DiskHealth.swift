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

/// One entry of the kernel's mount table, as `getmntinfo_r_np` answers it
/// without asking the filesystem anything.
struct DiskMount: Sendable, Equatable {
    let path: String
    /// `MNT_LOCAL`: the kernel's word that the filesystem is not remote.
    let isLocal: Bool
    /// `MNT_DONTBROWSE` unset, which is what hides the system's own volumes
    /// from Finder.
    let isBrowsable: Bool
}

/// Which volumes the page lists and what it says about each.
enum DiskVolumes {
    /// Whether a mount is worth asking for resource values at all.
    ///
    /// **Decided from the mount table alone, before any volume is touched.**
    /// A resource value of a network mount is a request to its server, and a
    /// stuck SMB, NFS or WebDAV mount blocks it without a bound; the kernel's
    /// own flags answer locality and visibility with no such request.
    static func isCandidate(_ mount: DiskMount) -> Bool {
        mount.isLocal && mount.isBrowsable
    }

    /// The mount a path lives on, by the longest mount point that holds it
    /// as a whole path component, so `/Users` does not claim `/Users2`.
    ///
    /// Out of the table rather than a `statfs` of the path, which is itself a
    /// request to the path's filesystem and blocks on a stuck network mount
    /// the way a resource value does.
    static func mount(of path: String, in mounts: [DiskMount]) -> DiskMount? {
        mounts
            .filter { holds($0.path, path) }
            .max { $0.path.count < $1.path.count }
    }

    /// Whether the home directory may be asked for resource values: only when
    /// the mount it lives on is local. A home the table does not place, or
    /// places on a network mount, is not read at all, and the Disk tab then
    /// has no headline rather than a read that can hang the monitor.
    static func isHomeReadable(_ homePath: String, in mounts: [DiskMount]) -> Bool {
        mount(of: homePath, in: mounts)?.isLocal ?? false
    }

    private static func holds(_ mountPoint: String, _ path: String) -> Bool {
        if mountPoint == "/" || mountPoint == path { return true }
        return path.hasPrefix(mountPoint.hasSuffix("/") ? mountPoint : mountPoint + "/")
    }

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
    ///
    /// **The home directory goes through the mount table too.** One table is
    /// taken per read, and the home volume is asked for resource values only
    /// when `DiskVolumes.isHomeReadable` places it on a local mount: a network
    /// home directory yields no home reading, so the headline is absent
    /// rather than the serialized read blocked on its server. `mounts` and
    /// `homePath` are injectable so a test can stand in a table that names a
    /// network home without touching one.
    static func read(
        now: Date = Date(), mounts: [DiskMount]? = nil, homePath: String = NSHomeDirectory()
    ) -> DiskReading {
        let table = mounts ?? mountTable()
        let home = DiskVolumes.isHomeReadable(homePath, in: table) ? homeVolume(at: homePath) : nil
        let homeVolume = home.flatMap { DiskVolumes.volume($0.attributes, importantFree: $0.important) }
        let volumes = mountedVolumes(in: table)
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
    private static func homeVolume(
        at path: String
    ) -> (attributes: DiskVolumeAttributes, important: Int64?)? {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard let attributes = attributes(at: url) else { return nil }
        return (attributes, importantFree(at: url))
    }

    /// The local, browsable mounts' attributes, and nothing read of any other.
    ///
    /// `getmntinfo_r_np` with `MNT_NOWAIT` rather than the mounted-volume
    /// listing of `FileManager`, which reads resource values of every mount,
    /// network ones included, before a caller can filter them. The reentrant
    /// form, because the plain call answers into one buffer shared by the whole
    /// process. Measured 2026-09-28 the table costs 4 µs, and on this Mac the
    /// filter keeps the same one volume the listing with hidden volumes
    /// skipped did.
    private static func mountedVolumes(in table: [DiskMount]) -> [DiskVolumeAttributes] {
        table
            .filter(DiskVolumes.isCandidate)
            .compactMap { attributes(at: URL(fileURLWithPath: $0.path, isDirectory: true)) }
    }

    private static func mountTable() -> [DiskMount] {
        var table: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&table, MNT_NOWAIT)
        guard let table else { return [] }
        defer { free(table) }
        guard count > 0 else { return [] }
        return (0..<Int(count)).map { index in
            var entry = table[index]
            let path = withUnsafeBytes(of: &entry.f_mntonname) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            return DiskMount(
                path: path, isLocal: entry.f_flags & UInt32(MNT_LOCAL) != 0,
                isBrowsable: entry.f_flags & UInt32(MNT_DONTBROWSE) == 0)
        }
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
