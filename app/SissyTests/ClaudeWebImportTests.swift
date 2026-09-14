import CommonCrypto
import SQLite3
import XCTest

@testable import Sissy

/// Reading a claude.ai session out of a Chromium cookie store: the format, the
/// store, and what each way of finding nothing is called.
final class ClaudeWebImportTests: XCTestCase {
    private let password = "1SsMcMwjrOD8lPB9dNjuvQ=="
    private let session = "sk-ant-sid01-" + String(repeating: "a", count: 100)

    // MARK: - The format

    /// A value this reader wrote is a value it reads back. The round trip is
    /// the whole contract of `decrypt`, and it runs without a keychain, a
    /// store or Claude.app.
    func testDecryptsAValueItCanAlsoBuild() {
        let value = encrypt(session, password: password, domainBound: false)
        XCTAssertEqual(ClaudeWebCookieImport.decrypt(value, password: password), session)
    }

    /// Recent Chromium prepends 32 bytes of domain hash. Both eras of store
    /// have to read, because a user's machine is whichever one it is.
    func testDecryptsADomainBoundValue() {
        let value = encrypt(session, password: password, domainBound: true)
        XCTAssertEqual(ClaudeWebCookieImport.decrypt(value, password: password), session)
    }

    /// The wrong key must answer nothing rather than a string of noise, which
    /// would reach the endpoint and be rejected there instead of here.
    func testWrongPasswordDecryptsToNothing() {
        let value = encrypt(session, password: password, domainBound: true)
        XCTAssertNil(ClaudeWebCookieImport.decrypt(value, password: "not the key"))
    }

    /// A value in a format this reader does not know is not guessed at.
    func testRejectsAValueWithoutTheVersionPrefix() {
        var value = encrypt(session, password: password, domainBound: false)
        value.replaceSubrange(0..<3, with: Data("v20".utf8))
        XCTAssertNil(ClaudeWebCookieImport.decrypt(value, password: password))
    }

    /// The binding is stripped by looking at the bytes, not by assuming a
    /// version: a plaintext that is printable throughout keeps every byte.
    func testKeepsAPlaintextThatIsPrintableThroughout() {
        let plain = Data(String(repeating: "x", count: 64).utf8)
        XCTAssertEqual(ClaudeWebCookieImport.strippingDomainBinding(plain), plain)
    }

    func testDropsALeadingHashThatIsNotPrintable() {
        let hash = Data((0..<32).map { UInt8($0) })
        let plain = Data("value".utf8)
        XCTAssertEqual(ClaudeWebCookieImport.strippingDomainBinding(hash + plain), plain)
    }

    // MARK: - The store

    func testReadsTheSessionOutOfAStore() throws {
        let store = try makeStore([
            (host: ".claude.ai", name: "sessionKey", value: Data("cipher".utf8), expires: 100)
        ])
        let found = try ClaudeWebCookieImport.encryptedSession(at: store)
        XCTAssertEqual(found, Data("cipher".utf8))
    }

    /// A store can carry a stale row beside the live one. The live one is the
    /// one that outlives it.
    func testPrefersTheRowThatExpiresLast() throws {
        let store = try makeStore([
            (host: ".claude.ai", name: "sessionKey", value: Data("old".utf8), expires: 100),
            (host: ".claude.ai", name: "sessionKey", value: Data("new".utf8), expires: 900),
        ])
        XCTAssertEqual(try ClaudeWebCookieImport.encryptedSession(at: store), Data("new".utf8))
    }

    /// A cookie set for the host and one set for the domain are the same
    /// session to claude.ai and different rows here.
    func testReadsTheHostSpellingToo() throws {
        let store = try makeStore([
            (host: "claude.ai", name: "sessionKey", value: Data("cipher".utf8), expires: 100)
        ])
        XCTAssertEqual(try ClaudeWebCookieImport.encryptedSession(at: store), Data("cipher".utf8))
    }

    /// A signed-out app has a store and no session, which is not the same as
    /// having no store.
    func testAStoreWithoutASessionAnswersNothing() throws {
        let store = try makeStore([
            (host: ".claude.ai", name: "lastActiveOrg", value: Data("x".utf8), expires: 100)
        ])
        XCTAssertNil(try ClaudeWebCookieImport.encryptedSession(at: store))
    }

    // MARK: - What finding nothing is called

    func testNoStoreIsItsOwnFailure() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("no-such-store-\(UUID().uuidString)")
        let result = ClaudeWebCookieImport.session(storeURL: missing) { .success("unused") }
        XCTAssertEqual(result.failure, .noStore)
    }

    func testASignedOutStoreIsNotAnUnreadableOne() throws {
        let store = try makeStore([])
        let result = ClaudeWebCookieImport.session(storeURL: store) { .success(password) }
        XCTAssertEqual(result.failure, .noSession)
    }

    /// The keychain refusing is the user's to act on and is reported as such,
    /// with the status kept so an absence can be told from a denial.
    func testAKeychainRefusalTravelsWithItsStatus() throws {
        let store = try makeStore([
            (
                host: ".claude.ai", name: "sessionKey",
                value: encrypt(session, password: password, domainBound: true), expires: 100
            )
        ])
        let result = ClaudeWebCookieImport.session(storeURL: store) {
            .failure(.noKey(errSecAuthFailed))
        }
        XCTAssertEqual(result.failure, .noKey(errSecAuthFailed))
    }

    /// A value that decrypts to something that is not a session is a format
    /// change, and saying so beats storing nonsense and failing at the wire.
    func testAValueThatIsNotASessionIsUndecryptable() throws {
        let store = try makeStore([
            (
                host: ".claude.ai", name: "sessionKey",
                value: encrypt("not-a-session", password: password, domainBound: true),
                expires: 100
            )
        ])
        let result = ClaudeWebCookieImport.session(storeURL: store) { .success(password) }
        XCTAssertEqual(result.failure, .undecryptable)
    }

    func testAWholeImportOffARealStoreShape() throws {
        let store = try makeStore([
            (
                host: ".claude.ai", name: "sessionKey",
                value: encrypt(session, password: password, domainBound: true), expires: 100
            )
        ])
        let result = ClaudeWebCookieImport.session(storeURL: store) { .success(password) }
        XCTAssertEqual(try result.get(), session)
    }

    // MARK: - Helpers

    /// A Chromium `v10` value, built the way Chromium builds one so the reader
    /// is tested against the format rather than against itself.
    private func encrypt(_ value: String, password: String, domainBound: Bool) -> Data {
        var key = Data(count: 16)
        let salt = Array("saltysalt".utf8)
        _ = key.withUnsafeMutableBytes { derived in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count,
                salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                derived.baseAddress?.assumingMemoryBound(to: UInt8.self), 16)
        }
        let binding = domainBound ? Data((0..<32).map { _ in UInt8.random(in: 0...0x1F) }) : Data()
        let plaintext = binding + Data(value.utf8)
        var ciphertext = Data(count: plaintext.count + kCCBlockSizeAES128)
        var written = 0
        let status = ciphertext.withUnsafeMutableBytes { output in
            plaintext.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, keyBytes.count,
                        Array(repeating: UInt8(ascii: " "), count: kCCBlockSizeAES128),
                        input.baseAddress, input.count,
                        output.baseAddress, output.count, &written)
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        ciphertext.removeSubrange(written...)
        return Data("v10".utf8) + ciphertext
    }

    /// A cookie store with the columns this reader names, so the query is
    /// tested against SQLite rather than against a stub.
    private func makeStore(
        _ rows: [(host: String, name: String, value: Data, expires: Int64)]
    ) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cookies-\(UUID().uuidString).db")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(
            sqlite3_exec(
                db,
                """
                create table cookies (
                  host_key text, name text, encrypted_value blob, expires_utc integer)
                """, nil, nil, nil), SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for row in rows {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "insert into cookies values (?, ?, ?, ?)", -1, &statement, nil), SQLITE_OK)
            sqlite3_bind_text(statement, 1, row.host, -1, transient)
            sqlite3_bind_text(statement, 2, row.name, -1, transient)
            _ = row.value.withUnsafeBytes {
                sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(row.value.count), transient)
            }
            sqlite3_bind_int64(statement, 4, row.expires)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }
        return url
    }
}

extension Result {
    fileprivate var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
