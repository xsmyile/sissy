import Foundation

/// A directory that was a checkout of a repository, and the repository it
/// belonged to.
///
/// `directory` is where the `.git` entry was read: a worktree for a worktree,
/// the repository itself for a repository. `project` is the answer that entry
/// gave — the main checkout in the first case, the directory in the second.
struct ProjectCheckout: Codable, Equatable, Sendable {
    let directory: String
    let project: String
}

/// What Sissy knows about which directory was a checkout of which repository,
/// and the only thing that can still answer for one that has been deleted.
///
/// It is kept apart from the tail's snapshot, and durable on its own terms,
/// for the reason the archive is: it holds no token math, so nothing that
/// changes how a cost is derived may throw it away. A `UsageStateSnapshot`
/// schema bump quarantines the file it used to ride in — seven times on one
/// machine, at v1, v2 and v3 — and a memory that dies there dies exactly
/// before the cold scan that needs it most.
///
/// **One ledger serves every provider.** Two answer the same path differently
/// as soon as one has seen a checkout the other has not, which is what a
/// memory per adapter did: Codex remembered nothing at all, because none of
/// the directories its own lines name is a repository.
///
/// Shared across the providers' actors, so the state sits behind a lock — and
/// no file I/O happens while that lock is held.
final class ProjectLedger: @unchecked Sendable {
    /// How many gone checkouts are worth carrying. Generous on purpose: an
    /// evicted entry is a row that loses its project for good, and the
    /// archive it has to answer for retains 90 days by default and may be
    /// asked for ten years. At a worktree-per-hour this is a year of them,
    /// and the file is a path pair each.
    static let maxCheckouts = 4096
    static let currentSchemaVersion = 1

    private static let fileName = "project-checkouts.json"

    /// The ledger's own file, beside the snapshot that used to carry this.
    static func defaultURL(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    private struct Document: Codable {
        var schemaVersion: Int
        var updatedAt: Date
        var checkouts: [ProjectCheckout]
    }

    private let url: URL?
    private let fileManager: FileManager
    private let lock = NSLock()
    /// Most recently confirmed first, which is also the order the cap drops
    /// from: a checkout still being worked in is re-confirmed on every launch.
    private var checkouts: [ProjectCheckout] = []
    private var dirty = false
    /// False once the file on disk is found to be a schema this build does not
    /// know. The run keeps its own memory and refuses to write over one a
    /// newer build left, which is the archive's rule and for the same reason:
    /// what is on disk knows more than this build can express.
    private var writable = true

    init(url: URL? = nil, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
        load()
    }

    /// The repository a directory belonged to when it was last read, for a
    /// directory that is no longer there.
    ///
    /// Only for one that is **gone**. A directory still on disk that names no
    /// repository is answered by the disk, because what a path means is
    /// today's answer; a deletion is not a change of meaning, it is the end of
    /// the only thing that could have changed it.
    ///
    /// Deepest match wins, so a worktree that sat inside another checkout is
    /// answered by itself rather than by what contained it.
    func project(under workingDirectory: String) -> String? {
        let match = lock.withLock {
            checkouts
                .filter { workingDirectory.isInside($0.directory) }
                .max { $0.directory.count < $1.directory.count }
        }
        guard let match, !fileManager.fileExists(atPath: match.directory) else { return nil }
        remember(match)
        return match.project
    }

    func remember(_ checkout: ProjectCheckout) {
        lock.withLock {
            if checkouts.first == checkout { return }
            if !checkouts.contains(checkout) { dirty = true }
            checkouts.removeAll { $0.directory == checkout.directory }
            checkouts.insert(checkout, at: 0)
            cap()
        }
    }

    /// Seeds what an earlier run read off disk. Additive and behind whatever
    /// this run has already walked to: a `.git` entry read a moment ago is a
    /// fresher answer about the same directory than one read last week.
    func adopt(_ remembered: [ProjectCheckout]) {
        lock.withLock {
            let known = Set(checkouts.map(\.directory))
            let added = remembered.filter { !known.contains($0.directory) }
            guard !added.isEmpty else { return }
            checkouts.append(contentsOf: added)
            dirty = true
            cap()
        }
    }

    func all() -> [ProjectCheckout] { lock.withLock { checkouts } }

    func saveIfDirty(now: Date = Date()) {
        guard let url else { return }
        let document: Document? = lock.withLock {
            guard dirty, writable else { return nil }
            dirty = false
            return Document(
                schemaVersion: Self.currentSchemaVersion, updatedAt: now, checkouts: checkouts)
        }
        guard let document else { return }
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(document).write(to: url, options: [.atomic])
        } catch {
            lock.withLock { dirty = true }
            sissyLog("sissy: project ledger save failed at \(url.path): \(error)")
        }
    }

    private func load() {
        guard let url, let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(Document.self, from: data) else {
            quarantine(url)
            return
        }
        guard document.schemaVersion == Self.currentSchemaVersion else {
            lock.withLock { writable = false }
            sissyLog(
                "sissy: project ledger at \(url.path) is schema \(document.schemaVersion), "
                    + "expected \(Self.currentSchemaVersion) — left alone, not written this run")
            return
        }
        lock.withLock {
            checkouts = document.checkouts
            cap()
        }
    }

    /// A file that will not decode holds nothing this build can use, and the
    /// write that produced it was atomic — so it is a forensic artifact rather
    /// than a record, and the run starts empty instead of refusing to write.
    private func quarantine(_ url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let target = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp).json")
        try? fileManager.moveItem(at: url, to: target)
        sissyLog("sissy: project ledger at \(url.path) did not decode — quarantined")
    }

    private func cap() {
        guard checkouts.count > Self.maxCheckouts else { return }
        checkouts.removeLast(checkouts.count - Self.maxCheckouts)
    }
}

extension String {
    /// Whether this path is `directory` or sits under it, by path component —
    /// `/a/bc` is not inside `/a/b`.
    fileprivate func isInside(_ directory: String) -> Bool {
        self == directory || hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
    }
}
