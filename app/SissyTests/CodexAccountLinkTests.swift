import XCTest

@testable import Sissy

/// What linking a second Codex account settles, and what it must never carry.
final class CodexAccountLinkTests: XCTestCase {
    private static func credential(
        user: String? = "user-1",
        account: String? = "7c31482a",
        refresh: String? = "refresh-token"
    ) -> CodexCredential {
        CodexCredential(
            accessToken: "access-token", refreshToken: refresh, idToken: nil,
            accountId: account, userId: user, email: "someone@example.com",
            plan: "plus", expiresAt: nil)
    }

    private static func body(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    // MARK: - Which workspaces a login holds

    func testReadsTheWorkspacesOpenAILists() {
        let body = Self.body(
            """
            {"items": [
              {"id": "7c31482a", "name": "Personal", "structure": "personal"},
              {"id": "a1b2", "name": "Master Soft", "structure": "workspace"}
            ]}
            """)
        let found = CodexAccountLinking.workspaces(in: body)
        XCTAssertEqual(found.map(\.id), ["7c31482a", "a1b2"])
        XCTAssertEqual(found.map(\.name), ["Personal", "Master Soft"])
        XCTAssertEqual(found.first?.structure, "personal")
    }

    /// An entry with no id is no workspace: it cannot be asked about and it
    /// cannot be read for. One with no name takes its id, which is at least
    /// addressable.
    func testDropsAWorkspaceWithNoIDAndNamesOneWithNoName() {
        let found = CodexAccountLinking.workspaces(
            in: Self.body(
                """
                {"items": [{"name": "Nameless"}, {"id": "a1b2"}]}
                """))
        XCTAssertEqual(found.map(\.id), ["a1b2"])
        XCTAssertEqual(found.first?.name, "a1b2")
    }

    // MARK: - What a link decides

    func testALoginWithOneWorkspaceIsLinkedWithoutAsking() async throws {
        let outcome = try await CodexAccountLinking.resolve(
            credential: Self.credential(),
            workspaces: { _ in
                [CodexWorkspace(id: "7c31482a", name: "Personal", structure: "personal")]
            })
        guard case .linked(let link) = outcome else {
            return XCTFail("one workspace is nothing to ask about")
        }
        XCTAssertEqual(link.identity.id, "user-1")
        XCTAssertEqual(link.workspace?.id, "7c31482a")
    }

    func testALoginWithTwoWorkspacesAsks() async throws {
        let outcome = try await CodexAccountLinking.resolve(
            credential: Self.credential(),
            workspaces: { _ in
                [
                    CodexWorkspace(id: "7c31482a", name: "Personal", structure: "personal"),
                    CodexWorkspace(id: "a1b2", name: "Master Soft", structure: "workspace"),
                ]
            })
        guard case .choice(let choice) = outcome else {
            return XCTFail("two workspaces are a question")
        }
        XCTAssertEqual(choice.workspaces.count, 2)
        XCTAssertEqual(choice.identity.email, "someone@example.com")
    }

    /// A workspace list Sissy could not read costs the row a name, never the
    /// login: the credential already carries the workspace OpenAI defaults it
    /// to, which is the vendor's own answer.
    func testAFailedWorkspaceListStillLinks() async throws {
        let outcome = try await CodexAccountLinking.resolve(
            credential: Self.credential(),
            workspaces: { _ in throw UsageRequestError.badStatus(500) })
        guard case .linked(let link) = outcome else { return XCTFail("the login still holds") }
        XCTAssertNil(link.workspace)
    }

    /// A row keyed by nothing cannot be drawn, listed or unlinked, so this is
    /// the one failure that stops a link.
    func testATokenNamingNoLoginIsNotLinked() async {
        do {
            _ = try await CodexAccountLinking.resolve(
                credential: Self.credential(user: nil), workspaces: { _ in [] })
            XCTFail("a credential naming no login has no key")
        } catch {
            XCTAssertEqual(error as? CodexAccountLinking.Failure, .unidentified)
        }
    }

    // MARK: - The sign-in itself

    func testTheAuthorizeURLCarriesTheChallengeAndTheCLIsRedirect() throws {
        let flow = CodexOAuth.begin()
        let components = try XCTUnwrap(
            URLComponents(url: flow.url, resolvingAgainstBaseURL: false))
        let items = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(components.host, "auth.openai.com")
        XCTAssertEqual(items["client_id"], CodexOAuth.clientID)
        XCTAssertEqual(items["redirect_uri"], CodexOAuth.redirectURI)
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["state"], flow.state)
        XCTAssertFalse(items["code_challenge", default: ""].isEmpty)
    }

    func testTheRedirectHandsOverItsCode() throws {
        let flow = CodexOAuth.begin()
        let url = try XCTUnwrap(
            URL(string: "http://localhost:1455/auth/callback?code=abc&state=\(flow.state)"))
        XCTAssertEqual(flow.code(fromRedirect: url), "abc")
    }

    /// The state is the whole of what says a code belongs to this login, so a
    /// redirect carrying somebody else's is not one.
    func testARedirectWithAnotherStateIsNotThisLogin() throws {
        let flow = CodexOAuth.begin()
        let url = try XCTUnwrap(
            URL(string: "http://localhost:1455/auth/callback?code=abc&state=other"))
        XCTAssertNil(flow.code(fromRedirect: url))
    }

    func testOnlyTheLoopbackRedirectIsRead() throws {
        let flow = CodexOAuth.begin()
        let url = try XCTUnwrap(
            URL(string: "https://evil.example/auth/callback?code=abc&state=\(flow.state)"))
        XCTAssertNil(flow.code(fromRedirect: url))
    }

    // MARK: - What the keychain item holds

    /// One parser for the item and for the CLI's file, so a renewal filed here
    /// reads back as the credential it was.
    func testTheStoredCredentialReadsBackWhole() throws {
        let data = try XCTUnwrap(CodexAccountStore.encode(Self.credential()))
        let read = try XCTUnwrap(CodexAuthSource.credential(data, renewable: true))
        XCTAssertEqual(read.accessToken, "access-token")
        XCTAssertEqual(read.refreshToken, "refresh-token")
        XCTAssertEqual(read.accountId, "7c31482a")
    }

    /// The refresh token is dropped for a reader that does not own what it is
    /// reading, which is what makes "Sissy never renews the CLI's credential"
    /// a property of the value.
    func testACredentialReadAsSomebodyElsesCarriesNoRefreshToken() throws {
        let data = try XCTUnwrap(CodexAccountStore.encode(Self.credential()))
        let read = try XCTUnwrap(CodexAuthSource.credential(data, renewable: false))
        XCTAssertNil(read.refreshToken)
        XCTAssertEqual(read.accessToken, "access-token")
    }

    // MARK: - One row per account

    private func source(account: String?, percent: Double) -> CodexUsageSource {
        CodexUsageSource(
            account: account,
            workspace: "Master Soft",
            credentialSource: { _ in .found(Self.credential(user: account ?? "user-cli")) },
            fetchSource: { _ in
                CodexUsagePayload.Reading(
                    accountId: "7c31482a",
                    account: ProviderAccount(email: "someone@example.com"),
                    plan: "plus",
                    windows: [UsageWindow(minutes: 300, usedPercent: percent, resetsAt: nil)!],
                    credits: nil)
            })
    }

    func testEveryReadableAccountGetsAnEntry() async {
        let cli = source(account: nil, percent: 32)
        let linked = source(account: "user-2", percent: 8)
        _ = await cli.refreshOnce {}
        _ = await linked.refreshOnce {}

        var own = ProviderSignals()
        own.windows = [UsageWindow(minutes: 300, usedPercent: 32, resetsAt: nil)!]
        let accounts = CodexSignals.perAccount(
            own: own, signedIn: cli, readers: [cli, linked], links: [:])

        XCTAssertEqual(accounts.map(\.id), ["user-cli", "user-2"])
        XCTAssertEqual(accounts.first?.isSignedIn, true)
        XCTAssertEqual(accounts.last?.windows.first?.usedPercent, 8)
    }

    /// Linking the account the CLI is already on is one account, not two: the
    /// signed-in entry answers for it, and a second row under the same id
    /// would be the same gauge twice.
    func testAnAccountLinkedTwiceIsStillOneRow() async {
        let cli = source(account: nil, percent: 32)
        let linked = source(account: "user-cli", percent: 8)
        _ = await cli.refreshOnce {}
        _ = await linked.refreshOnce {}

        let accounts = CodexSignals.perAccount(
            own: ProviderSignals(), signedIn: cli, readers: [cli, linked], links: [:])
        XCTAssertEqual(accounts.map(\.id), ["user-cli"])
    }

    /// A Mac whose `codex` is signed out still has an answer if exactly one
    /// account is linked. More than one and there is a choice to get wrong, so
    /// the row keeps the CLI's own empty answer and the accounts say the rest.
    func testALoneLinkedAccountAnswersForTheRow() async {
        let linked = source(account: "user-2", percent: 8)
        _ = await linked.refreshOnce {}
        let reading = CodexSignals.row(
            own: ProviderSignals(), linked: [linked.currentSignals()])
        XCTAssertEqual(reading.windows.first?.usedPercent, 8)

        let second = source(account: "user-3", percent: 20)
        _ = await second.refreshOnce {}
        let ambiguous = CodexSignals.row(
            own: ProviderSignals(), linked: [linked.currentSignals(), second.currentSignals()])
        XCTAssertTrue(ambiguous.windows.isEmpty)
    }

    /// The row may fall back to a lone linked account; the signed-in account's
    /// own entry may not. One account's windows under another's name is the
    /// pairing the whole per-account shape exists to prevent.
    func testTheRowsFallbackDoesNotReachTheSignedInAccount() async {
        let cli = source(account: nil, percent: 0)
        let linked = source(account: "user-2", percent: 8)
        _ = await cli.refreshOnce {}
        _ = await linked.refreshOnce {}
        // The CLI's own reader answered for the credential and not for the
        // windows, which is a token OpenAI refused.
        await cli.stop(clearingState: false)

        let own = ProviderSignals()
        let row = CodexSignals.row(own: own, linked: [linked.currentSignals()])
        XCTAssertEqual(row.windows.first?.usedPercent, 8)

        let accounts = CodexSignals.perAccount(
            own: own, signedIn: cli, readers: [cli, linked], links: [:])
        XCTAssertEqual(accounts.filter(\.isSignedIn).flatMap(\.windows).count, 0)
    }

    /// The usage reply names the account by id and the organisation nowhere,
    /// so the identity stays the tail's — which read `auth.json` for it.
    func testALiveReadingDoesNotCostTheRowItsOrganisation() {
        var rollout = ProviderSignals()
        rollout.account = ProviderAccount(email: "someone@example.com", organization: "Master Soft")
        rollout.windows = [UsageWindow(minutes: 300, usedPercent: 30, resetsAt: nil)!]
        rollout.limitsObservedAt = Date(timeIntervalSince1970: 1000)

        var live = ProviderSignals()
        live.account = ProviderAccount(email: "someone@example.com")
        live.windows = [UsageWindow(minutes: 300, usedPercent: 32, resetsAt: nil)!]
        live.limitsObservedAt = Date(timeIntervalSince1970: 2000)

        let merged = CodexSignals.merge(rollout: rollout, live: live)
        XCTAssertEqual(merged.windows.first?.usedPercent, 32)
        XCTAssertEqual(merged.account?.organization, "Master Soft")
    }

    // MARK: - Secrecy

    private func strings(in value: Any) -> [String] {
        var found: [String] = []
        if let text = value as? String { found.append(text) }
        for child in Mirror(reflecting: value).children {
            found.append(contentsOf: strings(in: child.value))
        }
        return found
    }

    private func assertNoToken(
        in value: Any, _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let leaked = strings(in: value).filter {
            $0.contains("access-token") || $0.contains("refresh-token")
        }
        XCTAssertTrue(
            leaked.isEmpty, "\(message): \(leaked.count) string(s) carried a token",
            file: file, line: line)
    }

    /// The readings the frame is built from, taken off readers holding the
    /// credentials and having just spent them on a request.
    func testNoReadingCarriesTheTokenItWasReadWith() async {
        let cli = source(account: nil, percent: 32)
        let linked = source(account: "user-2", percent: 8)
        _ = await cli.refreshOnce {}
        _ = await linked.refreshOnce {}

        let accounts = CodexSignals.perAccount(
            own: ProviderSignals(), signedIn: cli, readers: [cli, linked], links: [:])
        // The sweep has to be able to fail: a walk that reached nothing would
        // report no leak for ever.
        XCTAssertTrue(strings(in: accounts).contains("someone@example.com"))
        assertNoToken(in: accounts, "the per-account readings")
        assertNoToken(in: cli.currentSignals(), "a published reading")
        assertNoToken(in: linked.currentSignals(), "a published reading")
    }

    /// What the login window is handed when one question is left. The
    /// credential stays in the engine until it is answered, so a view that
    /// could be screenshotted never holds one.
    func testTheQuestionHandedToTheAppHoldsNoToken() async throws {
        let outcome = try await CodexAccountLinking.resolve(
            credential: Self.credential(),
            workspaces: { _ in
                [
                    CodexWorkspace(id: "7c31482a", name: "Personal", structure: "personal"),
                    CodexWorkspace(id: "a1b2", name: "Master Soft", structure: "workspace"),
                ]
            })
        guard case .choice(let choice) = outcome else { return XCTFail("expected a question") }
        XCTAssertTrue(strings(in: choice).contains("Master Soft"))
        assertNoToken(in: choice, "the choice handed to the app")
    }

    /// The file that names what each credential is for sits beside them and
    /// holds none: it is readable without the keychain, which is why it exists.
    func testTheLinkIndexHoldsNoToken() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = CodexAccountIndex(url: CodexAccountIndex.defaultURL(in: directory))

        try index.remember(
            CodexAccountLink(
                identity: CodexAccountIdentity(
                    id: "user-1", email: "someone@example.com", plan: "plus"),
                workspace: CodexWorkspace(id: "7c31482a", name: "Personal", structure: "personal")))

        let written = try String(
            contentsOf: CodexAccountIndex.defaultURL(in: directory), encoding: .utf8)
        XCTAssertFalse(written.contains("access-token"))
        XCTAssertTrue(written.contains("someone@example.com"))
        assertNoToken(in: index.load(), "the loaded links")
    }
}
