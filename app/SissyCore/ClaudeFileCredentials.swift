import Foundation

/// Claude Code's OAuth credential as it sits in an account's own config home.
///
/// This is the only per-account source for the live usage endpoint. The login
/// keychain holds one item for the whole machine, so it answers for whichever
/// account the CLI is signed into and cannot be asked about a second one; a
/// claude.ai cookie belongs to whichever account Claude.app happens to hold,
/// which is one at a time by construction. The file is inside
/// `CLAUDE_CONFIG_DIR`, so an account that has its own home has its own copy —
/// measured against 2.1.272, whose credential path is the config home plus
/// `.credentials.json`.
///
/// Reading it raises no dialog and needs no grant, which is why every caller
/// here ignores `allowingInteraction`: there is nothing for macOS to
/// authorize. A token this returns is still the CLI's, never Sissy's — Sissy
/// does not refresh it and never writes the file, on the same grounds
/// `ClaudeCredentials` documents: Anthropic's refresh tokens rotate on use, so
/// spending one would sign the user out of their own terminal.
enum ClaudeFileCredentials {
    private static let oauthKey = "claudeAiOauth"
    private static let tokenKey = "accessToken"
    private static let expiryKey = "expiresAt"

    /// The credential filed for one account, or why there is none.
    ///
    /// `ClaudeCredentialsLookup` rather than a type of its own so the limits
    /// probe takes this source and the keychain one without knowing which it
    /// got. A file that is not there is `.absent` — an account whose CLI has
    /// never signed in — and one that will not parse is `.unreadable`, which
    /// leaves the last good reading alone instead of claiming a signed-out
    /// account.
    static func load(at url: URL) -> ClaudeCredentialsLookup {
        guard let data = try? Data(contentsOf: url) else { return .absent }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root[oauthKey] as? [String: Any],
            let token = oauth[tokenKey] as? String,
            !token.isEmpty
        else {
            return .unreadable(OSStatus(errSecDecode))
        }
        return .found(
            ClaudeCredentials(accessToken: token, expiresAt: expiry(oauth[expiryKey])))
    }

    /// Whether an account has a credential at all, asked without reading it.
    /// Settings uses it to tell an account whose CLI has never been signed in
    /// from one whose token has simply gone stale.
    static func isPresent(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Claude Code writes the expiry in milliseconds. The bound is the same
    /// one `ClaudeCredentialsStore` applies to the keychain copy, so the two
    /// sources cannot disagree about what a number means.
    private static func expiry(_ raw: Any?) -> Date? {
        guard let seconds = (raw as? Double) ?? (raw as? NSNumber)?.doubleValue else { return nil }
        let scaled = seconds > ClaudeCredentialsStore.secondsUpperBound ? seconds / 1000 : seconds
        return Date(timeIntervalSince1970: scaled)
    }
}
