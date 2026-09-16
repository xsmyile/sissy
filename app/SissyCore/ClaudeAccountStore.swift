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
