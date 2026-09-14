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

/// What one pass over the inbox found.
///
/// `arrivedDeleted` is the measurement the inbox exists to justify: an entry
/// whose directory was already gone by the time Sissy read it is one the tail
/// could not have learned by itself, because there was nothing left to walk to.
struct InboxIngest: Equatable, Sendable {
    var read = 0
    var learned = 0
    var arrivedDeleted = 0
    var rejected = 0
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
/// **It learns from git, not only from the lines it reads.** A worktree is
/// recorded the moment anything resolves against the repository it was cut
/// from, by reading the list git itself keeps in
/// `<repo>/.git/worktrees/*/gitdir` — so the answer is banked while the
/// worktree is alive instead of being looked for once it is gone. Without
/// that, learning is a race against `git worktree remove` that the tail loses
/// whenever it is not running: measured 2026-09-13, a cold read of that day's
/// Claude Code logs could name 66% of its tokens and the day before 21%,
/// because the directories the work happened in had been deleted by the time
/// anything read the lines naming them.
///
/// What neither of those reaches is a checkout created *and* deleted while
/// Sissy was not running: git has pruned its side, the logs name the path and
/// nothing else, and there is no reading left to remember. That is what the
/// **inbox** answers. A CLI session writes the pair down itself, from inside
/// the directory, while it is still there — which happens whether or not Sissy
/// is running, and is the only evidence that survives being the one thing
/// Sissy could not have watched.
///
/// The inbox is written by a process Sissy does not control, so it is read as a
/// boundary rather than as its own file: every entry is opened without
/// following a link, checked to be a regular file this user owns, size-capped,
/// and parsed into the same pair a walk would have produced or discarded. What
/// survives is `adopt`ed rather than `remember`ed — evidence Sissy did not see
/// itself goes behind what it did, never in front of it.
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
    /// How long a repository's worktree list is taken on trust before it is
    /// read again. Shorter than the tail's poll so every poll refreshes it,
    /// and short enough that a worktree has to be created and destroyed
    /// inside half a minute to slip past.
    static let worktreeScanInterval: TimeInterval = 30
    /// How many inbox entries one pass consumes. The inbox is foreign input,
    /// and a pass runs on the tail's own cadence, so there is never a reason to
    /// let one directory listing become unbounded work.
    static let maxInboxEntriesPerPass = 256
    /// A pair of paths and two newlines. Anything larger is not the file the
    /// hook writes.
    static let maxInboxEntryBytes: off_t = 8192
    /// `PATH_MAX` on macOS. A path that cannot be opened cannot be a checkout.
    static let maxPathBytes = 1024
    static let currentSchemaVersion = 1

    private static let fileName = "project-checkouts.json"
    private static let inboxDirectoryName = "checkout-inbox"
    private static let gitEntryName = ".git"
    private static let worktreesDirName = "worktrees"
    private static let worktreePointerName = "gitdir"

    /// The ledger's own file, beside the snapshot that used to carry this.
    static func defaultURL(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// Where a CLI session leaves what it read about the directory it started
    /// in. Beside the ledger, because it is the same memory arriving by the one
    /// road that does not require Sissy to have been running.
    static func inboxURL(in directory: URL) -> URL {
        directory.appendingPathComponent(inboxDirectoryName)
    }

    private struct Document: Codable {
        var schemaVersion: Int
        var updatedAt: Date
        var checkouts: [ProjectCheckout]
    }

    private let url: URL?
    private let inbox: URL?
    private let fileManager: FileManager
    private let lock = NSLock()
    /// Held for the whole of a save, so the two providers cannot both reach
    /// the file with a document each: the one that wrote second would decide
    /// what is on disk, and the one that wrote the newer document has already
    /// cleared `dirty`, so nothing would rewrite it. Taken outside `lock` and
    /// never the other way round, which is the only order either is taken in.
    private let writeLock = NSLock()
    /// Most recently confirmed first, which is also the order the cap drops
    /// from: a checkout still being worked in is re-confirmed on every launch.
    private var checkouts: [ProjectCheckout] = []
    private var scannedAt: [String: Date] = [:]
    private var dirty = false
    /// False once the file on disk is found to be a schema this build does not
    /// know. The run keeps its own memory and refuses to write over one a
    /// newer build left, which is the archive's rule and for the same reason:
    /// what is on disk knows more than this build can express.
    private var writable = true

    init(url: URL? = nil, fileManager: FileManager = .default) {
        self.url = url
        self.inbox = url.map { Self.inboxURL(in: $0.deletingLastPathComponent()) }
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
    @discardableResult
    func adopt(_ remembered: [ProjectCheckout]) -> Int {
        lock.withLock {
            let known = Set(checkouts.map(\.directory))
            let added = remembered.filter { !known.contains($0.directory) }
            guard !added.isEmpty else { return 0 }
            checkouts.append(contentsOf: added)
            dirty = true
            cap()
            return added.count
        }
    }

    func all() -> [ProjectCheckout] { lock.withLock { checkouts } }

    /// Records every worktree git currently lists for a repository, so each one
    /// is already answered for by the time it is deleted.
    ///
    /// `<repo>/.git/worktrees/<name>/gitdir` names the worktree's own `.git`
    /// file, which is the pointer the walk would have read had it got there
    /// first. A pointer naming a relative path is skipped rather than guessed
    /// at — git writes an absolute one, and a reading that has to be
    /// reconstructed is not a reading.
    func harvestWorktrees(of repository: String, now: Date = Date()) {
        guard claimScan(of: repository, now: now) else { return }
        let admin = URL(fileURLWithPath: repository)
            .appendingPathComponent(Self.gitEntryName)
            .appendingPathComponent(Self.worktreesDirName)
        let entries =
            (try? fileManager.contentsOfDirectory(
                at: admin, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
        for entry in entries {
            let pointer = entry.appendingPathComponent(Self.worktreePointerName)
            guard let text = try? String(contentsOf: pointer, encoding: .utf8) else { continue }
            let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard target.hasPrefix("/") else { continue }
            let directory = URL(fileURLWithPath: target)
                .deletingLastPathComponent()
                .standardizedFileURL
                .path
            guard directory != repository else { continue }
            remember(ProjectCheckout(directory: directory, project: repository))
        }
    }

    /// Re-reads the worktree list of every repository the ledger already
    /// names. Run at launch and on the tail's own cadence, which is what turns
    /// harvesting from something that happens when a line is read into
    /// something that happens before one is.
    func refreshKnownRepositories(now: Date = Date()) {
        let repositories = Set(lock.withLock { checkouts.map(\.project) })
        for repository in repositories {
            harvestWorktrees(of: repository, now: now)
        }
    }

    /// Takes in what CLI sessions left in the inbox and empties it.
    ///
    /// An entry is deleted once it has been read, whether or not it was
    /// usable: it has either become a checkout the ledger now holds or been
    /// judged unusable, and neither answer changes by asking again. That is
    /// also what bounds the directory — there is no retention to tune and no
    /// stamp to keep, because nothing is left to re-read.
    ///
    /// An entry that cannot be opened at all is left where it is. It is
    /// nothing this run can act on, and removing a file Sissy could not even
    /// read is a worse answer than listing it again next time.
    @discardableResult
    func ingestInbox() -> InboxIngest {
        guard let inbox else { return InboxIngest() }
        let entries =
            (try? fileManager.contentsOfDirectory(
                at: inbox, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
        var report = InboxIngest()
        var arrived: [ProjectCheckout] = []
        for entry in entries.prefix(Self.maxInboxEntriesPerPass) {
            guard let text = readEntry(at: entry) else { continue }
            report.read += 1
            try? fileManager.removeItem(at: entry)
            guard let checkout = Self.checkout(from: text) else {
                report.rejected += 1
                continue
            }
            if !fileManager.fileExists(atPath: checkout.directory) {
                report.arrivedDeleted += 1
            }
            arrived.append(checkout)
        }
        report.learned = adopt(arrived)
        if report.read > 0 {
            sissyLog(
                "sissy: checkout inbox: read \(report.read), learned \(report.learned), "
                    + "already deleted on arrival \(report.arrivedDeleted), "
                    + "rejected \(report.rejected)")
        }
        return report
    }

    /// Reads one inbox entry through its descriptor rather than its path.
    ///
    /// `O_NOFOLLOW` refuses a symlink, so an entry pointed at a private key is
    /// not read and cannot reach a log. `O_NONBLOCK` is what stops a named pipe
    /// from holding `open(2)` open forever — that would wedge the provider
    /// actor this runs inside and stop metering with nothing to show for it —
    /// and the mode check is what rejects the pipe once it is open. Every other
    /// question is asked of the descriptor already held, so there is no window
    /// between deciding a file is safe and reading the file that answered.
    private func readEntry(at url: URL) -> String? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
            info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == getuid(),
            info.st_nlink == 1,
            info.st_size <= Self.maxInboxEntryBytes
        else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var filled = 0
        while filled < bytes.count {
            let taken = bytes[filled...].withUnsafeMutableBytes {
                read(descriptor, $0.baseAddress, $0.count)
            }
            guard taken > 0 else { break }
            filled += taken
        }
        guard filled == bytes.count else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// The pair an entry claims, or nil for anything that is not exactly one.
    ///
    /// Strict on purpose: this is the one place a path Sissy never walked to
    /// can enter the ledger, and from there a persisted row's label and an
    /// export.
    static func checkout(from text: String) -> ProjectCheckout? {
        var lines = text.components(separatedBy: "\n")
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.count == 2,
            let directory = path(from: lines[0], minimumComponents: 2),
            let project = path(from: lines[1], minimumComponents: 1)
        else { return nil }
        return ProjectCheckout(directory: directory, project: project)
    }

    /// An absolute path with nothing in it that a path cannot contain.
    ///
    /// A control character would reach a log and a row label, and `..`
    /// surviving standardization is a path that does not mean what it says.
    ///
    /// Standardised lexically rather than through `standardizedFileURL`, whose
    /// stripping of a `/private` prefix depends on the path still existing — so
    /// a checkout would normalise to one key while it was alive and another
    /// once it was gone, which is precisely the transition this file exists to
    /// survive. The hook already answers with a physical path.
    ///
    /// `minimumComponents` is two for the checkout and one for the repository,
    /// because only the checkout is matched by prefix: a planted `/Volumes`
    /// would re-label everything beneath it, where a repository that shallow is
    /// merely an odd label on its own row.
    private static func path(from line: String, minimumComponents: Int) -> String? {
        guard line.hasPrefix("/"), line.utf8.count <= maxPathBytes,
            !line.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return nil }
        let standardized = URL(fileURLWithPath: line).standardized.path
        guard standardized.hasPrefix("/"),
            !standardized.split(separator: "/").contains(".."),
            standardized.split(separator: "/").count >= minimumComponents
        else { return nil }
        return standardized
    }

    /// Flushed **ahead of** the tail's snapshot, which writes its own
    /// `projectCheckouts` back as nil: an install being migrated off that
    /// field has its only copy of the memory here until this returns, and the
    /// other order loses it to any process that dies in between.
    func saveIfDirty(now: Date = Date()) {
        guard let url else { return }
        writeLock.withLock {
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
    }

    private func claimScan(of repository: String, now: Date) -> Bool {
        lock.withLock {
            if let last = scannedAt[repository],
                now.timeIntervalSince(last) < Self.worktreeScanInterval
            {
                return false
            }
            scannedAt[repository] = now
            return true
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
        do {
            try fileManager.moveItem(at: url, to: target)
            sissyLog("sissy: project ledger at \(url.path) did not decode — quarantined")
        } catch {
            sissyLog(
                "sissy: project ledger at \(url.path) did not decode and could not be moved "
                    + "aside (\(error)) — this run starts empty and will overwrite it")
        }
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
