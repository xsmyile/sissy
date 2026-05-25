import Foundation
import Security

/// Generic-Password Keychain wrapper for app-held secrets. Today only the
/// daemon bearer token uses it; the API is generic so future secrets (OTA
/// password, custom Wi-Fi creds during pairing) can move off plaintext JSON
/// on the same machinery.
///
/// Service is the bundle id (`com.radonforge.sissy` or
/// `com.radonforge.sissy.dev`) so dev and release builds keep separate
/// keychain entries — same isolation pattern as `SissyPaths.appSupportDir`.
enum KeychainStore {
    static let bearerAccount = "daemon-bearer"

    private static var service: String {
        Bundle.main.bundleIdentifier ?? "com.radonforge.sissy"
    }

    /// Stores or replaces the value at `(service, account)`. Returns true on
    /// success; the caller can fall back to plaintext if Keychain is locked
    /// or otherwise unavailable.
    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var add = query
            for (k, v) in update { add[k] = v }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            return addStatus == errSecSuccess
        }
        return false
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
            let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: bearer-token convenience

    static var bearerToken: String? { Self.get(account: bearerAccount) }

    @discardableResult
    static func setBearerToken(_ value: String) -> Bool { set(value, account: bearerAccount) }

    @discardableResult
    static func deleteBearerToken() -> Bool { delete(account: bearerAccount) }
}
