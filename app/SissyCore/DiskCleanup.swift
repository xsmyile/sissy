import Darwin
import Foundation
import Synchronization

/// A regenerable cache the Disk tab offers to empty, at a fixed place in the
/// current user's home.
///
/// **A fixed list rather than a search**, because the list is the whole of
/// what a cleanup may touch: a press on a row can only ever reach the one
/// directory the case names, and a cache a tool keeps somewhere else is not
/// on the page rather than being found. Each was verified on the Mac this was
/// built on, measured 2026-09-28: DerivedData 9.2 GB in 156,979 files, the
/// npm cache 2.6 GB in 10,009, the uv cache 6.0 GB in 217,271, and
/// `iOS DeviceSupport` present and empty, which is why a row is drawn only for
/// a cache that takes room. None of them is behind a privacy permission, so
/// reading and removing them asks for nothing.
///
/// **Only the default location, and no environment variable**: `UV_CACHE_DIR`
/// and `npm_config_cache` are read by a shell, and an app launched from the
/// Dock or at login inherits no shell environment, and recovering one would
/// mean running the user's startup files, which is also why
/// `CLAUDE_CONFIG_DIR` is not followed.
/// `~/Library/Developer/CoreSimulator/Caches` is left out because what it held
/// on that Mac, a Personalization folder, is not a cache anything documents as
/// regenerable.
///
/// **`removedProjects` is DerivedData again, narrowed to the builds nothing can
/// use.** Xcode files each project's build products in a folder of its own and
/// records the project's path in that folder's `info.plist`, and nothing
/// removes the folder when the project goes. Measured 2026-09-29 on a Mac
/// working in throwaway worktrees, 28 of DerivedData's 30 folders, 9.1 GB of
/// its 9.5, named a project that no longer existed. Emptying the whole root
/// frees the same space and costs every live project a full rebuild, so this
/// row takes only the folders whose project is gone, and is refused only
/// while the Xcode app runs. See `DiskCleaner.isRemovedProject`.
enum CleanupTarget: String, CaseIterable, Sendable, Identifiable {
    case derivedData
    case removedProjects
    case npm
    case uv
    case deviceSupport

    var id: Self { self }

    var name: String {
        switch self {
        case .derivedData: "Xcode DerivedData"
        case .removedProjects: "Builds of removed projects"
        case .npm: "npm cache"
        case .uv: "uv cache"
        case .deviceSupport: "iOS device support"
        }
    }

    /// The directory under the home, a component at a time, because that is
    /// how it is opened.
    var components: [String] {
        switch self {
        case .derivedData, .removedProjects: ["Library", "Developer", "Xcode", "DerivedData"]
        case .npm: [".npm", "_cacache"]
        case .uv: [".cache", "uv"]
        case .deviceSupport: ["Library", "Developer", "Xcode", "iOS DeviceSupport"]
        }
    }

    /// The directory as a person reads it, relative to their home.
    var displayPath: String { "~/" + components.joined(separator: "/") }
}

/// What emptying one directory did, entry by entry.
///
/// A removal is reported rather than trusted: an entry this user does not own
/// is left where it is and counted, and one the filesystem refused is counted
/// too, so a page can say a cleanup was partial instead of claiming it freed
/// what it did not.
struct CleanupReport: Sendable, Equatable {
    var removed = 0
    /// The allocated blocks of the files whose last link was removed, which
    /// is what the removal handed back at most: a file still linked elsewhere
    /// frees nothing, and one sharing clone blocks frees less.
    var removedBytes: Int64 = 0
    /// Entries left alone because another user owns them or because they sit
    /// on another volume.
    var skipped = 0
    /// Entries the filesystem refused to list, open or remove, and
    /// directories left alone because they were no longer where the walk
    /// found them.
    var failed = 0
    /// Whether the removal stopped because its task was cancelled.
    var cancelled = false

    var isComplete: Bool { skipped == 0 && failed == 0 && !cancelled }
}

/// Why a cleanup touched nothing at all.
enum CleanupRefusal: Error, Equatable, Sendable {
    /// The root could not be opened as the directory it names, on the home's
    /// own volume, owned by this user.
    case unsafeRoot
    /// Another walk over the same root was still running.
    case walkInProgress
    /// The tool that writes the cache was at work on it.
    case toolRunning(CleanupTool)
}

/// A stop signal a filesystem walk on a dispatch thread polls between entries.
final class CleanupCancellation: Sendable {
    private let flag = Atomic<Bool>(false)

    func cancel() { flag.store(true, ordering: .relaxed) }
    var isCancelled: Bool { flag.load(ordering: .relaxed) }
}

/// Sizes and empties the `CleanupTarget` directories, and nothing else.
///
/// **Nothing is ever reached through a symlink.** The root is opened from the
/// home one component at a time with `O_NOFOLLOW`, and its real path, asked of
/// the open descriptor with `F_GETPATH`, must be the home's own real path with
/// those components after it; a root that resolves anywhere else is refused
/// whole. Below the root every entry is examined with `fstatat` and removed
/// with `unlinkat` relative to its parent's descriptor, and a directory is
/// entered only through `openat` with `O_NOFOLLOW` and only when the
/// descriptor names the very inode that was examined. So a symlink inside a
/// root is removed as a link, and whatever it points at is never read. A root
/// that is refused, a symlinked `~/.cache` among them, is sized at 0 and so
/// has no row: the cleanup fails closed rather than follow a link it cannot
/// vouch for.
///
/// **A directory is emptied only while it is still inside the root.** A
/// process of this user can rename a directory out of the root while the walk
/// holds its descriptor, and every removal after that would land wherever it
/// went. So before a directory's entries are listed its `F_GETPATH` must still
/// be the path the walk reached it by, from the root's real path, or the
/// directory is left and counted as failed. What remains is a rename between
/// that check and the directory's last entry, which reaches no further than
/// that one directory's own entries, and a file swapped in between `fstatat`
/// and `unlinkat` by someone with write access to a directory this user owns
/// inside the root, which removes nothing that user could not already remove.
///
/// **Only this user's entries, on the home's own volume.** A root on another
/// device than the home, whether a RAM disk, an external drive or a share
/// mounted at the root or at any component above it, is refused whole, and an
/// entry another user owns or on another device is skipped with everything
/// under it. Nothing is deleted with elevated rights or through a shell:
/// `unlinkat` is the only call that removes anything, and the root itself is
/// never removed, so the tool that owns the cache finds its directory where it
/// left it.
///
/// **Never under the tool that writes it**: see `CleanupTool`. A removal
/// holds uv's lock while it runs and keeps the lock file itself, and refuses a
/// cache whose tool is running otherwise. A tool that starts after that check
/// is the one race left, and it meets a cache emptied under it, which each of
/// these tools already survives as a cache miss.
///
/// **One walk per root at a time**, sizing or removal, so two can never race
/// over one tree and the descriptors held stay bounded: at most `maxDepth`
/// plus one per walk. A root is its directory rather than its target, so
/// DerivedData and its removed projects wait for each other.
///
/// **What is counted is the allocated size**, `st_blocks`, once per inode for
/// a hard-linked file, and only for what a cleanup would reach: a directory
/// that cannot be listed or entered is not counted, its own blocks included,
/// since a removal would leave it too. It is an upper bound on what a removal
/// hands back: APFS clones share their blocks, and measured 2026-09-28 the
/// private part of DerivedData was 5.8 GB of its 8.7 GB allocated and of the
/// uv cache 3.1 of 6.0, while reading that private size tripled the walk, 7 s
/// against 2 s for DerivedData.
struct DiskCleaner: Sendable {
    /// How deep a walk goes below a root. Each level holds one descriptor
    /// against a soft limit of 256 for the whole app; measured 2026-09-28 the
    /// deepest entry under any root was 15 levels down, so 24 leaves room for a
    /// deeper cache and keeps two walks well inside the limit.
    static let maxDepth = 24

    let home: String
    private let owns: @Sendable (stat) -> Bool
    private let device: @Sendable (stat) -> dev_t
    private let runningTools: @Sendable () -> Set<CleanupTool>
    private let directoryOpened: (@Sendable (String) -> Void)?

    /// `owns` is the ownership rule and `device` the volume an entry is on,
    /// seams for tests that cannot make a file another user owns or mount a
    /// volume; `runningTools` reads the process table, which a test must not;
    /// `directoryOpened` hears the path of each directory the removal has
    /// opened and not yet checked, so a test can move one. Every caller in the
    /// app takes the defaults.
    init(
        home: String = NSHomeDirectory(),
        owns: @escaping @Sendable (stat) -> Bool = { $0.st_uid == getuid() },
        device: @escaping @Sendable (stat) -> dev_t = { $0.st_dev },
        runningTools: @escaping @Sendable () -> Set<CleanupTool> = CleanupToolScan.running,
        directoryOpened: (@Sendable (String) -> Void)? = nil
    ) {
        self.home = home
        self.owns = owns
        self.device = device
        self.runningTools = runningTools
        self.directoryOpened = directoryOpened
    }

    /// The bytes a cleanup of `target` would remove, 0 for a directory that
    /// is not there or not safe to open, nil if cancelled or if another walk
    /// holds the root.
    ///
    /// Sizing DerivedData took 4.6 s of wall time for 9.2 GB in 156,979
    /// files, measured 2026-09-28 in a release build on a Mac under a build
    /// load, where `fts` took 4.2 s over the same tree; the uv cache took
    /// 5.8 s. It is seconds, so a caller runs it off the main actor and a page
    /// says it is sizing.
    func size(of target: CleanupTarget) async -> Int64? {
        await Self.offThread { self.size(of: target, cancellation: $0) }
    }

    /// Empties `target`, keeping the directory itself, or says why nothing was
    /// touched.
    func clean(_ target: CleanupTarget) async -> Result<CleanupReport, CleanupRefusal> {
        await Self.offThread { self.clean(target, cancellation: $0) }
    }

    /// The tool at work on `target` now, which a page asks before it offers
    /// the removal. The removal asks again, since the answer can change.
    func toolAtWork(on target: CleanupTarget) async -> CleanupTool? {
        await Self.offThread { _ in
            guard let root = openRoot(target) else { return nil }
            defer { close(root.descriptor) }
            switch toolGuard(target, root: root.descriptor) {
            case .success(let lock):
                lock?.release()
                return nil
            case .failure(.toolRunning(let tool)): return tool
            case .failure: return nil
            }
        }
    }

    func size(of target: CleanupTarget, cancellation: CleanupCancellation) -> Int64? {
        guard claim(target) else { return nil }
        defer { release(target) }
        guard let root = openRoot(target) else { return 0 }
        defer { close(root.descriptor) }
        var seen: Set<ino_t> = []
        return allocated(
            in: root.descriptor, own: 0, depth: 0, seen: &seen,
            Walk(
                device: root.device, cancellation: cancellation,
                removedProjectsOnly: target == .removedProjects, places: root.places))
    }

    func clean(_ target: CleanupTarget, cancellation: CleanupCancellation) -> Result<
        CleanupReport, CleanupRefusal
    > {
        guard claim(target) else { return .failure(.walkInProgress) }
        defer { release(target) }
        guard let root = openRoot(target) else { return .failure(.unsafeRoot) }
        defer { close(root.descriptor) }
        let lock: CleanupToolLock?
        switch toolGuard(target, root: root.descriptor) {
        case .success(let held): lock = held
        case .failure(let refusal): return .failure(refusal)
        }
        defer { lock?.release() }
        var report = CleanupReport()
        let kept = lock == nil ? [] : Array(CleanupToolLock.fileName.utf8CString)
        empty(
            Directory(descriptor: root.descriptor, path: root.path), depth: 0, keeping: kept,
            report: &report,
            Walk(
                device: root.device, cancellation: cancellation,
                removedProjectsOnly: target == .removedProjects, places: root.places))
        return .success(report)
    }

    /// uv's lock when it keeps one, or the process table otherwise.
    private func toolGuard(_ target: CleanupTarget, root: Int32) -> Result<
        CleanupToolLock?, CleanupRefusal
    > {
        if target.tool == .uv {
            switch CleanupToolLock.take(in: root) {
            case .held(let lock): return .success(lock)
            case .busy: return .failure(.toolRunning(.uv))
            case .absent: break
            }
        }
        return runningTools().contains(target.tool) ? .failure(.toolRunning(target.tool)) : .success(nil)
    }

    // MARK: Root

    private struct Root {
        let descriptor: Int32
        let device: dev_t
        let path: String
        /// Where a removed project may have been: see `DiskCleaner.isGone`.
        let places: [String]
    }

    /// The roots a walk holds, keyed by home and target, across every cleaner
    /// in the process.
    private static let walking = LockedValue<Set<String>>([])

    private func walkKey(_ target: CleanupTarget) -> String {
        home + "\u{0}" + target.components.joined(separator: "/")
    }

    private func claim(_ target: CleanupTarget) -> Bool {
        var claimed = false
        Self.walking.update { claimed = $0.insert(walkKey(target)).inserted }
        return claimed
    }

    private func release(_ target: CleanupTarget) {
        Self.walking.update { $0.remove(walkKey(target)) }
    }

    private func openRoot(_ target: CleanupTarget) -> Root? {
        guard let realHome = Self.realPath(home) else { return nil }
        var descriptor = open(home, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        var homeStatus = stat()
        guard fstat(descriptor, &homeStatus) == 0 else {
            close(descriptor)
            return nil
        }
        for component in target.components {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(descriptor)
            guard next >= 0 else { return nil }
            descriptor = next
        }
        var status = stat()
        let expected = ([realHome] + target.components).joined(separator: "/")
        guard fstat(descriptor, &status) == 0, Self.isDirectory(status), owns(status),
            device(status) == device(homeStatus), Self.path(of: descriptor) == expected
        else {
            close(descriptor)
            return nil
        }
        return Root(
            descriptor: descriptor, device: device(status), path: expected,
            places: Self.projectPlaces(home: home, realHome: realHome))
    }

    /// The home as it was given and as it resolves, and the two temporary
    /// directories, each spelled every way a recorded path may start with.
    private static func projectPlaces(home: String, realHome: String) -> [String] {
        let temporary = (NSTemporaryDirectory() as NSString).standardizingPath
        let spellings = [home, realHome, "/tmp", "/private/tmp", temporary, realPath(temporary)]
        return Array(Set(spellings.compactMap { $0 }))
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func path(of descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: Walk

    /// An entry as it was examined, before anything was done to it.
    private struct Entry {
        let name: [CChar]
        let status: stat
    }

    /// An open directory and the path the walk reached it by.
    private struct Directory {
        let descriptor: Int32
        let path: String

        func child(_ name: [CChar], _ descriptor: Int32) -> Self {
            Self(descriptor: descriptor, path: path + "/" + String(cString: name))
        }
    }

    /// What every level of one walk shares: the root's volume, the stop
    /// signal, and, when only the root's removed projects are reached, the
    /// home a project must have been inside to count as gone.
    private struct Walk {
        let device: dev_t
        let cancellation: CleanupCancellation
        var removedProjectsOnly = false
        var places: [String] = []

        /// Whether the walk reaches an entry of the root at all.
        func reaches(_ name: [CChar], in root: Int32, _ status: stat) -> Bool {
            !removedProjectsOnly
                || DiskCleaner.isRemovedProject(name, in: root, status, inside: places, device: device)
        }

        /// The entry a folder of the root keeps until the rest of it is gone:
        /// a removed project's record, which is what says the folder is one.
        var record: [CChar] { removedProjectsOnly ? DiskCleaner.infoPlist : [] }
    }

    // MARK: Removed projects

    /// The most an `info.plist` of DerivedData is read to; measured 2026-09-29
    /// the largest of 30 was under 1 KB.
    private static let infoPlistLimit = 64 * 1024
    fileprivate static let infoPlist = Array("info.plist".utf8CString)

    /// Whether a folder of DerivedData holds the builds of a project that is
    /// no longer there.
    ///
    /// **Only an answer of absence counts.** The folder must be a directory
    /// whose `info.plist`, opened without following a link, names a
    /// `WorkspacePath` that `isGone` answers for. Anything else keeps the
    /// folder: a folder with no such record (`ModuleCache.noindex` and the SDK
    /// caches beside it), a record that cannot be read, a project Sissy is
    /// refused the right to look at, which answers `EPERM`.
    static func isRemovedProject(
        _ name: [CChar], in parent: Int32, _ status: stat, inside places: [String], device: dev_t
    ) -> Bool {
        guard isDirectory(status), let folder = openChild(name, in: parent, matching: status) else {
            return false
        }
        defer { close(folder) }
        guard let data = readInfoPlist(in: folder),
            let record = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            let project = record["WorkspacePath"] as? String
        else { return false }
        return isGone(project, inside: places, device: device)
    }

    /// Whether `path`, inside one of `places`, names nothing, and the nearest
    /// directory above it that does exist is on the home's volume `device`.
    ///
    /// **Inside the home or a temporary directory, because only there can
    /// absence be told from a volume that is away.** A project on a drive that
    /// is not mounted answers `ENOENT` while it is still whole, and so does one
    /// under an empty mount point left behind at `/Volumes`, an automount
    /// under `/net`, or a path spelled `/volumes` on a case-insensitive disk.
    /// The temporary directories are the boot volume's own and nobody mounts
    /// there, and they are where agents build: measured 2026-09-29, of the 28
    /// removed projects DerivedData named on the Mac this was built on, 19 sat
    /// in the home and 9, 2.8 GB, in scratch directories under `/tmp`. A path
    /// with a `.` or `..` component or a NUL is not read at all, so the prefix
    /// is the path's real place, and the ancestor check catches a volume
    /// mounted inside the home and then taken away. An ancestor that is a link
    /// is followed, and must lead to a directory on that same volume: a link
    /// to a drive that is away is the absence this refuses to believe.
    static func isGone(_ path: String, inside places: [String], device: dev_t) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.contains("\0"), !components.contains("."), !components.contains(".."),
            places.contains(where: { path.hasPrefix($0 + "/") })
        else { return false }
        var status = stat()
        guard lstat(path, &status) != 0, errno == ENOENT else { return false }
        var ancestor = (path as NSString).deletingLastPathComponent
        while lstat(ancestor, &status) != 0 {
            guard errno == ENOENT, places.contains(where: { ancestor.hasPrefix($0 + "/") }) else {
                return false
            }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        if status.st_mode & S_IFMT == S_IFLNK, stat(ancestor, &status) != 0 { return false }
        return isDirectory(status) && status.st_dev == device
    }

    private static func readInfoPlist(in folder: Int32) -> Data? {
        let file = openat(folder, "info.plist", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { return nil }
        defer { close(file) }
        var status = stat()
        guard fstat(file, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
            status.st_size <= infoPlistLimit
        else { return nil }
        var data = Data(count: Int(status.st_size))
        let count = data.withUnsafeMutableBytes { read(file, $0.baseAddress, $0.count) }
        return count == data.count ? data : nil
    }

    /// A directory whose entries could not be read to the end.
    private struct ListingFailed: Error {}

    /// One directory's entries, read whole before any is touched: whether
    /// `readdir` returns entries removed while it runs is unspecified.
    private static func names(in descriptor: Int32) throws -> [[CChar]] {
        let listing = dup(descriptor)
        guard listing >= 0 else { throw ListingFailed() }
        guard let directory = fdopendir(listing) else {
            close(listing)
            throw ListingFailed()
        }
        defer { closedir(directory) }
        var names: [[CChar]] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else { break }
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                raw.prefix(length).map { CChar(bitPattern: $0) } + [0]
            }
            if name == [0x2E, 0] || name == [0x2E, 0x2E, 0] { continue }
            names.append(name)
        }
        guard errno == 0 else { throw ListingFailed() }
        return names
    }

    /// Opens the directory `name` names in `parent`, only if it is still the
    /// inode `status` describes.
    private static func openChild(_ name: [CChar], in parent: Int32, matching status: stat) -> Int32? {
        let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { return nil }
        var opened = stat()
        guard fstat(child, &opened) == 0, opened.st_dev == status.st_dev, opened.st_ino == status.st_ino
        else {
            close(child)
            return nil
        }
        return child
    }

    private static func isDirectory(_ status: stat) -> Bool { status.st_mode & S_IFMT == S_IFDIR }

    private static func blocks(_ status: stat) -> Int64 { Int64(status.st_blocks) * 512 }

    /// What a directory would free, its own blocks `own` included once its
    /// entries could be read.
    private func allocated(
        in descriptor: Int32, own: Int64, depth: Int, seen: inout Set<ino_t>, _ walk: Walk
    ) -> Int64? {
        guard let names = try? Self.names(in: descriptor) else { return 0 }
        var total = own
        for name in names {
            if walk.cancellation.isCancelled { return nil }
            var status = stat()
            guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
                device(status) == walk.device, owns(status),
                depth > 0 || walk.reaches(name, in: descriptor, status)
            else { continue }
            if Self.isDirectory(status) {
                guard depth < Self.maxDepth,
                    let child = Self.openChild(name, in: descriptor, matching: status)
                else { continue }
                defer { close(child) }
                guard
                    let inner = allocated(
                        in: child, own: Self.blocks(status), depth: depth + 1, seen: &seen, walk)
                else { return nil }
                total += inner
            } else if status.st_nlink <= 1 || seen.insert(status.st_ino).inserted {
                total += Self.blocks(status)
            }
        }
        return total
    }

    /// Empties a directory, leaving `keeping` where it is, and at the root
    /// every entry the walk does not reach.
    private func empty(
        _ directory: Directory, depth: Int, keeping: [CChar], report: inout CleanupReport,
        _ walk: Walk
    ) {
        guard Self.path(of: directory.descriptor) == directory.path,
            let names = try? Self.names(in: directory.descriptor)
        else {
            report.failed += 1
            return
        }
        for name in names {
            if walk.cancellation.isCancelled {
                report.cancelled = true
                return
            }
            var status = stat()
            guard fstatat(directory.descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                report.failed += 1
                continue
            }
            if name == keeping || depth == 0 && !walk.reaches(name, in: directory.descriptor, status) {
                continue
            }
            guard device(status) == walk.device, owns(status) else {
                report.skipped += 1
                continue
            }
            if Self.isDirectory(status) {
                removeDirectory(
                    Entry(name: name, status: status), in: directory, depth: depth, &report, walk)
                if report.cancelled { return }
            } else if unlinkat(directory.descriptor, name, 0) == 0 {
                report.removed += 1
                if status.st_nlink <= 1 { report.removedBytes += Self.blocks(status) }
            } else {
                report.failed += 1
            }
        }
    }

    /// Empties a directory below the root, then removes it. One left holding
    /// what was skipped or refused inside it is not counted a second time.
    ///
    /// A removed project's record goes last, and only once everything beside
    /// it has: a folder a removal left half emptied, by a refusal, a
    /// cancellation or the app quitting, must still read as a removed project
    /// the next time, or only emptying all of DerivedData could reach it.
    private func removeDirectory(
        _ entry: Entry, in parent: Directory, depth: Int, _ report: inout CleanupReport, _ walk: Walk
    ) {
        guard depth < Self.maxDepth,
            let descriptor = Self.openChild(entry.name, in: parent.descriptor, matching: entry.status)
        else {
            report.failed += 1
            return
        }
        let child = parent.child(entry.name, descriptor)
        directoryOpened?(child.path)
        let before = report
        let record = depth == 0 ? walk.record : []
        empty(child, depth: depth + 1, keeping: record, report: &report, walk)
        if !report.cancelled, !record.isEmpty, !Self.leftSomething(since: before, report) {
            removeFile(record, in: descriptor, &report)
        }
        close(descriptor)
        if report.cancelled { return }
        let leftInside = Self.leftSomething(since: before, report)
        if unlinkat(parent.descriptor, entry.name, AT_REMOVEDIR) == 0 {
            report.removed += 1
            report.removedBytes += Self.blocks(entry.status)
        } else if !leftInside {
            report.failed += 1
        }
    }

    private static func leftSomething(since before: CleanupReport, _ report: CleanupReport) -> Bool {
        report.skipped != before.skipped || report.failed != before.failed
    }

    private func removeFile(_ name: [CChar], in directory: Int32, _ report: inout CleanupReport) {
        var status = stat()
        guard fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
            unlinkat(directory, name, 0) == 0
        else {
            report.failed += 1
            return
        }
        report.removed += 1
        if status.st_nlink <= 1 { report.removedBytes += Self.blocks(status) }
    }

    // MARK: Off the actor

    /// Runs a walk on a dispatch thread, since it is blocking I/O that can
    /// last seconds, and hands it a flag the task's cancellation raises.
    private static func offThread<Value: Sendable>(
        _ work: @escaping @Sendable (CleanupCancellation) -> Value
    ) async -> Value {
        let cancellation = CleanupCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: work(cancellation))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}
