import Foundation

/// Read-only view of the OAuth credentials Claude Code keeps in the login
/// keychain.
///
/// Sissy never writes them and never performs a refresh. Anthropic's refresh
/// tokens rotate on use, so spending one here would invalidate the copy the
/// CLI holds and sign the user out of their own terminal. An expired access
/// token is simply skipped until the CLI renews it.
struct ClaudeCredentials: Sendable, Equatable {
    let accessToken: String
    /// When the credential dies, for the source that says so.
    ///
    /// Nil for a claude.ai session: the cookie names an expiry in the store it
    /// was imported from, but the copy Sissy holds is a string and the
    /// endpoint's own 401 is the only thing that knows the session has ended.
    /// Treating an absent expiry as "not expired" keeps that 401 the single
    /// place a dead credential is handled, rather than a clock here and a
    /// status code there.
    let expiresAt: Date?

}

/// What a lookup of Claude Code's own credential found.
typealias ClaudeCredentialsLookup = CredentialLookup<ClaudeCredentials>

enum ClaudeCredentialsStore {
    /// Epoch values above this many seconds cannot be a plausible date, so
    /// they are milliseconds. Claude Code writes `expiresAt` in ms; the guard
    /// keeps the parse correct if that ever changes.
    ///
    /// Shared with `ClaudeCredentialBlob`, which parses the same field out of
    /// the copy the CLI keeps in its config home: two readers of one vendor's
    /// number must not disagree about its unit.
    static let secondsUpperBound: Double = 4_102_444_800

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
    /// `lookup` is the read itself, and it is required rather than defaulted.
    /// The default this had was an in-process `SecItemCopyMatching`, which is
    /// the one read on this path that can raise the legacy keychain's own
    /// panel — and nothing in the app took it, so it was a dialog waiting for
    /// the first caller that forgot to pass something. Naming the read at the
    /// call site is also what makes the abandonment testable without a
    /// keychain.
    ///
    /// One lookup at a time is a process-wide gate, so every caller must be
    /// asking the same question. That holds because there is one Claude config
    /// home and therefore one reader: a second home would need a gate per
    /// service, not this one.
    static func loadOffPool(
        timeout: Duration,
        lookup: @escaping @Sendable () -> ClaudeCredentialsLookup
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
                DispatchQueue.global(qos: .utility).async {
                    gate.finish(lookup())
                }
            }
        }
        deadline?.cancel()
        return outcome
    }

    private static let gate = KeychainLookupGate()
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
