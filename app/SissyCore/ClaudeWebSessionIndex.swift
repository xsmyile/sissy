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
                let archived = archived.first { $0.uuid == uuid }
                guard let linked = links[uuid]?.identity else {
                    return ClaudeWebAccount(id: uuid, identity: archived)
                }
                return ClaudeWebAccount(id: uuid, identity: linked.named(after: archived))
            }
    }
}

extension ClaudeAccountIdentity {
    /// This identity, with the owner's name borrowed from another copy of the
    /// same account where this one does not carry it.
    ///
    /// A link is written once, when the account is linked, and never rewritten
    /// — so a field that lands in a later build never reaches an account
    /// already linked, and a user would have to unlink and sign in again to
    /// see a name Sissy can already read. That is the mirror of the freeze
    /// `ClaudeAccountRegistry` has on its own side, and it is worth undoing
    /// only for a field both copies answer for the same way: the uuid names
    /// one person, so whichever copy knows their name knows the same name.
    ///
    /// Deliberately the name and nothing else. Filling every nil from the
    /// archive would restore `rateLimitTier`, which `ClaudeWebAccountProfile`
    /// drops on purpose — claude.ai reports `default_raven` where the OAuth
    /// profile reports `default_claude_max_5x`, two taxonomies — so a generic
    /// merge would put back the one field a parser refuses.
    func named(after other: ClaudeAccountIdentity?) -> ClaudeAccountIdentity {
        guard name == nil, let borrowed = other?.name else { return self }
        return ClaudeAccountIdentity(
            uuid: uuid,
            email: email,
            name: borrowed,
            organization: organization,
            organizationType: organizationType,
            rateLimitTier: rateLimitTier,
            seat: seat)
    }
}
