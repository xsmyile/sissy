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
///
/// Asserted with more than one stored, because every surface here changed from
/// holding one session to holding a set and a leak of the second would read as
/// the first still being safe.
///
/// The export is the one surface not asserted, and deliberately:
/// `UsageHistoryExport` takes `[UsageHistoryDay]`, which names days, models and
/// project paths and has no account on it at all — a test there would assert
/// that a type with no path to the secret does not carry it.
final class ClaudeWebSessionSecrecyTests: XCTestCase {
    private static let session = "sk-ant-sid01-" + String(repeating: "s", count: 100)
    private static let second = "sk-ant-sid01-" + String(repeating: "t", count: 100)

    private func identity(_ uuid: String) -> ClaudeAccountIdentity {
        ClaudeAccountIdentity(
            uuid: uuid, email: "someone@example.com", organization: "Example Ltd",
            organizationType: "claude_team", rateLimitTier: nil, seat: "team_tier_1")
    }

    /// Every string anywhere inside a value, however deeply nested. A leak is
    /// a field somebody added, so the sweep is over the whole shape rather
    /// than over the fields this test thought to name.
    private func strings(in value: Any) -> [String] {
        var found: [String] = []
        if let text = value as? String { found.append(text) }
        for child in Mirror(reflecting: value).children {
            found.append(contentsOf: strings(in: child.value))
        }
        return found
    }

    private func assertNoSession(
        in value: Any, _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let leaked = strings(in: value).filter {
            $0.contains(ClaudeWebSessionStore.sessionPrefix)
        }
        XCTAssertTrue(
            leaked.isEmpty, "\(message): \(leaked.count) string(s) carried a session",
            file: file, line: line)
    }

    /// The readings the frame is built from, taken off sources that are
    /// holding the sessions and have just spent them on a request.
    func testNoReadingCarriesTheSessionItWasReadWith() async {
        let sources = [
            source(account: "u-1", session: Self.session),
            source(account: "u-2", session: Self.second),
        ]
        for source in sources { await source.refresh {} }

        let accounts = ClaudeCodeSignals.perAccount(
            ProviderSignals(),
            sources: sources,
            known: ClaudeAccountRegistry.Snapshot(accounts: [], activeUUID: nil),
            links: [
                "u-1": ClaudeWebLink(identity: identity("u-1"), organization: "org-1"),
                "u-2": ClaudeWebLink(identity: identity("u-2"), organization: "org-2"),
            ])

        XCTAssertEqual(accounts.count, 2)
        // The sweep has to be able to fail: a walk that reached nothing would
        // report no leak for ever. This string is nested two optionals deep.
        XCTAssertTrue(strings(in: accounts).contains("someone@example.com"))
        assertNoSession(in: accounts, "the per-account readings")
        for source in sources { assertNoSession(in: source.currentSignals(), "a published reading") }
    }

    private func source(account: String, session: String) -> ClaudeWebSource {
        ClaudeWebSource(
            account: account,
            organization: "org-\(account)",
            sessionSource: { _ in .found(ClaudeCredentials(accessToken: session, expiresAt: nil)) },
            fetchSource: { _, org in
                ClaudeWebSource.Reading(
                    organization: org ?? "org", windows: [], credits: nil)
            })
    }

    /// The file that names what each session is for sits beside the sessions
    /// and holds none of them: it is readable without the keychain, which is
    /// the whole reason it exists.
    func testTheLinkIndexHoldsNoSession() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("secrecy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = ClaudeWebSessionIndex(url: ClaudeWebSessionIndex.defaultURL(in: directory))

        try index.remember(ClaudeWebLink(identity: identity("u-1"), organization: "org-1"))
        try index.remember(ClaudeWebLink(identity: identity("u-2"), organization: "org-2"))

        let written = try String(
            contentsOf: ClaudeWebSessionIndex.defaultURL(in: directory), encoding: .utf8)
        XCTAssertFalse(written.contains(ClaudeWebSessionStore.sessionPrefix))
        assertNoSession(in: index.load(), "the loaded links")
    }

    /// What the login window hands the app when one question is left. The
    /// session stays in the engine until it is answered, so a view that could
    /// be screenshotted never holds one.
    func testTheQuestionHandedToTheAppHoldsNoSession() async throws {
        let named = identity("u-1")
        let outcome = try await ClaudeWebAccountLink.resolve(
            session: Self.session,
            identify: { _ in named },
            organizations: { _ in
                [
                    ClaudeWebOrganization(id: "org-1", name: "Example Ltd", plan: "team"),
                    ClaudeWebOrganization(id: "org-2", name: "Other Ltd", plan: "max"),
                ]
            })

        guard case .choice(let identity, let organizations) = outcome else {
            return XCTFail("expected an account with more than one organisation to ask")
        }
        let choice = ClaudeWebLinkChoice(identity: identity, organizations: organizations)
        XCTAssertTrue(strings(in: choice).contains("Other Ltd"))
        assertNoSession(in: choice, "the choice handed to the app")
    }

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
