import Foundation
import Security

/// Claude Code credentials filed for a config home Sissy does not read.
///
/// `CLAUDE_CONFIG_DIR` is not followed, and deliberately: an app started from
/// the Dock or at login does not inherit a shell's environment, so the
/// variable a user exports in `.zshrc` never reaches Sissy, and reading the
/// login shell's environment to recover it runs the user's startup files to
/// answer a question about a folder. What Sissy can see without either is the
/// consequence. Claude Code files every home other than the default under
/// `Claude Code-credentials-` and the first eight hex characters of the
/// SHA-256 of that home's path, so an item under that shape whose hash is none
/// of the names Sissy reads is a `claude` signed in somewhere Sissy is not
/// looking, and Settings can say so rather than leave the account missing.
///
/// Only service names and modification dates are listed. The query asks for
/// attributes and never for data, which the keychain answers without an ACL
/// check, so it cannot raise a dialog and reads no secret.
///
/// An item nothing has written for a week is left out. The hash cannot be
/// turned back into a path, so whether the folder still exists is not
/// answerable, and a folder the user abandoned keeps its item forever. What
/// is answerable is whether a `claude` still uses it: the CLI rewrites the
/// item on every token refresh, measured 2026-09-24 as two minutes old on the
/// default home against nine days on a folder deleted since.
enum ClaudeUnsupportedHomes {
    /// One Claude Code keychain item, as the attributes-only listing names it.
    struct ListedItem: Equatable {
        let service: String
        let modified: Date?
    }

    /// How long an item may go unwritten before it counts as abandoned.
    static let staleAfter: TimeInterval = 7 * 24 * 60 * 60

    /// Most items the listing takes. The query is already narrowed to the
    /// account name Claude Code files under, where a Mac holds a handful; the
    /// bound is what keeps a keychain with thousands of such items from
    /// costing more than one page of attributes.
    private static let listingLimit = 256
    private static let hexDigits = Set("0123456789abcdef")

    /// The scoped names in `listed` that belong to no home Sissy reads,
    /// sorted and each once.
    static func services(in listed: [String], reading home: URL) -> [String] {
        let known = Set(
            [ClaudeKeychainCLI.claudeService(for: home)]
                + ClaudeKeychainCLI.siblingClaudeServices(for: home))
        let prefix = ClaudeKeychainCLI.claudeService + "-"
        let foreign = listed.filter { service in
            guard service.hasPrefix(prefix), !known.contains(service) else { return false }
            let suffix = service.dropFirst(prefix.count)
            return suffix.count == ClaudeKeychainCLI.suffixLength
                && suffix.allSatisfy { hexDigits.contains($0) }
        }
        return Set(foreign).sorted()
    }

    /// The services in `listed` some `claude` has written within
    /// `staleAfter` of `now`. An item with no date is kept, because the
    /// absence of a reading is not a reading of abandonment.
    static func inUse(_ listed: [ListedItem], now: Date) -> [String] {
        listed
            .filter { item in item.modified.map { now.timeIntervalSince($0) <= staleAfter } ?? true }
            .map(\.service)
    }

    /// Lists the keychain and filters it. `listing` is the keychain half,
    /// injectable so the rule is provable without the login keychain.
    static func scan(
        reading home: URL,
        now: Date = Date(),
        listing: () -> [ListedItem] = keychainItems
    ) -> [String] {
        services(in: inUse(listing(), now: now), reading: home)
    }

    /// Every generic-password item filed under Claude Code's account name,
    /// read as attributes only and with every prompt suppressed.
    ///
    /// A keychain that failed says so in the log rather than passing for one
    /// with no such items, for the reason `ClaudeWebSessionStore.storedAccounts`
    /// gives: both are `[]` to the caller and only one is the user's doing.
    static func keychainItems() -> [ListedItem] {
        var query = ClaudeCredentialsStore.makeQuery(allowingInteraction: false)
        query.removeValue(forKey: kSecAttrService as String)
        query.removeValue(forKey: kSecReturnData as String)
        query[kSecAttrAccount as String] = ClaudeKeychainCLI.claudeLoginName()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = listingLimit
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                sissyLog("sissy: could not list Claude Code's keychain items (OSStatus \(status))")
            }
            return []
        }
        guard let attributes = items as? [[String: Any]] else { return [] }
        return attributes.compactMap { item in
            guard let service = item[kSecAttrService as String] as? String else { return nil }
            return ListedItem(
                service: service, modified: item[kSecAttrModificationDate as String] as? Date)
        }
    }
}
