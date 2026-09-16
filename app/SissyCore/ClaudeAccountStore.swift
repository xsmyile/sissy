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
    let organization: String?
    /// `claude_team`, `claude_max`… as the vendor spells it. Worded by
    /// `UsageFormat`, never here.
    let organizationType: String?
    let rateLimitTier: String?

    var id: String { uuid }
}

/// Resolves an access token to the account that owns it.
enum ClaudeAccountProfile {
    private static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    private static let betaHeader = "oauth-2025-04-20"
    private static let requestTimeout: TimeInterval = 10

    enum Failure: Error, Equatable {
        case badStatus(Int)
        case malformedPayload
    }

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
            organization: organization?["name"] as? String,
            organizationType: organization?["organization_type"] as? String,
            rateLimitTier: organization?["rate_limit_tier"] as? String
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
        var delete: @Sendable (String) throws -> Void

        static let keychain = Self(
            read: { uuid in
                try? ClaudeKeychainCLI.read(
                    service: ClaudeKeychainCLI.sissyAccountService, account: uuid)
            },
            write: { uuid, data in
                try ClaudeKeychainCLI.write(
                    data, service: ClaudeKeychainCLI.sissyAccountService, account: uuid)
            },
            delete: { uuid in
                try ClaudeKeychainCLI.delete(
                    service: ClaudeKeychainCLI.sissyAccountService, account: uuid)
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

    /// Drops an account's credential and its entry. The user asking for a
    /// stored secret to be gone is the only caller.
    func forget(uuid: String) throws {
        try secrets.delete(uuid)
        var index = loadIndex()
        index.accounts.removeAll { $0.uuid == uuid }
        if index.activeUUID == uuid { index.activeUUID = nil }
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
/// The seat is a sixth thing claude.ai answers for (`seat_tier`, measured to
/// equal the CLI's) and this type carries no field for it, so a Team account
/// resolved from a session is badged "Team" where the CLI badges it "Team
/// Premium". That is the consumer's question rather than the parser's, and it
/// is settled where the seat is actually read.
///
/// Fetching belongs beside the session, in `ClaudeWebSource`, which is what
/// keeps the cookie leaving this module through paths that file owns.
enum ClaudeWebAccountProfile {
    /// The identity a session answers for, or a throw this layer cannot act
    /// on. Both halves of the failure mean the same thing to a caller — the
    /// session did not name an account — so the network error is mapped into
    /// this type's own rather than propagated as claude.ai's.
    static func resolve(session: String) async throws -> ClaudeAccountIdentity {
        let payload: [String: Any]
        do {
            payload = try await ClaudeWebSource.account(session: session)
        } catch {
            throw ClaudeAccountProfile.Failure.malformedPayload
        }
        return try parse(payload)
    }

    private static let idKey = "uuid"
    private static let emailKey = "email_address"
    private static let membershipsKey = "memberships"
    private static let organizationKey = "organization"
    private static let organizationNameKey = "name"
    /// The plan, under the name claude.ai gives it. Measured to carry the
    /// identical token `.claude.json` puts in `organizationType`.
    private static let planKey = "analytics_subscription_plan"

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
        let organization = subscriptionOrganization(in: payload)
        return ClaudeAccountIdentity(
            uuid: uuid,
            email: payload[emailKey] as? String,
            organization: organization?[organizationNameKey] as? String,
            organizationType: organization?[planKey] as? String,
            rateLimitTier: nil
        )
    }

    private static func subscriptionOrganization(in payload: [String: Any]) -> [String: Any]? {
        let memberships = (payload[membershipsKey] as? [Any] ?? [])
            .compactMap { $0 as? [String: Any] }
            .compactMap { $0[organizationKey] as? [String: Any] }
        return ClaudeWebSource.subscriptionOrganization(among: memberships)
    }
}
