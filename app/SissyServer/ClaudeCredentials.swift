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
    /// Giving up cannot be expressed as a race between two children of a task
    /// group: a group awaits every child before it returns, and a child parked
    /// on a continuation does not observe cancellation, so the timeout would
    /// only ever report a wait it had already served in full. The lookup
    /// therefore runs outside structured concurrency and the gate below
    /// delivers whichever outcome arrives first.
    ///
    /// A lookup that outlived its budget is still running, so the next call
    /// answers `.timedOut` rather than parking a second dispatch thread on the
    /// same query; the slot reopens when the abandoned one returns, and its
    /// result is discarded.
    ///
    /// `lookup` exists so the abandonment can be tested without a keychain:
    /// the blocking call is the one piece of external I/O here, and nothing
    /// else in this path can stand in for a dialog nobody answers.
    static func loadOffPool(
        timeout: Duration,
        lookup: @Sendable @escaping () -> ClaudeCredentialsLookup = { load() }
    ) async -> ClaudeCredentialsLookup {
        guard gate.claim() else { return .timedOut }
        DispatchQueue.global(qos: .utility).async { gate.finish(lookup()) }
        let deadline = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            gate.giveUp()
        }
        defer { deadline.cancel() }
        return await gate.wait()
    }

    private static let gate = KeychainLookupGate()

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

/// One-shot handoff between a blocking keychain lookup and the caller waiting
/// on it, plus the single in-flight slot that keeps an abandoned lookup from
/// being duplicated.
///
/// `finish` and `giveUp` are both safe to call in either order and after the
/// caller has left: whichever lands first resumes the waiter, and the other
/// is dropped.
private final class KeychainLookupGate: @unchecked Sendable {
    private let lock = NSLock()
    private var outstanding = false
    private var waiter: CheckedContinuation<ClaudeCredentialsLookup, Never>?
    private var undelivered: ClaudeCredentialsLookup?

    /// True when the caller now owns the only in-flight lookup.
    func claim() -> Bool {
        lock.withLock {
            if outstanding { return false }
            outstanding = true
            waiter = nil
            undelivered = nil
            return true
        }
    }

    func wait() async -> ClaudeCredentialsLookup {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let ready = undelivered {
                undelivered = nil
                lock.unlock()
                continuation.resume(returning: ready)
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }

    /// The lookup returned. Frees the slot, and hands the value over if the
    /// caller is still waiting for it.
    func finish(_ value: ClaudeCredentialsLookup) {
        lock.lock()
        outstanding = false
        let pending = waiter
        waiter = nil
        if pending == nil { undelivered = value }
        lock.unlock()
        pending?.resume(returning: value)
    }

    /// The budget ran out. The slot stays taken because the lookup itself is
    /// still parked in the Security framework.
    func giveUp() {
        lock.lock()
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(returning: .timedOut)
    }
}
