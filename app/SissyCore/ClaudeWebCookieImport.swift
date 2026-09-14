import CommonCrypto
import Foundation
import SQLite3
import Security

/// Imports the claude.ai session out of Claude.app's own cookie store.
///
/// The desktop app is the source rather than a browser because it is where the
/// session actually is. Measured 2026-09-14 on one machine: Claude.app held a
/// `sessionKey` valid for four more weeks, written a minute earlier; Chrome's
/// copy had expired three and a half months before; Safari held no claude.ai
/// cookie at all. A browser-first import would have found nothing, and it
/// would have cost Full Disk Access to find it.
///
/// Claude.app stores cookies the way every Chromium does: the value is AES
/// under a key derived from a keychain secret. That secret is an *install*
/// key, not a session one — measured, `Claude Safe Storage` was created
/// 2024-11-11 and has never been rewritten, across app updates, where Claude
/// Code's credential item is rewritten on every token refresh. So the grant it
/// costs is asked for once, on the click that switches this source on, and
/// what every poll afterwards reads is the item Sissy wrote from it.
enum ClaudeWebCookieImport {
    /// Where Claude.app keeps its cookies. Not configurable: this is the
    /// vendor's own path, and a Sissy that had to be told it would be a Sissy
    /// that could be pointed at any SQLite file on the machine.
    static var defaultStoreURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Claude/Cookies")
    }

    static let safeStorageService = "Claude Safe Storage"
    static let safeStorageAccount = "Claude Key"

    /// Cookie host the session is filed under. Both spellings are queried
    /// because a cookie set for the domain and one set for the host are the
    /// same session to claude.ai and different rows here.
    static let cookieHosts = [".claude.ai", "claude.ai"]

    /// Chromium's own constants. Named rather than inlined because they are a
    /// format's parameters, not tuning: changing one does not make the reader
    /// better, it makes it read a different format.
    private static let salt = "saltysalt"
    private static let iterations: UInt32 = 1003
    private static let keyLength = 16
    private static let versionPrefix = Data("v10".utf8)
    /// Recent Chromium binds a cookie to its domain by prepending 32 bytes of
    /// hash to the plaintext. Older stores do not, so its presence is decided
    /// by looking rather than by assuming — see `strippingDomainBinding`.
    private static let domainBindingLength = 32

    /// Why an import produced no session. Each case is a different sentence to
    /// the user and a different thing for them to do, which is why they are
    /// not one error.
    enum Failure: Error, Equatable {
        /// Claude.app is not installed, or has never signed in.
        case noStore
        /// The keychain would not hand over the Safe Storage key. Carries the
        /// status so a refusal can be told from an absence.
        case noKey(OSStatus)
        /// The store is there and holds no claude.ai session: the app is
        /// installed and signed out.
        case noSession
        /// The store could not be opened or queried.
        case unreadableStore(String)
        /// The value decrypted to something that is not a session. A format
        /// change, or a key that does not belong to this store.
        case undecryptable
    }

    /// The session Claude.app is holding, or why there is none.
    ///
    /// `password` is injected for the same reason `ClaudeLimitsProbe` injects
    /// its credential source: reading the keychain is what can raise a system
    /// dialog, and a test of this path must be able to answer for one without
    /// putting it on a screen.
    static func session(
        storeURL: URL = defaultStoreURL,
        password: () -> Result<String, Failure> = { safeStoragePassword(allowingInteraction: true) }
    ) -> Result<String, Failure> {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return .failure(.noStore)
        }
        let encrypted: Data
        do {
            guard let found = try encryptedSession(at: storeURL) else {
                return .failure(.noSession)
            }
            encrypted = found
        } catch {
            return .failure(.unreadableStore(String(describing: error)))
        }
        return password().flatMap { secret in
            guard let plaintext = decrypt(encrypted, password: secret),
                ClaudeWebSessionStore.looksLikeSession(plaintext)
            else {
                return .failure(.undecryptable)
            }
            return .success(plaintext)
        }
    }

    /// The Safe Storage key.
    ///
    /// `allowingInteraction` is the caller declaring itself a user action, and
    /// it is the only thing that lets macOS put a dialog on screen — the same
    /// contract, through the same suppressors, as a read of Claude Code's own
    /// item. A silent read is what lets a launch import a session whose grant
    /// is already given without asking anyone anything; a read that would have
    /// prompted simply answers `.noKey` and leaves the button.
    static func safeStoragePassword(allowingInteraction: Bool) -> Result<String, Failure> {
        var query = ClaudeCredentialsStore.makeQuery(
            service: safeStorageService, allowingInteraction: allowingInteraction)
        query[kSecAttrAccount as String] = safeStorageAccount
        let result = ClaudeCredentialsStore.copyMatching(
            query, allowingInteraction: allowingInteraction)
        guard result.status == errSecSuccess,
            let data = result.data,
            let secret = String(data: data, encoding: .utf8)
        else {
            return .failure(.noKey(result.status))
        }
        return .success(secret)
    }

    /// The encrypted `sessionKey` row, or nil when the store holds none.
    ///
    /// Read-only and parameterized. The newest expiry wins: a store can carry
    /// a stale row for the same cookie beside the live one, and the live one
    /// is the one that outlives it.
    static func encryptedSession(at storeURL: URL) throws -> Data? {
        var db: OpaquePointer?
        let opened = sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }
        guard opened == SQLITE_OK else {
            throw ImportError.sqlite(code: opened, message: message(db))
        }
        let sql = """
            select encrypted_value from cookies
            where name = ? and host_key in (?, ?)
            order by expires_utc desc limit 1
            """
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard prepared == SQLITE_OK else {
            throw ImportError.sqlite(code: prepared, message: message(db))
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, ClaudeWebSessionStore.cookieName, -1, transient)
        for (offset, host) in cookieHosts.enumerated() {
            sqlite3_bind_text(statement, Int32(offset + 2), host, -1, transient)
        }
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        case SQLITE_DONE:
            return nil
        case let code:
            throw ImportError.sqlite(code: code, message: message(db))
        }
    }

    /// One Chromium `v10` value, as the string it holds.
    ///
    /// Pure, so the format is testable without a keychain, a store or
    /// Claude.app: given the same password and bytes it gives the same answer.
    static func decrypt(_ value: Data, password: String) -> String? {
        guard value.starts(with: versionPrefix),
            let key = deriveKey(password: password)
        else { return nil }
        let ciphertext = value.dropFirst(versionPrefix.count)
        guard !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0 else { return nil }
        var plaintext = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var written = 0
        let status = plaintext.withUnsafeMutableBytes { output in
            Data(ciphertext).withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, keyBytes.count,
                        Array(repeating: UInt8(ascii: " "), count: kCCBlockSizeAES128),
                        input.baseAddress, input.count,
                        output.baseAddress, output.count,
                        &written)
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { return nil }
        plaintext.removeSubrange(written...)
        return String(data: strippingDomainBinding(plaintext), encoding: .utf8)
    }

    /// The value without the domain hash recent Chromium puts in front of it.
    ///
    /// Decided by looking, not by version: a cookie value is printable ASCII,
    /// and a 32-byte hash is not. Assuming the prefix is always there breaks
    /// older stores; assuming it never is yields a string that decodes to
    /// nothing and reads as a wrong key, which is the least helpful way this
    /// can fail.
    static func strippingDomainBinding(_ plaintext: Data) -> Data {
        guard plaintext.count > domainBindingLength else { return plaintext }
        let prefix = plaintext.prefix(domainBindingLength)
        let isPrintable = prefix.allSatisfy { (0x20...0x7E).contains($0) }
        return isPrintable ? plaintext : plaintext.dropFirst(domainBindingLength)
    }

    private static func deriveKey(password: String) -> Data? {
        let passwordBytes = Array(password.utf8)
        let saltBytes = Array(salt.utf8)
        var key = Data(count: keyLength)
        let status = key.withUnsafeMutableBytes { derived -> Int32 in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                password, passwordBytes.count,
                saltBytes, saltBytes.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                iterations,
                derived.baseAddress?.assumingMemoryBound(to: UInt8.self), keyLength)
        }
        return status == kCCSuccess ? key : nil
    }

    private static func message(_ db: OpaquePointer?) -> String {
        db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
    }

    enum ImportError: Error {
        case sqlite(code: Int32, message: String)
    }
}
