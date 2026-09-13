import Foundation

/// Reads the plan out of the id_token Codex keeps in `~/.codex/auth.json`.
///
/// The rollout stream is the fresher source — the CLI restamps `plan_type` on
/// every turn — but it only answers while there are unread bytes. A reader
/// that resumed with its offsets at EOF has nothing left to re-read, which
/// left the Codex row with a plan the next turn would name and no badge until
/// then. This file answers at boot, before any turn, and the rollout
/// overwrites it the moment one lands.
///
/// The same file holds Codex's access and refresh tokens. They are never
/// logged, never persisted and never sent anywhere: the claims named below are
/// the only things that leave this type.
enum CodexAuthSource {
    private static let fileName = "auth.json"

    /// Namespace OpenAI puts its account claims under. Not a URL to fetch —
    /// a JWT claim key that happens to be spelled as one.
    private static let claimNamespace = "https://api.openai.com/auth"
    private static let planClaimKey = "chatgpt_plan_type"
    private static let renewalClaimKey = "chatgpt_subscription_active_until"
    private static let organizationsClaimKey = "organizations"
    private static let organizationTitleKey = "title"
    private static let organizationDefaultKey = "is_default"
    private static let emailClaimKey = "email"
    private static let jwtPartCount = 3
    private static let base64Alignment = 4

    /// Everything this file answers for: the plan Codex is on and who it is
    /// signed in as. Read in one pass because they come out of one token.
    struct Identity: Sendable, Equatable {
        let plan: String?
        let account: ProviderAccount?
    }

    /// `auth.json` sits beside the rollout tree in Codex's home, so the path
    /// is derived from the sessions dir the reader was given rather than from
    /// `$HOME`: that keeps `CODEX_HOME` and a custom `codexDataDir` pointing
    /// at the same install.
    static func defaultURL(sessionsDir: URL) -> URL {
        sessionsDir.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    static func load(at url: URL) -> Identity? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> Identity? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = root["tokens"] as? [String: Any],
            let idToken = tokens["id_token"] as? String,
            let claims = claims(inJWT: idToken)
        else { return nil }
        let auth = claims[claimNamespace] as? [String: Any] ?? [:]
        return Identity(
            plan: UsageReaderShared.sanitizedPlanToken(auth[planClaimKey] as? String),
            account: ProviderAccount(
                email: UsageReaderShared.sanitizedDisplayText(claims[emailClaimKey] as? String),
                organization: organization(in: auth),
                renewsAt: UsageReaderShared.parseTimestamp(auth[renewalClaimKey] as? String ?? "")
            )
        )
    }

    /// The account's default organisation, by the flag OpenAI sets on it. A
    /// payload naming several and flagging none answers nothing rather than
    /// picking the first: the order of that array is not a promise.
    private static func organization(in auth: [String: Any]) -> String? {
        guard let organizations = auth[organizationsClaimKey] as? [[String: Any]] else {
            return nil
        }
        let preferred = organizations.first { $0[organizationDefaultKey] as? Bool == true }
        return UsageReaderShared.sanitizedDisplayText(
            preferred?[organizationTitleKey] as? String)
    }

    /// Reads a JWT's payload without verifying its signature. The token is the
    /// user's own local copy and everything taken from it is a display string,
    /// so the alternative is holding OpenAI's signing keys to learn a word
    /// Sissy also reads off the rollout stream. Anything malformed reads as
    /// no identity at all.
    private static func claims(inJWT token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == jwtPartCount,
            let payload = base64URLDecoded(String(parts[1]))
        else { return nil }
        return try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
    }

    private static func base64URLDecoded(_ text: String) -> Data? {
        var encoded =
            text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (base64Alignment - encoded.count % base64Alignment) % base64Alignment
        encoded.append(String(repeating: "=", count: padding))
        return Data(base64Encoded: encoded)
    }
}
