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

    func load() -> [String: Link] {
        linkIndexLock.withLock { read() }
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

    /// Drops every link, for the switch that forgets every session.
    func forgetAll() throws {
        try change {
            defer { $0.removeAll() }
            return !$0.isEmpty
        }
    }

    /// Applies `mutation` to the file's links under the lock, and writes them
    /// back only when it answers that it changed something.
    private func change(_ mutation: (inout [String: Link]) -> Bool) throws {
        try linkIndexLock.withLock {
            var links = read()
            guard mutation(&links) else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Contents(links: links)).write(to: url, options: .atomic)
        }
    }

    private func read() -> [String: Link] {
        guard let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(Contents.self, from: data)
        else { return [:] }
        return decoded.links
    }
}

/// The one lock every link index changes its file under. One for all of
/// them rather than one per file, because the files are few and a change is
/// a few milliseconds of disk.
private let linkIndexLock = NSLock()

/// The claude.ai session links.
///
/// Deliberately not `ClaudeAccountStore`'s index, though both list accounts.
/// That one answers "whose CLI credential has Sissy archived", which is what
/// decides whether an account can be switched to; an account with a session
/// and no archived credential belongs in exactly one of the two lists, and
/// putting it in that one would offer `Use in CLI` for an account Sissy holds
/// nothing to sign in with. The lifecycles differ for the same reason:
/// forgetting the sessions must not drop the archived credentials, and
/// forgetting an account must not unlink its session.
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
