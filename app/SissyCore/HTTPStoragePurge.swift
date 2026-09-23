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
/// had filled the cache again. Every bundle id is purged whichever build is
/// running, because a Mac that ran both keeps both trees, and `sissy-cli`'s
/// two ids are among them: it sent its requests through the default session
/// under its own id, so what it fetched was cached in a tree of its own.
///
/// Only named entries are touched, and no symlink is followed: a build's
/// cache directory that is not a real directory is skipped whole, and a link
/// among the entries is unlinked rather than traversed, so the purge cannot
/// reach outside the two trees it was pointed at.
enum HTTPStoragePurge {
    static let bundleIdentifiers = [
        SissyPaths.releaseBundleIdentifier, SissyPaths.devBundleIdentifier,
        SissyPaths.cliBundleIdentifier, SissyPaths.cliDevBundleIdentifier,
    ]

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

    /// What one run did: the entries it deleted, and the directories it could
    /// not list, whose credentials may therefore still be on disk.
    struct Outcome: Equatable {
        var removed: [URL] = []
        var unreadable: [URL] = []
    }

    /// Deletes every matching entry under `roots` and answers what it deleted
    /// and what it could not look into. The release id is a prefix of the dev
    /// one, so an entry both name is removed once. A removal that fails, and a
    /// directory that exists but will not list, is logged by name and left
    /// for the next launch; neither stops the others. A directory that does
    /// not exist is nothing to purge rather than a failure.
    @discardableResult
    static func run(
        in roots: Roots, bundleIdentifiers: [String] = bundleIdentifiers,
        fileManager: FileManager = .default
    ) -> Outcome {
        var outcome = Outcome()
        let list = { (directory: URL) -> [String] in
            do {
                return try fileManager.contentsOfDirectory(atPath: directory.path)
            } catch {
                if !outcome.unreadable.contains(directory) { outcome.unreadable.append(directory) }
                return []
            }
        }
        var seen: Set<URL> = []
        let targets = bundleIdentifiers.flatMap { id in
            cacheEntries(in: roots.caches.appendingPathComponent(id), fileManager, list)
                + storageEntries(for: id, in: roots.httpStorages, fileManager, list)
        }.filter { seen.insert($0).inserted }
        outcome.removed = targets.filter { remove($0, fileManager) }
        for directory in outcome.unreadable {
            sissyLog("sissy: http-purge unlistable dir=\(directory.lastPathComponent)")
        }
        return outcome
    }

    private static func cacheEntries(
        in directory: URL, _ fileManager: FileManager, _ list: (URL) -> [String]
    ) -> [URL] {
        guard isDirectory(directory, fileManager) else { return [] }
        return list(directory).filter { name in
            name.hasPrefix(cacheDatabasePrefix) || name == cacheBodiesDirectory
        }.map { directory.appendingPathComponent($0) }
    }

    private static func storageEntries(
        for id: String, in directory: URL, _ fileManager: FileManager, _ list: (URL) -> [String]
    ) -> [URL] {
        guard isDirectory(directory, fileManager) else { return [] }
        return list(directory).filter { name in
            name == id || name.hasPrefix("\(id).")
        }.map { directory.appendingPathComponent($0) }
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
