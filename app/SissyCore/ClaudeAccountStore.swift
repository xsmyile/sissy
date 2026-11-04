import Foundation

/// Who an OAuth credential belongs to.
///
/// The credential blob itself names a subscription and a tier but no account,
/// so the only thing that can tell two sign-ins apart is the vendor's own
/// answer. Everything here is a display string read back from Anthropic for a
/// token the user already holds.
struct ClaudeAccountIdentity: Sendable, Codable, Equatable, Identifiable {
    /// Anthropic's own account id, which is what an account is filed under:
    /// it survives an email change and a re-login where nothing else does.
    let uuid: String
    let email: String?
    /// What the person calls themselves, where the vendor answers with one.
    ///
    /// The address is what an account is *keyed* by and the name is what it is
    /// recognised by, and they are not interchangeable: two seats of one
    /// company read as one word apart in a list of addresses, where the names
    /// beside them are the whole answer. Nil is the ordinary case rather than a
    /// fault — an account that has filled in neither field, and every source
    /// that answers for an account without naming its owner — so every surface
    /// that leads on it falls back to the address it always had.
    ///
    /// Optional on a type two JSON files hold, for the reason `seat` is.
    let name: String?
    let organization: String?
    /// `claude_team`, `claude_max`… as the vendor spells it. Worded by
    /// `UsageFormat`, never here.
    let organizationType: String?
    let rateLimitTier: String?
    /// Which seat of a Team plan the account holds (`team_tier_1`), where the
    /// vendor names one.
    ///
    /// Both sources answer for it and neither was read until now, so a Team
    /// account reached through either was badged "Team" where the CLI badged
    /// it "Team Premium" — measured 2026-09-16, `api/oauth/profile` carries
    /// `organization.seat_tier` and claude.ai carries `seat_tier` on the
    /// membership, both `team_tier_1` for the same account.
    ///
    /// Optional on a type two JSON files hold, so an index written before this
    /// decodes with a nil rather than being quarantined.
    let seat: String?
    /// The id of the organisation the seat belongs to, as `api/oauth/profile`
    /// answers it, which is what a reset is spent for. Optional for the reason
    /// `seat` is.
    let organizationUUID: String?
    /// The plan as Anthropic words it, off `organization.plan_display_name`
    /// on `api/oauth/profile`. Optional for the reason `seat` is, and nil on
    /// an account filed before it was read, which `UsageFormat` words from the
    /// tier instead.
    let planName: String?

    init(
        uuid: String,
        email: String?,
        name: String? = nil,
        organization: String?,
        organizationType: String?,
        rateLimitTier: String?,
        seat: String? = nil,
        organizationUUID: String? = nil,
        planName: String? = nil
    ) {
        self.uuid = uuid
        self.email = email
        self.name = name
        self.organization = organization
        self.organizationType = organizationType
        self.rateLimitTier = rateLimitTier
        self.seat = seat
        self.organizationUUID = organizationUUID
        self.planName = planName
    }

    var id: String { uuid }

    /// The account as a row carries it. Sanitized here rather than in the
    /// parses, so the index keeps what the vendor sent.
    var providerAccount: ProviderAccount? {
        ProviderAccount(
            email: UsageReaderShared.sanitizedDisplayText(email), name: name,
            organization: UsageReaderShared.sanitizedDisplayText(organization), seat: seat)
    }

    /// The plan and its tier in the vocabulary the frame carries: `team`
    /// rather than `claude_team`, `max_5x` rather than `default_claude_max_5x`.
    ///
    /// `UsageFormat` derives its words from the token rather than mapping it,
    /// so a prefixed one does not render a little wrong — it renders as a
    /// different plan. `words("claude_team")` is "Claude Team", and
    /// `tierParts("default_claude_max_5x")` splits a base that matches no
    /// plan, which put "Claude Team" and "Default Claude Max 5x" on the rows
    /// of every known account.
    var plan: String? {
        UsageReaderShared.sanitizedPlanToken(Self.stripping(Self.planPrefix, from: organizationType))
    }

    var planTier: String? {
        UsageReaderShared.sanitizedPlanToken(Self.stripping(Self.tierPrefix, from: rateLimitTier))
    }

    /// `organizationType` prefixes the plan the CLI displays: `claude_max`
    /// against the bare `max` its own label switch takes. Verified against
    /// 2.1.267, whose enumeration is exactly pro / max / team / enterprise.
    static let planPrefix = "claude_"

    /// `rateLimitTier` prefixes the tier the same way: `default_claude_max_5x`
    /// for the account on the plan Anthropic now sells as Max. Only the two
    /// `max` multipliers appear in 2.1.267, which is why the tier is treated as
    /// a decoration on the plan and never as the plan itself.
    static let tierPrefix = "default_claude_"

    /// The owner's name off whichever block a source carries it on.
    ///
    /// Two keys because the vendor publishes two: measured 2026-09-16,
    /// `api/oauth/profile` answers `account.full_name` *and*
    /// `account.display_name`. The full name leads — it is what the account was
    /// registered as, where the display name is what it chose to be shown as
    /// and can be a handle.
    ///
    /// Shared by both parsers rather than written twice, which is also what
    /// keeps a key claude.ai turns out to spell differently a one-line fix
    /// instead of two. Through `sanitizedDisplayText` for the reason the
    /// organisation is: the panel prints it unguarded, and the value came out
    /// of a reply Sissy does not own.
    static func name(in account: [String: Any]) -> String? {
        for key in nameKeys {
            if let name = UsageReaderShared.sanitizedDisplayText(account[key] as? String) {
                return name
            }
        }
        return nil
    }

    private static let nameKeys = ["full_name", "display_name"]

    /// Shared with `ClaudeProfileSource`, which reads the same two tokens out
    /// of `.claude.json`: the OAuth profile and the CLI's config spell them
    /// identically, so one normaliser answers for both rather than two that
    /// can come to disagree about what a plan is called.
    static func stripping(_ prefix: String, from raw: String?) -> String? {
        guard let raw else { return nil }
        return raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw
    }
}

/// Resolves an access token to the account that owns it.
enum ClaudeAccountProfile {
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    private static let requestTimeout: TimeInterval = 10

    /// The seat, on the organisation beside the plan and the tier. claude.ai
    /// puts the same token on the membership instead, which is why the two
    /// parsers read it from different places and record the same answer.
    private static let seatKey = "seat_tier"

    static func resolve(token: String) async throws -> ClaudeAccountIdentity {
        let request = ClaudeResetGrants.request(
            profileURL, token: token, userAgent: nil, timeout: requestTimeout)
        return try parse(await UsageRequestError.object(answering: request))
    }

    /// Pure, so the shape of the vendor's reply is testable without the
    /// network — and so a field they rename costs a nil rather than a throw.
    static func parse(_ payload: [String: Any]) throws -> ClaudeAccountIdentity {
        let account = payload["account"] as? [String: Any]
        guard let uuid = account?["uuid"] as? String, !uuid.isEmpty else {
            throw UsageRequestError.malformedPayload
        }
        let organization = payload["organization"] as? [String: Any]
        return ClaudeAccountIdentity(
            uuid: uuid,
            email: account?["email"] as? String,
            name: account.flatMap(ClaudeAccountIdentity.name(in:)),
            organization: organization?["name"] as? String,
            organizationType: organization?["organization_type"] as? String,
            rateLimitTier: organization?["rate_limit_tier"] as? String,
            seat: UsageReaderShared.sanitizedPlanToken(organization?[seatKey] as? String),
            organizationUUID: organization?["uuid"] as? String,
            planName: UsageReaderShared.sanitizedDisplayText(
                organization?["plan_display_name"] as? String)
        )
    }
}

/// Every Claude Code account Sissy has seen signed in, by name.
///
/// The CLI's own keychain slots hold whichever account is active, so they
/// cannot say which others exist. This index can, and it holds identities only:
/// no token and no copy of a credential, here or in the keychain.
///
/// An index written while Sissy still kept credentials also holds refresh
/// expiries and token hashes. They decode as nothing and the next save drops
/// them.
struct ClaudeAccountStore: Sendable {
    /// Where the identities are listed.
    let indexURL: URL

    /// What the index holds: who Sissy knows about, and who it last saw
    /// active. The active id is a note, not a claim: the CLI's credential is
    /// what decides, and `ClaudeAccountRegistry` reads it.
    struct Index: Sendable, Codable, Equatable {
        var accounts: [ClaudeAccountIdentity] = []
        var activeUUID: String?
    }

    static let indexFileName = "claude-accounts.json"
    /// What an index that would not decode is renamed to, with a timestamp
    /// after it so a second one never replaces the first.
    static let setAsidePrefix = "claude-accounts.unreadable-"

    static func defaultURL(in parent: URL) -> URL {
        parent.appendingPathComponent(indexFileName)
    }

    /// The index, empty when there is none yet.
    ///
    /// Throws for a file that is there and will not read. That used to come
    /// back as an empty index, and the next `remember` wrote over it. Every
    /// write here follows a load that succeeded, so a file this refuses is
    /// never overwritten. An empty file is refused too: `saveIndex` writes
    /// atomically and never leaves one, so a file with no bytes is one
    /// something truncated.
    func loadIndex() throws -> Index {
        try file.load() ?? Index()
    }

    /// The index, with one that does not decode moved out of the way first.
    ///
    /// Renamed rather than deleted: a person can still read it. **Only a file
    /// that read and did not decode is moved**, because one whose read failed
    /// may be a sound index behind a lock or a permission. That, and a file
    /// that could not be moved, throw.
    func loadIndexSettingAside(now: Date = Date()) throws -> Index {
        try file.loadSettingAside(named: "the Claude account index", now: now) ?? Index()
    }

    /// Whether an index has ever been set aside beside this one.
    func hasSetAsideIndex() -> Bool {
        file.hasSetAside()
    }

    func saveIndex(_ index: Index) throws {
        try file.save(index)
    }

    private var file: VersionedJSONFile<Index> {
        VersionedJSONFile(
            url: indexURL, policy: .refuse, setAsidePrefix: Self.setAsidePrefix,
            formatting: [.prettyPrinted, .sortedKeys])
    }

    /// Records an identity, replacing what was known about that account.
    ///
    /// Called whenever the active credential turns out to be new: a `/login`
    /// or the CLI rotating a token.
    func remember(_ identity: ClaudeAccountIdentity) throws {
        var index = try loadIndex()
        if let existing = index.accounts.firstIndex(where: { $0.uuid == identity.uuid }) {
            index.accounts[existing] = identity
        } else {
            index.accounts.append(identity)
        }
        try saveIndex(index)
    }
}

/// Resolves a claude.ai session to the account that owns it.
///
/// Deliberately the same `ClaudeAccountIdentity` `ClaudeAccountProfile`
/// produces from the OAuth endpoint, because measured 2026-09-16 the two
/// vendors' endpoints name one account with one id: `api/oauth/profile` and
/// `claude.ai/api/account` both answered the same uuid for one person. So a
/// session and a CLI credential file under one key and the account list is one
/// list, rather than two that have to be reconciled by email address.
///
/// Four of the five fields map exactly — the uuid, the address, the
/// organisation's name and its plan, whose token is character-for-character
/// the one `.claude.json` puts in `organizationType`, so one formatter words
/// both. The fifth does not and is left nil rather than guessed: claude.ai
/// reports the organisation's `rate_limit_tier` (`default_raven`) where the
/// OAuth profile reports the seat's (`default_claude_max_5x`): measured
/// 2026-11-04, one `.claude.json` block holds both, under
/// `organizationRateLimitTier` and `userRateLimitTier`. It is also not trusted
/// for the plan's size: the same day a link's token read `claude_max 5x` for
/// an account the OAuth profile puts at `default_claude_max_20x`. That token
/// fails `sanitizedPlanToken`, so such an account has no badge from this
/// source, a missing decoration rather than a wrong plan.
///
/// The seat is the sixth and it maps too, from a different place: claude.ai
/// puts `seat_tier` on the *membership* where the OAuth profile puts it on the
/// organisation. Measured 2026-09-16, both answered `team_tier_1` for one
/// account. So the membership is picked before the organisation is taken off
/// it — reading the organisations alone cannot say which seat belongs to the
/// one chosen, and an account holding two would badge the wrong plan's.
///
/// Fetching belongs beside the session, in `ClaudeWebSource`, which is what
/// keeps the cookie leaving this module through paths that file owns.
enum ClaudeWebAccountProfile {
    /// The identity a session answers for.
    ///
    /// claude.ai's own status travels out rather than being flattened: a 401
    /// is a session that has ended and will answer no better tomorrow, where a
    /// timeout is a machine that was offline for a moment. A caller that
    /// cannot tell them apart retries the first forever and says nothing about
    /// why, which is what the log line off this is for.
    static func resolve(session: String) async throws -> ClaudeAccountIdentity {
        try parse(await ClaudeWebSource.account(session: session))
    }

    private static let idKey = "uuid"
    private static let emailKey = "email_address"
    private static let membershipsKey = "memberships"
    private static let organizationKey = "organization"
    private static let organizationNameKey = "name"
    /// The plan, under the name claude.ai gives it. Measured to carry the
    /// identical token `.claude.json` puts in `organizationType` for a Team
    /// account, and not for a Max one (see above).
    private static let planKey = "analytics_subscription_plan"
    /// On the membership here, on the organisation in the OAuth profile.
    private static let seatKey = "seat_tier"

    /// Pure, so the shape of the reply is testable without claude.ai — and so
    /// a field they rename costs a nil rather than a throw, on the same rule
    /// `ClaudeAccountProfile.parse` follows. The id is the exception: it is the
    /// key the session would be filed under, and there is nothing to file
    /// without one.
    ///
    /// The organisation is picked by capability and by nothing else. An
    /// account that holds no `chat` organisation is on no chat plan, so it
    /// answers no organisation and no plan rather than borrowing the first
    /// membership listed — the measured account's other organisation reports
    /// `api_individual`, which would badge a subscription with an API tier
    /// nobody is on. `ClaudeWebSource` falls back to the first for the same
    /// payload, and should: there the fallback buys a usage reading that is
    /// otherwise impossible, where here the identity is already complete from
    /// the uuid and the fallback would buy only a label that can be wrong.
    /// Membership order is the server's, so it could also differ between two
    /// polls of one account.
    static func parse(_ payload: [String: Any]) throws -> ClaudeAccountIdentity {
        guard let uuid = payload[idKey] as? String, !uuid.isEmpty else {
            throw UsageRequestError.malformedPayload
        }
        let membership = subscriptionMembership(in: payload)
        let organization = membership?[organizationKey] as? [String: Any]
        return ClaudeAccountIdentity(
            uuid: uuid,
            email: payload[emailKey] as? String,
            name: ClaudeAccountIdentity.name(in: payload),
            organization: organization?[organizationNameKey] as? String,
            organizationType: organization?[planKey] as? String,
            rateLimitTier: nil,
            seat: UsageReaderShared.sanitizedPlanToken(membership?[seatKey] as? String)
        )
    }

    /// The membership rather than the organisation off it, because the seat is
    /// the membership's: an account holding two would otherwise take the
    /// subscription's name and the other one's seat.
    private static func subscriptionMembership(in payload: [String: Any]) -> [String: Any]? {
        let memberships = (payload[membershipsKey] as? [Any] ?? [])
            .compactMap { $0 as? [String: Any] }
        let organizations = memberships.compactMap { $0[organizationKey] as? [String: Any] }
        guard let chosen = ClaudeWebSource.subscriptionOrganization(among: organizations),
            let uuid = chosen[idKey] as? String
        else { return nil }
        return memberships.first {
            ($0[organizationKey] as? [String: Any])?[idKey] as? String == uuid
        }
    }
}
