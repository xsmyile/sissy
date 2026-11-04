import Foundation

/// What a link index files: a link, the key it is filed under and the file
/// the index lives in.
protocol IndexedLink: Codable, Sendable {
    /// The account the link describes, which is the key its secret is filed
    /// under in the keychain.
    var key: String { get }
    static var fileName: String { get }
}

/// The links of one kind of linked account, in a file of Sissy's own beside
/// the secrets they describe.
///
/// One implementation for the claude.ai sessions and the Codex accounts,
/// which had been two byte-identical copies. Every change is a read, a
/// mutation and a write, and it holds `linkIndexLock` across all three: two
/// callers interleaving there (a link made from the window while an unlink
/// runs from Settings) would otherwise each write back the file as it read it,
/// and one of the two changes would be lost.
///
/// It holds no secret, so it is readable on a build whose keychain grant has
/// lapsed, which is what lets the panel name an account it cannot currently
/// read.
struct LinkIndex<Link: IndexedLink>: Sendable {
    let url: URL

    static func defaultURL(in parent: URL) -> URL {
        parent.appendingPathComponent(Link.fileName)
    }

    private struct Contents: Codable {
        var links: [String: Link] = [:]
    }

    private var file: VersionedJSONFile<Contents> {
        VersionedJSONFile(
            url: url, policy: .refuse,
            setAsidePrefix: "\(url.deletingPathExtension().lastPathComponent).unreadable-",
            formatting: [.prettyPrinted, .sortedKeys])
    }

    /// Every link, and none when there is no file yet.
    ///
    /// Throws for a file that is there and will not read, which used to come
    /// back as no links: the next `remember` or `forget` then wrote that over
    /// the file, losing every other account's name and chosen organisation.
    /// The rule `ForgeConnectionIndex.load` is on, for the same reason.
    func load() throws -> [String: Link] {
        try linkIndexLock.withLock { try file.load()?.links ?? [:] }
    }

    /// Every link, with an index that does not decode moved out of the way
    /// first.
    ///
    /// Moved rather than deleted: a person can still read it, and a new link
    /// starts a fresh file instead of being refused for ever. **Only a file
    /// that read and did not decode is moved**, because one whose read failed
    /// may be a sound index behind a lock or a permission. That, and a file
    /// that could not be moved, throw.
    func loadSettingAside(now: Date = Date()) throws -> [String: Link] {
        try linkIndexLock.withLock {
            try file.loadSettingAside(named: Link.fileName, now: now)?.links ?? [:]
        }
    }

    /// The links an engine starts with: none, and said so, when the file will
    /// not answer. The file stays where it is and `change` keeps refusing to
    /// write over it.
    func loadAtLaunch() -> [String: Link] {
        do {
            return try loadSettingAside()
        } catch {
            sissyLog("sissy: \(Link.fileName) could not be loaded (\(error))")
            return [:]
        }
    }

    /// Copies the file's links into what the engine holds. A file that will
    /// not read leaves the held copy as it stands, because blanking it would
    /// take every account's name with it.
    func reload(into held: LockedValue<[String: Link]>) {
        do {
            held.store(try load())
        } catch {
            sissyLog("sissy: \(Link.fileName) could not be reloaded (\(error))")
        }
    }

    /// Records what a link turned out to be, replacing whatever was there.
    ///
    /// Linking the same account again is a re-link rather than a second entry:
    /// the secret it describes has just been replaced too.
    func remember(_ link: Link) throws {
        try change {
            $0[link.key] = link
            return true
        }
    }

    /// Drops one account's link. An entry that was not there is not a failure.
    func forget(key: String) throws {
        try change { $0.removeValue(forKey: key) != nil }
    }

    /// Applies `mutation` to the file's links under the lock, and writes them
    /// back only when it answers that it changed something. A file that will
    /// not read throws before anything is written, so it is never overwritten.
    private func change(_ mutation: (inout [String: Link]) -> Bool) throws {
        try linkIndexLock.withLock {
            var links = try file.load()?.links ?? [:]
            guard mutation(&links) else { return }
            try file.save(Contents(links: links))
        }
    }
}

/// The one lock every link index changes its file under. One for all of
/// them rather than one per file, because the files are few and a change is
/// a few milliseconds of disk.
private let linkIndexLock = NSLock()

/// The claude.ai session links.
///
/// Deliberately not `ClaudeAccountStore`'s index, though both list accounts.
/// That one answers "who has Sissy seen signed in to the CLI"; an account with
/// a session that never signed in there belongs in exactly one of the two
/// lists. The lifecycles differ for the same reason: forgetting a session must
/// not drop the name, and forgetting an account must not unlink its session.
typealias ClaudeWebSessionIndex = LinkIndex<ClaudeWebLink>

/// The linked Codex accounts.
///
/// Deliberately its own file rather than a corner of `server.json`: it is
/// written from the link flow while the engine is running, and a config the
/// engine also rewrites would race it.
typealias CodexAccountIndex = LinkIndex<CodexAccountLink>

extension LinkIndex where Link == ClaudeWebLink {
    func forget(uuid: String) throws { try forget(key: uuid) }
}

extension LinkIndex where Link == CodexAccountLink {
    func forget(id: String) throws { try forget(key: id) }
}

extension ClaudeWebLink: IndexedLink {
    var key: String { identity.uuid }
    static var fileName: String { "claude-web-sessions.json" }
}

extension CodexAccountLink: IndexedLink {
    var key: String { identity.id }
    static var fileName: String { "codex-accounts.json" }
}
