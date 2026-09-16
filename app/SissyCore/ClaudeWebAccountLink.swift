import Foundation

/// One organisation of an account, as claude.ai names it.
///
/// The name is frequently not one a human chose: measured 2026-09-16 on two
/// accounts, claude.ai auto-generates `<name>'s Individual Org` and
/// `<email>'s Organization` for the organisation that comes with a personal
/// plan, and the two patterns differ. So the plan travels beside it — the
/// token `.claude.json` puts in `organizationType`, which `UsageFormat.plan`
/// already words — and a surface asking someone to choose can say what each
/// one *is* rather than repeat a machine-generated string at them.
struct ClaudeWebOrganization: Sendable, Codable, Equatable, Identifiable {
    let id: String
    let name: String
    /// The plan in the vocabulary `UsageFormat` words, which is the vendor's
    /// token with its `claude_` namespace stripped — the same form
    /// `ClaudeAccountIdentity.plan` answers in, so one organisation and the
    /// account it belongs to cannot label the same plan two ways.
    let plan: String?
}

/// The question a link could not answer for itself, as a surface draws it.
///
/// Carries the identity and the choices and never the session: the session is
/// the engine's until the question is answered, because a secret that reaches
/// a view is a secret that reaches a frame, a log, or an export.
struct ClaudeWebLinkChoice: Sendable, Equatable {
    let identity: ClaudeAccountIdentity
    let organizations: [ClaudeWebOrganization]
}

/// Turns a claude.ai session into a linked account.
///
/// Two questions, and the session is the only thing that can answer either:
/// whose account it is, and which of that account's organisations it should be
/// read for. Both are asked once, here, and the answers are stored — a poll
/// that derived them again would be free to derive them differently, which is
/// the defect this closes.
///
/// Nothing is written until both are settled. A session filed under an account
/// with no organisation recorded is one a reader would have to guess for, and
/// a link half-written is worse than a link the user has to make again.
enum ClaudeWebAccountLink {
    /// What one session turned out to need.
    enum Outcome: Sendable, Equatable {
        /// The ordinary case: one organisation answers the usage question, so
        /// there is nothing to ask and the link is complete.
        case linked(ClaudeWebLink)
        /// The account holds several. Which one this session meters is the
        /// user's to say, and the session is held until they do.
        case choice(identity: ClaudeAccountIdentity, organizations: [ClaudeWebOrganization])
    }

    /// Why a link could not be made. Each is a different sentence: a session
    /// claude.ai will not answer for is the user's to retry, and an account
    /// with no chat organisation is on no plan Sissy can read.
    enum Failure: Error, Equatable {
        case unidentified
        case noSubscription
        /// The question was answered and the session it belonged to was no
        /// longer held. Its own case rather than `unidentified`, because
        /// claude.ai answered fine and what to do about it is different: the
        /// login is made again, and nothing about the account was wrong.
        case interrupted
    }

    /// Resolves a session, asking claude.ai who it belongs to and what it
    /// could be read for.
    ///
    /// The two requests are made together rather than in sequence: neither
    /// depends on the other, and a link is two round trips to a server the
    /// user is waiting on.
    static func resolve(
        session: String,
        identify: @Sendable (String) async throws -> ClaudeAccountIdentity =
            ClaudeWebAccountProfile.resolve,
        organizations: @Sendable (String) async throws -> [ClaudeWebOrganization] =
            ClaudeWebSource.subscriptionOrganizations
    ) async throws -> Outcome {
        async let identityTask = identify(session)
        async let organizationsTask = organizations(session)

        let identity: ClaudeAccountIdentity
        let found: [ClaudeWebOrganization]
        do {
            identity = try await identityTask
            found = try await organizationsTask
        } catch {
            throw Failure.unidentified
        }

        guard let only = found.first else { throw Failure.noSubscription }
        guard found.count > 1 else {
            return .linked(ClaudeWebLink(identity: identity, organization: only.id))
        }
        return .choice(identity: identity, organizations: found)
    }
}
