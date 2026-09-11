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
    /// One lookup runs at a time and every caller waits on that one, each
    /// under its own budget. A caller arriving while an abandoned lookup is
    /// still parked therefore starts no second one — that would queue a second
    /// dispatch thread behind the same dialog without asking a different
    /// question — and is not answered `.timedOut` on the spot either: it is
    /// served the moment the dialog is. Only the lookup returning reopens the
    /// slot, because only that proves the query is no longer parked in the
    /// Security framework.
    ///
    /// `lookup` exists so the abandonment can be tested without a keychain:
    /// the blocking call is the one piece of external I/O here, and nothing
    /// else in this path can stand in for a dialog nobody answers.
    static func loadOffPool(
        timeout: Duration,
        lookup: @Sendable @escaping () -> ClaudeCredentialsLookup = { load() }
    ) async -> ClaudeCredentialsLookup {
        let id = UUID()
        var deadline: Task<Void, Never>?
        let outcome = await withCheckedContinuation { continuation in
            let mine = gate.join(id, continuation)
            // Armed before the lookup is dispatched and after the join, so it
            // can neither fire against an unregistered waiter nor be skipped
            // by an answer that lands first.
            deadline = Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                gate.giveUp(id)
            }
            if mine {
                DispatchQueue.global(qos: .utility).async { gate.finish(lookup()) }
            }
        }
        deadline?.cancel()
        return outcome
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

/// The single in-flight keychain lookup and everyone waiting on its answer.
///
/// One at a time is the whole point: `SecItemCopyMatching` behind a
/// user-presence prompt blocks until the dialog is answered, and a second call
/// would park a second dispatch thread behind that same dialog. The waiters
/// are independent of it — each leaves on its own budget, and whoever is still
/// there when the lookup returns is served.
final class KeychainLookupGate: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = false
    private var waiters: [UUID: CheckedContinuation<ClaudeCredentialsLookup, Never>] = [:]

    /// Registers `id` as a waiter and reports whether this caller is the one
    /// that has to run the lookup.
    func join(
        _ id: UUID,
        _ continuation: CheckedContinuation<ClaudeCredentialsLookup, Never>
    ) -> Bool {
        lock.withLock {
            waiters[id] = continuation
            if inFlight { return false }
            inFlight = true
            return true
        }
    }

    /// The lookup returned. Hands its answer to everyone still waiting and
    /// reopens the slot.
    func finish(_ value: ClaudeCredentialsLookup) {
        lock.lock()
        inFlight = false
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in pending.values { continuation.resume(returning: value) }
    }

    /// One caller's budget ran out. It leaves alone: the lookup stays in
    /// flight, and the waiters still under their own budget are served by it.
    func giveUp(_ id: UUID) {
        lock.lock()
        let abandoned = waiters.removeValue(forKey: id)
        lock.unlock()
        abandoned?.resume(returning: .timedOut)
    }
}
