import Foundation
import LocalAuthentication
import Security

/// Outcome of a keychain lookup. Absence and refusal are different states:
/// the first is a user who has not signed in, the second is a user who said
/// no, and re-asking them on a timer would be harassment.
///
/// Generic in what was found because the outcomes are the keychain's rather
/// than a vendor's: a second item, holding something else, meets the same six
/// answers and must read them the same way — which is the whole point of
/// `classify` being one table.
enum CredentialLookup<Value: Sendable>: Sendable {
    case found(Value)
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

/// How Sissy reads a keychain item without putting a dialog in front of
/// someone who did not ask for one, for any service.
///
/// Vendor-neutral on purpose: Claude Code's item, the claude.ai session, a
/// linked Codex account and a forge token all meet the same three
/// suppressors and the same outcome table, and a forge reading its token
/// through a type named for Claude was a dependency on a vendor it has
/// nothing to do with.
enum KeychainAccess {
    /// One `SecItemCopyMatching`, with the legacy keychain's own Allow/Deny
    /// panel switched off for the duration of a silent read.
    ///
    /// `makeQuery`'s two suppressors are not enough on their own. Measured on
    /// macOS 27 against the item Claude Code writes: a read carrying both an
    /// `interactionNotAllowed` `LAContext` and `kSecUseAuthenticationUIFail`
    /// still raised the panel at launch. That panel is the *keychain's* own
    /// ACL check — Sissy is not on the ACL of an item another team wrote —
    /// rather than an authentication policy, and the only switch that reaches
    /// it is `SecKeychainSetUserInteractionAllowed`. It is process-wide and
    /// deprecated with no replacement, so it is resolved by name for the same
    /// reason the constants are, thrown only around the call, and put back
    /// before returning — the interactive read a user action makes needs the
    /// panel.
    ///
    /// The restore is to `true` rather than to whatever was there before: the
    /// API has no getter, and `true` is the state every process starts in and
    /// the only one anything else in Sissy would want. Which is also the bound
    /// on it: the suppression covers one synchronous call, so two readers
    /// overlapping here would have the first one's restore re-open the panel
    /// for the second. `suppressingInteraction` is what serialises them.
    ///
    /// Its callers read items Sissy owns, the claude.ai session, a linked
    /// Codex account and a forge token: such an item
    /// is on Sissy's own ACL and reads silently right up until Sissy is
    /// re-signed, and at that point a background read has to fail rather than
    /// interrupt. Claude Code's own item is no longer read this
    /// way at all — `ClaudeCodeCredentials` reaches it through
    /// `/usr/bin/security`, which is on that item's ACL where Sissy is not.
    static func copyMatching(
        _ query: [String: Any],
        allowingInteraction: Bool
    ) -> (status: OSStatus, data: Data?) {
        suppressingInteraction(
            allowingInteraction, unavailable: (errSecInteractionNotAllowed, nil)
        ) {
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            return (status, item as? Data)
        }
    }

    /// How long a reader waits for the one in front of it.
    ///
    /// Generous by orders of magnitude — a read of a local item answers in
    /// milliseconds — because what this bounds is a reader that has wedged,
    /// not one that is merely busy. Same figure and same reasoning as
    /// `ClaudeKeychainCLI`'s own budget.
    static let suppressorTimeout: TimeInterval = 5

    /// Runs `read` with the panel switched off, and lets no second reader in
    /// while it does.
    ///
    /// The lock is the whole point. `SecKeychainSetUserInteractionAllowed` is
    /// process-wide and the restore is unconditional — the API has no getter,
    /// so it goes back to `true`, which is right for one reader and wrong for
    /// two. Without this, A suppressing, B suppressing, A returning and
    /// restoring, then B reading, is a scheduled background read running with
    /// the panel allowed: the single outcome the three suppressors exist to
    /// prevent. Two readers is the ordinary case rather than a corner — there
    /// is a `ClaudeWebSource` per linked claude.ai session and a
    /// `CodexUsageSource` per linked OpenAI account, each polling on its own.
    ///
    /// **The wait is bounded, and that is not a detail.**
    /// `ClaudeCredentialsStore.loadOffPool` exists because
    /// `SecItemCopyMatching` blocks for as long as macOS takes to authorize,
    /// which is unbounded — it can sit behind a dialog nobody
    /// answers. Suppression is what should stop that, and it is not
    /// guaranteed: `setUserInteractionAllowed` answers false where `dlsym`
    /// cannot resolve a deprecated symbol, and the read then runs with nothing
    /// suppressing it at all. Held without a budget, one reader parked that
    /// way would take every other linked account's reader down with it, for
    /// good — neither `ClaudeWebSessionStore` nor `CodexAccountStore` goes
    /// through `loadOffPool`, so neither has a timeout of its own. That is a
    /// worse failure than the overlap this exists to prevent.
    ///
    /// A reader that cannot get in answers `unavailable` rather than running
    /// unsuppressed, which would be the original bug on purpose.
    /// `copyMatching` supplies `errSecInteractionNotAllowed` for it, because
    /// `classify` reads that as `.interactionRequired` whether or not the
    /// caller was allowed to ask — the item is there, this read could not have
    /// it, the reader stays alive and the next poll tries again. Deliberately
    /// not `errSecAuthFailed`, which an interactive caller would be told is a
    /// person clicking Deny.
    ///
    /// Not `loadOffPool`'s gate, which serves every waiter the one lookup's
    /// answer. These readers ask for different items, so the answer to one is
    /// not the answer to another.
    static func suppressingInteraction<Value>(
        _ allowingInteraction: Bool,
        unavailable: @autoclosure () -> Value,
        timeout: TimeInterval = suppressorTimeout,
        _ read: () -> Value
    ) -> Value {
        guard interactionLock.lock(before: Date().addingTimeInterval(timeout)) else {
            return unavailable()
        }
        defer { interactionLock.unlock() }
        let suppressed = allowingInteraction ? false : setUserInteractionAllowed(false)
        defer { if suppressed { _ = setUserInteractionAllowed(true) } }
        return read()
    }

    private static let interactionLock = NSLock()

    /// Runs a blocking keychain read on a dispatch thread and resumes with its
    /// answer, so it parks that thread rather than one of the cooperative
    /// pool's, which the whole runtime shares. For a read that needs no gate
    /// and no budget of its own: `suppressingInteraction` already bounds the
    /// wait behind another reader.
    static func offPool<Value: Sendable>(_ read: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: read()) }
        }
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
    ///
    /// Generic in what the item holds, because the mapping below is the rule
    /// that must not drift, not the payload.
    static func classify<Value>(
        _ status: OSStatus,
        data: Data?,
        allowingInteraction: Bool,
        decoding decode: (Data) -> Value?
    ) -> CredentialLookup<Value> {
        switch status {
        case errSecSuccess:
            guard let data, let parsed = decode(data) else {
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
    /// the lookup, alongside the process-wide one `copyMatching` throws around
    /// it.
    ///
    /// `LAContext.interactionNotAllowed` covers the modern path and
    /// `kSecUseAuthenticationUIFail` the authentication policy the SDK
    /// deprecates while still honouring it. Neither reaches the legacy
    /// keychain's ACL panel — measured, and the reason `copyMatching` also
    /// switches user interaction off for the call. They stay because they are what
    /// answers `errSecInteractionNotAllowed` rather than a bare auth failure,
    /// which is the only outcome that says the item is there and untouched. A
    /// build that cannot resolve either name still reads — it just reads the
    /// way it always did — so a missing symbol costs the silence, never the
    /// feature.
    static func makeQuery(
        service: String,
        allowingInteraction: Bool
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
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
    private static func setUserInteractionAllowed(_ allowed: Bool) -> Bool {
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
}

/// The generic-password items Sissy files under one service of its own, one
/// per account.
///
/// One value for every such store (the claude.ai sessions, the linked Codex
/// accounts and the forge tokens), which had each written out the same save,
/// load, delete and listing and differ only in the service and what the
/// secret decodes to.
struct SissyKeychainItems: Sendable {
    let service: String
    /// What a failed listing says it could not list, for the log.
    let listing: String

    /// One account's item, under the suppression every scheduled read in this
    /// app takes: silent in the ordinary case, and refusing rather than
    /// interrupting once a re-signing has cost the grant.
    func load<Value>(
        account: String, allowingInteraction: Bool, decoding decode: (Data) -> Value?
    ) -> CredentialLookup<Value> {
        var query = KeychainAccess.makeQuery(
            service: service, allowingInteraction: allowingInteraction)
        query[kSecAttrAccount as String] = account
        let result = KeychainAccess.copyMatching(query, allowingInteraction: allowingInteraction)
        return KeychainAccess.classify(
            result.status, data: result.data, allowingInteraction: allowingInteraction,
            decoding: decode)
    }

    /// Files `data` under `account`, replacing whatever was there, and answers
    /// the keychain's status: `errSecSuccess` or the failure.
    ///
    /// Add-then-update rather than delete-then-add: a delete that succeeds
    /// followed by an add that fails would leave the user with no secret and
    /// no way to tell that from one they never handed over.
    func save(_ data: Data, account: String) -> OSStatus {
        var attributes = identity(account: account)
        attributes[kSecValueData as String] = data
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecDuplicateItem else { return added }
        return SecItemUpdate(
            identity(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
    }

    /// Forgets one account's item. An item that was not there is not a
    /// failure: the caller asked for it gone and it is gone.
    func delete(account: String) -> OSStatus {
        let status = SecItemDelete(identity(account: account) as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }

    /// Every account an item is filed under, sorted so two calls agree.
    ///
    /// Attributes only and never the data: the keychain authorizes a read of
    /// the *secret*, so asking which items exist costs no ACL check and cannot
    /// raise a dialog. That is what lets the engine decide how many readers to
    /// build before any of them has read anything, and on a build whose grant
    /// has lapsed.
    ///
    /// An empty answer means nothing is filed. A keychain that failed for any
    /// other reason says so in the log rather than passing for one, because
    /// the two are the same `[]` to every caller and only one of them is the
    /// user's doing.
    func accounts() -> [String] {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                sissyLog("sissy: could not list \(listing) (OSStatus \(status))")
            }
            return []
        }
        guard let attributes = items as? [[String: Any]] else { return [] }
        return attributes.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }

    /// What the item is, with neither a value nor a read on it. Shared by
    /// every operation so an add, an update and a delete cannot drift into
    /// addressing different items.
    private func identity(account: String) -> [String: Any] {
        var query = baseQuery()
        query[kSecAttrAccount as String] = account
        return query
    }
}
