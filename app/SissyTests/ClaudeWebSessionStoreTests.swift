import XCTest

@testable import Sissy

/// What Sissy will accept as a claude.ai session, and what holding one in an
/// item Sissy owns actually does.
final class ClaudeWebSessionStoreTests: XCTestCase {
    private let session = "sk-ant-sid01-" + String(repeating: "a", count: 100)
    /// A per-run account, so a test can write to the real keychain without
    /// ever addressing the item the user's own import lives in.
    private lazy var account = "test-\(UUID().uuidString)"
    private lazy var secondAccount = "test-\(UUID().uuidString)"

    override func tearDown() {
        try? ClaudeWebSessionStore.delete(account: account)
        try? ClaudeWebSessionStore.delete(account: secondAccount)
        super.tearDown()
    }

    // MARK: - What a session looks like

    func testTakesASessionCopiedWithItsCookieName() {
        XCTAssertEqual(
            ClaudeWebSessionStore.normalize("sessionKey=\(session)"), session)
    }

    /// A whole `Cookie` header pasted in keeps only the cookie it names.
    func testTakesASessionOutOfAWholeCookieHeader() {
        XCTAssertEqual(
            ClaudeWebSessionStore.normalize("sessionKey=\(session); lastActiveOrg=abc"), session)
    }

    func testTakesASessionSurroundedByWhitespace() {
        XCTAssertEqual(ClaudeWebSessionStore.normalize("  \(session)\n"), session)
    }

    func testRecognisesASession() {
        XCTAssertTrue(ClaudeWebSessionStore.looksLikeSession(session))
    }

    /// The shape check exists to name the obvious mis-paste before it is sent
    /// anywhere. An API key is the one that would otherwise look plausible.
    func testDoesNotMistakeAnAPIKeyForASession() {
        XCTAssertFalse(ClaudeWebSessionStore.looksLikeSession("sk-ant-api03-abcdef"))
    }

    func testDoesNotAcceptTheBarePrefix() {
        XCTAssertFalse(ClaudeWebSessionStore.looksLikeSession("sk-ant-sid"))
    }

    // MARK: - The item

    func testASavedSessionReadsBack() throws {
        try ClaudeWebSessionStore.save(session, account: account)
        guard
            case .found(let credentials) = ClaudeWebSessionStore.load(
                account: account, allowingInteraction: false)
        else {
            return XCTFail("a session Sissy just wrote did not read back")
        }
        XCTAssertEqual(credentials.accessToken, session)
    }

    /// A session carries no expiry: the cookie store names one, but the copy
    /// Sissy holds is a string and the endpoint's 401 is what knows the
    /// session has ended.
    func testASessionIsValidUntilTheEndpointSaysOtherwise() throws {
        try ClaudeWebSessionStore.save(session, account: account)
        guard
            case .found(let credentials) = ClaudeWebSessionStore.load(
                account: account, allowingInteraction: false)
        else {
            return XCTFail("a session Sissy just wrote did not read back")
        }
        XCTAssertNil(credentials.expiresAt)
        XCTAssertNil(credentials.expiresAt)
    }

    /// Importing again replaces: a rotated session must not leave the old one
    /// behind for a poll to find.
    func testASecondImportReplacesTheFirst() throws {
        let rotated = "sk-ant-sid01-" + String(repeating: "b", count: 100)
        try ClaudeWebSessionStore.save(session, account: account)
        try ClaudeWebSessionStore.save(rotated, account: account)
        guard
            case .found(let credentials) = ClaudeWebSessionStore.load(
                account: account, allowingInteraction: false)
        else {
            return XCTFail("a session Sissy just wrote did not read back")
        }
        XCTAssertEqual(credentials.accessToken, rotated)
    }

    /// Presence is asked without decrypting, so Settings can say "a session is
    /// set" on a build whose grant has lapsed.
    func testPresenceIsAnsweredWithoutReadingTheSecret() throws {
        XCTAssertFalse(ClaudeWebSessionStore.storedAccounts().contains(account))
        try ClaudeWebSessionStore.save(session, account: account)
        XCTAssertTrue(ClaudeWebSessionStore.storedAccounts().contains(account))
    }

    func testForgettingASessionLeavesNothingBehind() throws {
        try ClaudeWebSessionStore.save(session, account: account)
        try ClaudeWebSessionStore.delete(account: account)
        XCTAssertFalse(ClaudeWebSessionStore.storedAccounts().contains(account))
        guard
            case .absent = ClaudeWebSessionStore.load(
                account: account, allowingInteraction: false)
        else {
            return XCTFail("a forgotten session still reads as something")
        }
    }

    /// Unlinking one account leaves every other account's session where it
    /// is, which is the whole of what the trash on a Settings row promises.
    ///
    /// The control used to be one "Forget session" that deleted every stored
    /// session at once, so a user with two linked accounts who wanted rid of
    /// one lost both.
    func testForgettingOneAccountsSessionLeavesTheOthers() throws {
        let other = "sk-ant-sid01-" + String(repeating: "b", count: 100)
        try ClaudeWebSessionStore.save(session, account: account)
        try ClaudeWebSessionStore.save(other, account: secondAccount)

        try ClaudeWebSessionStore.delete(account: account)

        XCTAssertFalse(ClaudeWebSessionStore.storedAccounts().contains(account))
        guard
            case .found(let kept) = ClaudeWebSessionStore.load(
                account: secondAccount, allowingInteraction: false)
        else {
            return XCTFail("forgetting one account's session took another's with it")
        }
        XCTAssertEqual(kept.accessToken, other)
    }

    /// Forgetting something that is already gone is what the caller asked for,
    /// not a failure.
    func testForgettingTwiceIsNotAnError() throws {
        try ClaudeWebSessionStore.save(session, account: account)
        try ClaudeWebSessionStore.delete(account: account)
        XCTAssertNoThrow(try ClaudeWebSessionStore.delete(account: account))
    }

    func testAnEmptySessionIsRefused() {
        XCTAssertThrowsError(try ClaudeWebSessionStore.save("   ", account: account)) { error in
            XCTAssertEqual(error as? ClaudeWebSessionStoreError, .empty)
        }
    }
}

/// The session is a whole claude.ai login. Nothing that leaves the machine may
/// carry it, and a test rather than a convention is what holds that.
final class ClaudeWebSessionSecrecyTests: XCTestCase {
    private static let session = "sk-ant-sid01-" + String(repeating: "s", count: 100)

    func testTheDiagnosticsReportNamesTheSourceAndNotTheSession() throws {
        let account = "test-\(UUID().uuidString)"
        addTeardownBlock { try? ClaudeWebSessionStore.delete(account: account) }
        try ClaudeWebSessionStore.save(Self.session, account: account)
        let report = DiagnosticsReport.text(
            DiagnosticsReport.Snapshot(
                version: "0.1.9", build: "1", systemVersion: "Version 27.0",
                filesWatched: 1, isWarm: true, claudeWebSession: true,
                providers: [], ccusage: []))
        XCTAssertTrue(report.contains("claude.ai session"))
        XCTAssertFalse(report.contains(Self.session))
        XCTAssertFalse(report.contains(ClaudeWebSessionStore.sessionPrefix))
    }
}
