import Foundation

/// Who an OAuth credential belongs to.
///
/// The credential blob itself names a subscription and a tier but no account,
/// so the only thing that can tell two sign-ins apart is the vendor's own
/// answer. Everything here is a display string read back from Anthropic for a
/// token the user already holds.
struct ClaudeAccountIdentity: Sendable, Codable, Equatable, Identifiable {
    /// Anthropic's own account id, which is what one stored credential is
    /// filed under: it survives an email change and a re-login where nothing
    /// else does.
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

    init(
        uuid: String,
        email: String?,
        name: String? = nil,
        organization: String?,
        organizationType: String?,
        rateLimitTier: String?,
        seat: String? = nil
    ) {
        self.uuid = uuid
        self.email = email
        self.name = name
        self.organization = organization
        self.organizationType = organizationType
        self.rateLimitTier = rateLimitTier
        self.seat = seat
    }

    var id: String { uuid }

    /// The account as a row carries it.
    var providerAccount: ProviderAccount? {
        ProviderAccount(email: email, organization: organization, seat: seat)
    }

    /// The plan and its tier in the vocabulary the frame carries: `team`
    /// rather than `claude_team`, `max_5x` rather than `default_claude_max_5x`.
    ///
    /// `UsageFormat` derives its words from the token rather than mapping it,
    /// so a prefixed one does not render a little wrong — it renders as a
    /// different plan. `words("claude_team")` is "Claude Team", and
    /// `tierParts("default_claude_max_5x")` splits a base that matches no
    /// plan, which put "Claude Team" and "Default Claude Max 5x" on the rows
    /// of every archived account.
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
    /// for the account metered at Max 5x. Only the two `max` multipliers
    /// appear in 2.1.267, which is why the tier is treated as a decoration on
    /// the plan and never as the plan itself.
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
    private static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    private static let betaHeader = "oauth-2025-04-20"
    private static let requestTimeout: TimeInterval = 10

    enum Failure: Error, Equatable {
        case badStatus(Int)
        /// Named rather than folded into a status, because it is the one
        /// failure that says "ask again later" in so many words.
        case rateLimited
        case malformedPayload
    }

    /// The seat, on the organisation beside the plan and the tier. claude.ai
    /// puts the same token on the membership instead, which is why the two
    /// parsers read it from different places and record the same answer.
    private static let seatKey = "seat_tier"

    static func resolve(token: String) async throws -> ClaudeAccountIdentity {
        var request = URLRequest(url: profileURL, timeoutInterval: requestTimeout)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.malformedPayload }
        guard http.statusCode == 200 else { throw Failure.badStatus(http.statusCode) }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.malformedPayload
        }
        return try parse(payload)
    }

    /// Pure, so the shape of the vendor's reply is testable without the
    /// network — and so a field they rename costs a nil rather than a throw.
    static func parse(_ payload: [String: Any]) throws -> ClaudeAccountIdentity {
        let account = payload["account"] as? [String: Any]
        guard let uuid = account?["uuid"] as? String, !uuid.isEmpty else {
            throw Failure.malformedPayload
        }
        let organization = payload["organization"] as? [String: Any]
        return ClaudeAccountIdentity(
            uuid: uuid,
            email: account?["email"] as? String,
            name: account.flatMap(ClaudeAccountIdentity.name(in:)),
            organization: organization?["name"] as? String,
            organizationType: organization?["organization_type"] as? String,
            rateLimitTier: organization?["rate_limit_tier"] as? String,
            seat: UsageReaderShared.sanitizedPlanToken(organization?[seatKey] as? String)
        )
    }
}

/// Every Claude Code account Sissy has seen signed in, and the credential each
/// one was last seen with.
///
/// This is the one place a Claude credential lives durably, and it exists
/// because the CLI's own keychain slots are **scratch**: the unscoped item and
/// each `Claude Code-credentials-<hash>` hold whichever account is active, and
/// the CLI rewrites them with a rotated token every time it refreshes.
/// Measured 2026-09-15: switching the active account and letting the CLI
/// refresh once destroyed the previous account's only copy, and Anthropic's
/// refresh tokens rotate on use, so it could not be recovered from anywhere on
/// the machine. An account switch is therefore only safe when Sissy holds the
/// archive and treats the CLI's slots as somewhere to write.
///
/// The secrets sit in the login keychain under Sissy's own service, addressed
/// through `ClaudeKeychainCLI` for the same reason as everything else here: no
/// dialog and no grant that a re-signed build invalidates. The index beside
/// them is identities only — never a token — so the list of accounts survives
/// without a secret ever touching Sissy's own directory.
struct ClaudeAccountStore: Sendable {
    /// The secret half, behind three closures.
    ///
    /// Injected rather than called directly so the archive can be exercised
    /// without a login keychain: writing a real credential is the one piece of
    /// external I/O here, and a test of what the store *decides* must not
    /// depend on it.
    struct Secrets: Sendable {
        var read: @Sendable (String) -> Data?
        var write: @Sendable (String, Data) throws -> Void

        static let keychain = Self(
            read: { uuid in
                try? ClaudeKeychainCLI.read(
                    service: ClaudeKeychainCLI.sissyAccountService, account: uuid)
            },
            write: { uuid, data in
                try ClaudeKeychainCLI.write(
                    data, service: ClaudeKeychainCLI.sissyAccountService, account: uuid)
            })
    }

    /// Where the identities are listed. Secrets are never in here.
    let indexURL: URL
    var secrets: Secrets = .keychain

    /// What the index holds: who Sissy knows about, and who it last saw
    /// active. The active id is a note, not a claim — the keychain is what
    /// decides, and `ClaudeAccountRegistry` reconciles the two.
    struct Index: Sendable, Codable, Equatable {
        var accounts: [ClaudeAccountIdentity] = []
        var activeUUID: String?
    }

    static let indexFileName = "claude-accounts.json"

    static func defaultURL(in parent: URL) -> URL {
        parent.appendingPathComponent(indexFileName)
    }

    func loadIndex() -> Index {
        guard let data = try? Data(contentsOf: indexURL),
            let decoded = try? JSONDecoder().decode(Index.self, from: data)
        else { return Index() }
        return decoded
    }

    func saveIndex(_ index: Index) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(index).write(to: indexURL, options: .atomic)
    }

    /// The credential archived for one account, or nil when none is.
    func credential(uuid: String) -> Data? { secrets.read(uuid) }

    /// Archives a credential under its account and records the identity.
    ///
    /// Called whenever the active credential turns out to be new — a switch,
    /// a `/login`, or the CLI rotating a token — so the archive tracks the
    /// live one instead of going stale behind it.
    func remember(_ identity: ClaudeAccountIdentity, credential: Data) throws {
        try secrets.write(identity.uuid, credential)
        var index = loadIndex()
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
/// `claude.ai/api/account` both answered `c805523f…` for the same person. So a
/// session and a CLI credential file under one key and the account list is one
/// list, rather than two that have to be reconciled by email address.
///
/// Four of the five fields map exactly — the uuid, the address, the
/// organisation's name and its plan, whose token is character-for-character
/// the one `.claude.json` puts in `organizationType`, so one formatter words
/// both. The fifth does not and is left nil rather than guessed: claude.ai
/// reports `rate_limit_tier` in a taxonomy of its own (`default_raven`) where
/// the OAuth profile reports `default_claude_max_5x`. Two vocabularies, so a
/// Max account reads "Max" here and "Max 5x" there — a missing decoration
/// rather than a wrong reading.
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
        do {
            return try parse(await ClaudeWebSource.account(session: session))
        } catch let failure as ClaudeLimitsError {
            switch failure {
            case .badStatus(let code): throw ClaudeAccountProfile.Failure.badStatus(code)
            case .rateLimited: throw ClaudeAccountProfile.Failure.rateLimited
            case .malformedPayload: throw ClaudeAccountProfile.Failure.malformedPayload
            }
        }
    }

    private static let idKey = "uuid"
    private static let emailKey = "email_address"
    private static let membershipsKey = "memberships"
    private static let organizationKey = "organization"
    private static let organizationNameKey = "name"
    /// The plan, under the name claude.ai gives it. Measured to carry the
    /// identical token `.claude.json` puts in `organizationType`.
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
            throw ClaudeAccountProfile.Failure.malformedPayload
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
