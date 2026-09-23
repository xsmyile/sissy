import Foundation

/// Removes, at launch, the HTTP cache and cookie jar the process-wide default
/// session wrote for either build before every request went through
/// `SissyHTTP`.
///
/// Those files hold credentials in the clear (`SissyHTTP` has the count), and
/// nothing reads them any more, so they are deleted rather than migrated. It
/// runs on every launch rather than once behind a marker: with nothing
/// writing there it finds nothing and costs a directory listing, and a marker
/// would be one more file that could say the job was done when a downgrade
/// had filled the cache again. Both bundle ids are purged whichever build is
/// running, because a Mac that ran both keeps both trees.
///
/// Only named entries are touched, and no symlink is followed: a build's
/// cache directory that is not a real directory is skipped whole, and a link
/// among the entries is unlinked rather than traversed, so the purge cannot
/// reach outside the two trees it was pointed at.
enum HTTPStoragePurge {
    static let bundleIdentifiers = ["com.radonforge.sissy", "com.radonforge.sissy.dev"]

    /// The cache database and its `-wal` / `-shm` companions share this prefix.
    static let cacheDatabasePrefix = "Cache.db"

    /// Where the cache keeps reply bodies too large for the database.
    static let cacheBodiesDirectory = "fsCachedData"

    /// The two directories under `~/Library` the default session writes into.
    struct Roots {
        let caches: URL
        let httpStorages: URL

        static func user() -> Self {
            Self(
                caches: URL.libraryDirectory.appendingPathComponent("Caches"),
                httpStorages: URL.libraryDirectory.appendingPathComponent("HTTPStorages"))
        }
    }

    /// Deletes every matching entry under `roots` and answers what it deleted.
    /// The release id is a prefix of the dev one, so an entry both name is
    /// removed once. A removal that fails is logged by entry name and left for the next
    /// launch; it never stops the others.
    @discardableResult
    static func run(
        in roots: Roots, bundleIdentifiers: [String] = bundleIdentifiers,
        fileManager: FileManager = .default
    ) -> [URL] {
        var seen: Set<URL> = []
        let targets = bundleIdentifiers.flatMap { id in
            cacheEntries(in: roots.caches.appendingPathComponent(id), fileManager)
                + storageEntries(for: id, in: roots.httpStorages, fileManager)
        }.filter { seen.insert($0).inserted }
        return targets.filter { remove($0, fileManager) }
    }

    private static func cacheEntries(in directory: URL, _ fileManager: FileManager) -> [URL] {
        guard isDirectory(directory, fileManager) else { return [] }
        return entries(of: directory, fileManager).filter { name in
            name.hasPrefix(cacheDatabasePrefix) || name == cacheBodiesDirectory
        }.map { directory.appendingPathComponent($0) }
    }

    private static func storageEntries(for id: String, in directory: URL, _ fileManager: FileManager)
        -> [URL]
    {
        guard isDirectory(directory, fileManager) else { return [] }
        return entries(of: directory, fileManager).filter { name in
            name == id || name.hasPrefix("\(id).")
        }.map { directory.appendingPathComponent($0) }
    }

    private static func entries(of directory: URL, _ fileManager: FileManager) -> [String] {
        (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    /// `attributesOfItem` does not traverse a final symlink, so a link to a
    /// directory answers `.typeSymbolicLink` here and is never entered.
    private static func isDirectory(_ url: URL, _ fileManager: FileManager) -> Bool {
        let type = (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        return type == .typeDirectory
    }

    private static func remove(_ url: URL, _ fileManager: FileManager) -> Bool {
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            let code = (error as NSError).code
            sissyLog("sissy: http-purge failed entry=\(url.lastPathComponent) code=\(code)")
            return false
        }
    }
}
