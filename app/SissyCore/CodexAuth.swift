import Foundation

/// Reads the plan out of the id_token Codex keeps in `~/.codex/auth.json`.
///
/// The rollout stream is the fresher source — the CLI restamps `plan_type` on
/// every turn — but it only answers while there are unread bytes. A daemon
/// that resumed with its offsets at EOF has nothing left to re-read, which
/// left the Codex row with a plan the next turn would name and no badge until
/// then. This file answers at boot, before any turn, and the rollout
/// overwrites it the moment one lands.
///
/// The same file holds Codex's access and refresh tokens. They are never
/// logged, never persisted and never sent anywhere: the plan claim is the only
/// thing that leaves this type.
enum CodexAuthSource {
    private static let fileName = "auth.json"

    /// Namespace OpenAI puts its account claims under. Not a URL to fetch —
    /// a JWT claim key that happens to be spelled as one.
    private static let claimNamespace = "https://api.openai.com/auth"
    private static let planClaimKey = "chatgpt_plan_type"
    private static let jwtPartCount = 3
    private static let base64Alignment = 4

    /// `auth.json` sits beside the rollout tree in Codex's home, so the path
    /// is derived from the sessions dir the reader was given rather than from
    /// `$HOME`: that keeps `CODEX_HOME` and a custom `codexDataDir` pointing
    /// at the same install.
    static func defaultURL(sessionsDir: URL) -> URL {
        sessionsDir.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    static func loadPlan(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parsePlan(data)
    }

    static func parsePlan(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = root["tokens"] as? [String: Any],
            let idToken = tokens["id_token"] as? String
        else { return nil }
        return UsageReaderShared.sanitizedPlanToken(planClaim(inJWT: idToken))
    }

    /// Reads the plan claim out of a JWT's payload without verifying its
    /// signature. The token is the user's own local copy and the value taken
    /// from it is a display string, so the alternative is holding OpenAI's
    /// signing keys to learn a word Sissy also reads off the rollout stream.
    /// Anything malformed reads as "no plan".
    private static func planClaim(inJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == jwtPartCount,
            let payload = base64URLDecoded(String(parts[1])),
            let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let auth = claims[claimNamespace] as? [String: Any]
        else { return nil }
        return auth[planClaimKey] as? String
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
