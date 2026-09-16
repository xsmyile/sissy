import Foundation

/// What Sissy knows about a linked claude.ai session, beside the session.
///
/// The session itself is a secret and lives in the keychain; this is the part
/// that is not, and it exists because neither answer is derivable when it is
/// needed. The identity, because an account reached only through a session has
/// no archived CLI credential and therefore no entry in the account index —
/// without this its row is labelled with the raw Anthropic uuid, which is the
/// ordinary case the moment sessions can be linked rather than imported. The
/// organisation, because an account can hold more than one that answers the
/// usage question and membership order is the server's: picking by capability
/// narrows it, and on an account holding a personal plan *and* a team seat
/// both name `chat` and the pick is arbitrary — and arbitrary differently
/// between two polls of one account.
struct ClaudeWebLink: Sendable, Codable, Equatable {
    let identity: ClaudeAccountIdentity
    /// Organisation whose usage this session is read for, chosen once when the
    /// account was linked.
    ///
    /// Absent for a session Sissy adopted from Claude.app rather than linked:
    /// nobody was there to be asked, and recording the capability-picked one
    /// as a choice would give a guess the standing of an answer. A reader with
    /// none derives it per poll, which is what every reader did before links
    /// existed.
    let organization: String?
}

/// One account Sissy holds a claude.ai session for, as a surface lists it.
///
/// Built from the sessions rather than from the links, because the two are not
/// the same list and the shorter one is the wrong one. A session is filed
/// first and named second — `UsageEngine.store(session:as:)` catches a failed
/// `remember` and keeps the session, on the reasoning that losing a login to a
/// disk error is worse than deriving an organisation — so a session with no
/// entry is a state the ordinary path can produce, and one whose reader is
/// polling claude.ai either way. Listing the links would leave it running with
/// no row and no way to stop it.
///
/// The identity is therefore optional and filled by whatever can fill it: the
/// link, then the account archive, then nothing. The same fallback the panel's
/// own rows take, so one account cannot be named two ways.
struct ClaudeWebAccount: Sendable, Equatable, Identifiable {
    let id: String
    let identity: ClaudeAccountIdentity?

    /// The join itself, so which accounts get a row is testable without a
    /// keychain.
    ///
    /// Driven by `stored`, never by `links`: an entry naming a session that is
    /// no longer filed is a row for an account Sissy reads nothing for, and a
    /// session with no entry is the case this list exists to reach.
    static func list(
        stored: [String],
        links: [String: ClaudeWebLink],
        archived: [ClaudeAccountIdentity]
    ) -> [ClaudeWebAccount] {
        stored
            .filter { $0 != ClaudeWebSessionStore.unkeyedAccount }
            .map { uuid in
                ClaudeWebAccount(
                    id: uuid,
                    identity: links[uuid]?.identity ?? archived.first { $0.uuid == uuid })
            }
    }
}

/// The links, in a file of Sissy's own beside the sessions they describe.
///
/// Deliberately not `ClaudeAccountStore`'s index, though both list accounts.
/// That one answers "whose CLI credential has Sissy archived", which is what
/// decides whether an account can be switched to; an account with a session
/// and no archived credential belongs in exactly one of the two lists, and
/// putting it in that one would offer `Use in CLI` for an account Sissy holds
/// nothing to sign in with. The lifecycles differ for the same reason:
/// forgetting the sessions must not drop the archived credentials, and
/// forgetting an account must not unlink its session.
///
/// It holds no secret, so it is readable on a build whose keychain grant has
/// lapsed — which is what lets the panel name an account it cannot currently
/// read.
struct ClaudeWebSessionIndex: Sendable {
    let url: URL

    static let fileName = "claude-web-sessions.json"

    static func defaultURL(in parent: URL) -> URL {
        parent.appendingPathComponent(fileName)
    }

    private struct Contents: Codable {
        var links: [String: ClaudeWebLink] = [:]
    }

    func load() -> [String: ClaudeWebLink] {
        guard let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(Contents.self, from: data)
        else { return [:] }
        return decoded.links
    }

    /// Records what a link turned out to be, replacing whatever was there.
    ///
    /// Linking the same account again is a re-link rather than a second entry:
    /// the session it describes has just been replaced too.
    func remember(_ link: ClaudeWebLink) throws {
        var links = load()
        links[link.identity.uuid] = link
        try save(links)
    }

    /// Drops one account's link. An entry that was not there is not a failure.
    func forget(uuid: String) throws {
        var links = load()
        guard links.removeValue(forKey: uuid) != nil else { return }
        try save(links)
    }

    /// Drops every link, for the switch that forgets every session.
    func forgetAll() throws {
        guard !load().isEmpty else { return }
        try save([:])
    }

    private func save(_ links: [String: ClaudeWebLink]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Contents(links: links)).write(to: url, options: .atomic)
    }
}
