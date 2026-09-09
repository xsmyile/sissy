import Foundation
import Security

/// Read-only view of the OAuth credentials Claude Code keeps in the login
/// keychain.
///
/// Sissy never writes them and never performs a refresh. Anthropic's refresh
/// tokens rotate on use, so spending one here would invalidate the copy the
/// CLI holds and sign the user out of their own terminal. An expired access
/// token is simply skipped until the CLI renews it.
struct ClaudeCredentials: Sendable {
    let accessToken: String
    let expiresAt: Date

    func isValid(at moment: Date = Date()) -> Bool { expiresAt > moment }
}

/// Outcome of a keychain lookup. Absence and refusal are different states:
/// the first is a user who has not signed into Claude Code, the second is a
/// user who said no, and re-asking them on a timer would be harassment.
enum ClaudeCredentialsLookup: Sendable {
    case found(ClaudeCredentials)
    case absent
    case denied
    case unreadable(OSStatus)
    /// The lookup outlived its budget. `SecItemCopyMatching` blocks while
    /// macOS decides whether to authorize, and that decision can wait on a
    /// dialog nobody answers — or, from a process with no way to show one,
    /// never resolve at all.
    case timedOut
}

enum ClaudeCredentialsStore {
    /// Service name Claude Code writes under. The account is the macOS user,
    /// but the query deliberately omits it so a keychain written by a
    /// differently-named login still matches.
    static let keychainService = "Claude Code-credentials"

    /// Epoch values above this many seconds cannot be a plausible date, so
    /// they are milliseconds. Claude Code writes `expiresAt` in ms; the guard
    /// keeps the parse correct if that ever changes.
    private static let secondsUpperBound: Double = 4_102_444_800

    /// `SecItemCopyMatching` blocks for as long as macOS takes to authorize,
    /// which is unbounded: it can sit behind a dialog nobody answers. The call
    /// runs off the cooperative pool so it parks a dispatch thread rather than
    /// one the whole runtime shares, and the caller gives up after `timeout`
    /// instead of leaving a poll loop stopped forever with nothing logged.
    ///
    /// The abandoned lookup is left to finish on its own; its result is
    /// discarded rather than resumed into a continuation nobody holds.
    static func loadOffPool(timeout: Duration) async -> ClaudeCredentialsLookup {
        await withTaskGroup(of: ClaudeCredentialsLookup?.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        continuation.resume(returning: load())
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .timedOut
        }
    }

    static func load() -> ClaudeCredentialsLookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let parsed = parse(data) else {
                return .unreadable(errSecDecode)
            }
            return .found(parsed)
        case errSecItemNotFound:
            return .absent
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return .denied
        default:
            return .unreadable(status)
        }
    }

    static func parse(_ data: Data) -> ClaudeCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            !token.isEmpty,
            let rawExpiry = oauth["expiresAt"] as? Double
        else { return nil }

        let seconds = rawExpiry > secondsUpperBound ? rawExpiry / 1000 : rawExpiry
        return ClaudeCredentials(
            accessToken: token,
            expiresAt: Date(timeIntervalSince1970: seconds)
        )
    }
}
