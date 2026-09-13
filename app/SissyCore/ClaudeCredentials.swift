import Foundation
import LocalAuthentication
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
    /// The item is there and this read was not allowed to ask for it.
    ///
    /// Emphatically not `.denied`: nobody was asked and nobody refused. It is
    /// what a background read meets when the grant has gone stale — Sissy
    /// re-signed, or the CLI rewrote the item — and the only honest answer is
    /// to show no limits and wait, because the alternative is a dialog in
    /// front of someone who did not just ask for one. A caller that *is* a
    /// user action reads again with interaction allowed.
    case interactionRequired
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
    ///
    /// `allowingInteraction` is the caller saying whether it is a user action.
    /// It is the only thing that decides whether macOS may put a dialog on
    /// screen, and every scheduled read passes `false`.
    static func loadOffPool(
        timeout: Duration,
        allowingInteraction: Bool,
        lookup: (@Sendable (Bool) -> ClaudeCredentialsLookup)? = nil
    ) async -> ClaudeCredentialsLookup {
        let run = lookup ?? { load(allowingInteraction: $0) }
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
                    gate.finish(run(allowingInteraction))
                }
            }
        }
        deadline?.cancel()
        return outcome
    }

    private static let gate = KeychainLookupGate()

    /// The lookup, with the legacy keychain's own Allow/Deny panel switched
    /// off for the duration of a silent read.
    ///
    /// `makeQuery`'s two suppressors are not enough on their own. Measured on
    /// macOS 27 against the item Claude Code writes: a read carrying both an
    /// `interactionNotAllowed` `LAContext` and `kSecUseAuthenticationUIFail`
    /// still raised the panel at launch. That panel is the *keychain's* own
    /// ACL check — this app is not on another team's item — rather than an
    /// authentication policy, and the only switch that reaches it is
    /// `SecKeychainSetUserInteractionAllowed`. It is process-wide and
    /// deprecated with no replacement, so it is resolved by name for the same
    /// reason the constants are, thrown only around the call, and put back
    /// before returning — the interactive read a user action makes needs the
    /// panel. Process-wide is safe here because `loadOffPool`'s gate runs one
    /// lookup at a time and nothing else in Sissy touches a keychain.
    static func load(allowingInteraction: Bool) -> ClaudeCredentialsLookup {
        let suppressed = allowingInteraction ? false : setUserInteractionAllowed(false)
        defer { if suppressed { _ = setUserInteractionAllowed(true) } }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            makeQuery(allowingInteraction: allowingInteraction) as CFDictionary, &item)
        return classify(status, data: item as? Data, allowingInteraction: allowingInteraction)
    }

    /// What one `SecItemCopyMatching` outcome means. Pure, because this is the
    /// mapping that decides whether the probe keeps polling or stops for good,
    /// and it has to be testable without a keychain.
    ///
    /// A suppressed read does not answer `errSecInteractionNotAllowed`: it
    /// answers `errSecAuthFailed`, the same status a user clicking Deny
    /// produces. `allowingInteraction` is what tells them apart. Folding them
    /// together would read a launch nobody was allowed to ask on as a refusal
    /// and stop the probe, which is the one thing `.interactionRequired`
    /// exists to prevent.
    static func classify(
        _ status: OSStatus,
        data: Data?,
        allowingInteraction: Bool
    ) -> ClaudeCredentialsLookup {
        switch status {
        case errSecSuccess:
            guard let data, let parsed = parse(data) else {
                return .unreadable(errSecDecode)
            }
            return .found(parsed)
        case errSecItemNotFound:
            return .absent
        case errSecInteractionNotAllowed:
            return .interactionRequired
        case errSecUserCanceled, errSecAuthFailed:
            return allowingInteraction ? .denied : .interactionRequired
        default:
            return .unreadable(status)
        }
    }

    /// The query half of a silent read: the two suppressors that travel with
    /// the lookup, alongside the process-wide one `load` throws around it.
    ///
    /// `LAContext.interactionNotAllowed` covers the modern path and
    /// `kSecUseAuthenticationUIFail` the authentication policy the SDK
    /// deprecates while still honouring it. Neither reaches the legacy
    /// keychain's ACL panel — measured, and the reason `load` also switches
    /// user interaction off for the call. They stay because they are what
    /// answers `errSecInteractionNotAllowed` rather than a bare auth failure,
    /// which is the only outcome that says the item is there and untouched. A
    /// build that cannot resolve either name still reads — it just reads the
    /// way it always did — so a missing symbol costs the silence, never the
    /// feature.
    static func makeQuery(allowingInteraction: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        guard !allowingInteraction else { return query }
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        if let key = securityConstant(authenticationUIName),
            let fail = securityConstant(authenticationUIFailName)
        {
            query[key] = fail
        }
        return query
    }

    static let authenticationUIName = "kSecUseAuthenticationUI"
    static let authenticationUIFailName = "kSecUseAuthenticationUIFail"
    static let userInteractionName = "SecKeychainSetUserInteractionAllowed"

    private typealias SetUserInteractionAllowed = @convention(c) (UInt8) -> OSStatus

    /// Throws the process-wide switch that decides whether the legacy keychain
    /// may put its Allow/Deny panel on screen, and reports whether it was
    /// actually thrown.
    ///
    /// The answer is what the caller restores against: a build that cannot
    /// resolve the symbol reads the way it always did rather than leaving the
    /// panel suppressed for the rest of the run.
    static func setUserInteractionAllowed(_ allowed: Bool) -> Bool {
        guard let symbol = dlsym(rtldDefault, userInteractionName) else { return false }
        let set = unsafeBitCast(symbol, to: SetUserInteractionAllowed.self)
        return set(allowed ? 1 : 0) == errSecSuccess
    }

    /// `RTLD_DEFAULT`, which is a sentinel rather than an address. Computed
    /// because a stored pointer is not `Sendable` under strict concurrency and
    /// there is nothing here worth storing.
    private static var rtldDefault: UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: -2)
    }

    /// Reads a `Security` string constant out of the already-loaded framework
    /// rather than referencing it, so a deprecation does not become a warning
    /// on every build for a value that still works.
    private static func securityConstant(_ name: String) -> String? {
        guard let symbol = dlsym(rtldDefault, name) else { return nil }
        return symbol.assumingMemoryBound(to: CFString?.self).pointee as String?
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
