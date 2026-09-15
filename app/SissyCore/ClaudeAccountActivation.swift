import CryptoKit
import Foundation
import Security

/// Which account Claude Code starts as, and changing it.
///
/// This is the one thing in Sissy that writes a credential, and it is a
/// deliberate exception to the rule that nothing Sissy does to the machine
/// outlives it: the whole point of switching an account is that the next
/// `claude` in a terminal Sissy never sees starts as the account the user
/// picked. It happens only on that click, never on a poll, a launch or a
/// refresh.
///
/// Claude Code 2.1+ scopes its keychain item by config directory:
/// `Claude Code-credentials-<first 8 hex of sha256(NFC(dir))>`, with the
/// unsuffixed `Claude Code-credentials` serving a CLI started with no
/// `CLAUDE_CONFIG_DIR`. Verified 2026-09-15 against the two homes on one Mac —
/// `~/.claude` hashes to `8a380954` and `~/.claude-mastersoft` to `a8264a74`,
/// and both items exist under exactly those names.
enum ClaudeAccountActivation {
    /// Service name Claude Code files the unscoped credential under, which is
    /// what a CLI started without `CLAUDE_CONFIG_DIR` reads.
    static let activeService = "Claude Code-credentials"
    /// Hex characters of the digest the CLI keeps. Its own constant, not a
    /// tuning knob: a different length addresses a different item.
    private static let suffixLength = 8
    /// Account the CLI files its item under, and the fallback it uses when the
    /// login name carries characters it will not accept.
    private static let accountPattern = try? NSRegularExpression(pattern: "^[a-zA-Z0-9._-]+$")
    private static let fallbackAccount = "claude-code-user"

    /// Why an activation could not happen. Each is a different sentence to the
    /// user: one is an account that has never signed in, the others are macOS
    /// declining, which only the user can resolve.
    enum Failure: Error, Equatable {
        /// No credential is filed for that home.
        case noCredential
        /// The keychain refused the read or the write. Carries the status so a
        /// refusal can be told from an absence.
        case keychain(OSStatus)
    }

    /// The keychain service one config home's credential is filed under.
    ///
    /// The default home is the exception the CLI itself makes: a session
    /// started with no `CLAUDE_CONFIG_DIR` reads the unsuffixed item, so that
    /// is the name for it rather than the hash of its path.
    static func service(for home: URL) -> String {
        guard home != AccountDefaults.claudeHome else { return activeService }
        return scopedService(for: home.path)
    }

    /// The scoped name for a directory path, by the CLI's own rule.
    static func scopedService(for path: String) -> String {
        let digest = SHA256.hash(data: Data(path.precomposedStringWithCanonicalMapping.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(activeService)-\(hex.prefix(suffixLength))"
    }

    /// Makes `home`'s account the one Claude Code starts as.
    ///
    /// Read then write, both against items Claude Code owns, so macOS may ask
    /// the user to allow each. That is correct here and nowhere else: this runs
    /// from a click that asked for exactly this, which is the rule every other
    /// keychain path in Sissy exists to honour from the other side.
    ///
    /// Only the unscoped item is written. The account's own scoped item is
    /// where the credential was just read from, so writing it back would
    /// rewrite a secret to the value it already holds — and a terminal pinned
    /// to that home with `CLAUDE_CONFIG_DIR` was already reading it.
    static func activate(home: URL) throws {
        let credentials = try read(service: service(for: home))
        try write(credentials, service: activeService)
    }

    /// Whether a credential is filed for this home, asked without reading it.
    ///
    /// Attributes only, deliberately: the keychain authorizes a read of the
    /// *secret*, so asking whether the item exists costs no ACL check and
    /// cannot raise a dialog. It is what lets the panel offer an account
    /// without prompting for one nobody has chosen yet.
    static func isPresent(home: URL) -> Bool {
        var query = identity(service: service(for: home))
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private static func read(service: String) throws -> Data {
        var query = identity(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { throw Failure.noCredential }
        guard status == errSecSuccess, let data = item as? Data else {
            throw Failure.keychain(status)
        }
        return data
    }

    /// Add-then-update rather than delete-then-add: a delete that succeeds
    /// followed by an add that fails would leave the user signed out of a CLI
    /// they only asked to switch.
    private static func write(_ data: Data, service: String) throws {
        var attributes = identity(service: service)
        attributes[kSecValueData as String] = data
        let added = SecItemAdd(attributes as CFDictionary, nil)
        if added == errSecSuccess { return }
        guard added == errSecDuplicateItem else { throw Failure.keychain(added) }
        let updated = SecItemUpdate(
            identity(service: service) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        guard updated == errSecSuccess else { throw Failure.keychain(updated) }
    }

    private static func identity(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount(),
        ]
    }

    /// The account name the CLI files under.
    ///
    /// Claude Code 2.1+ refuses a login name outside `[a-zA-Z0-9._-]` — an SSO
    /// address, say — and stores the item under a fixed name instead, so
    /// addressing the item by `$USER` alone would miss it on exactly those
    /// machines.
    static func keychainAccount(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let user = environment["USER"] ?? environment["USERNAME"] ?? NSUserName()
        let range = NSRange(user.startIndex..., in: user)
        guard let accountPattern,
            accountPattern.firstMatch(in: user, range: range) != nil
        else { return fallbackAccount }
        return user
    }
}
