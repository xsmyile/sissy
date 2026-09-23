import XCTest

@testable import Sissy

/// What renewing a linked Codex account's credential is allowed to lose, which
/// is nothing a caller can cause: OpenAI rotates the refresh token on every
/// renewal, so a renewal that lands and is not filed is a link that is gone.
final class CodexRenewalTests: XCTestCase {
    private static let account = "user-1"
    private static let chosenWorkspace = "7c31482a"

    private static func credential(
        access: String = "access-old",
        refresh: String? = "refresh-old",
        workspace: String? = chosenWorkspace,
        expiresAt: Date? = .distantPast
    ) -> CodexCredential {
        CodexCredential(
            accessToken: access, refreshToken: refresh, idToken: nil,
            accountId: workspace, userId: account, email: "someone@example.com",
            plan: "plus", expiresAt: expiresAt)
    }

    private static let renewed = credential(
        access: "access-new", refresh: "refresh-new", expiresAt: .distantFuture)

    /// The keychain item, in memory. `failures` is how many saves throw
    /// before one lands.
    private final class Keychain: @unchecked Sendable {
        let items = LockedValue<[String: CodexCredential]>([:])
        let failures = LockedValue(0)
        let saves = LockedValue(0)
        /// Access tokens whose save always throws, for a renewal the keychain
        /// refuses while a later one lands.
        let refusing = LockedValue<Set<String>>([])

        init(holding credential: CodexCredential) {
            items.store([CodexRenewalTests.account: credential])
        }

        func load(_ account: String) -> CodexCredentialReading {
            items.load()[account].map { .found($0) } ?? .missing
        }

        func save(_ credential: CodexCredential, _ account: String) throws {
            saves.update { $0 += 1 }
            var failing = false
            failures.update {
                failing = $0 > 0
                if failing { $0 -= 1 }
            }
            if failing || refusing.load().contains(credential.accessToken) {
                throw CodexAccountStoreError.keychain(errSecInteractionNotAllowed)
            }
            items.update { $0[account] = credential }
        }
    }

    /// Holds a renewal at the token endpoint until the test lets it answer.
    private actor Gate {
        private var entered: [CheckedContinuation<Void, Never>] = []
        private var released: CheckedContinuation<Void, Never>?
        private var isOpen = false
        private var arrivals = 0

        func arrive() async {
            arrivals += 1
            entered.forEach { $0.resume() }
            entered = []
            guard !isOpen else { return }
            await withCheckedContinuation { released = $0 }
        }

        func waitForArrival() async {
            guard arrivals == 0 else { return }
            await withCheckedContinuation { entered.append($0) }
        }

        func open() {
            isOpen = true
            released?.resume()
            released = nil
        }
    }

    private static func renewal(
        keychain: Keychain,
        loads: AsyncStream<Void>.Continuation? = nil,
        renew: @escaping CodexRenewal.Renew
    ) -> CodexRenewal {
        CodexRenewal(
            load: { account, _ in
                loads?.yield()
                return keychain.load(account)
            },
            save: { try keychain.save($0, $1) },
            renew: renew,
            pause: { _ in },
            jitter: { 1 })
    }

    // MARK: - The workspace the user chose

    /// An id_token naming another workspace, which is what the vendor's
    /// default claim looks like on a login holding two.
    private static func idToken(workspace: String) -> String {
        let claims: [String: Any] = [
            "email": "someone@example.com",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": workspace, "chatgpt_user_id": account,
            ],
        ]
        let payload = (try? JSONSerialization.data(withJSONObject: claims)) ?? Data()
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(encoded).signature"
    }

    private static func reply(
        status: Int, body: String = "{}", headers: [String: String] = [:]
    ) -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: nil, headerFields: headers))
            return (Data(body.utf8), response)
        }
    }

    func testARenewalKeepsTheWorkspaceTheLinkChose() async throws {
        let body = """
            {"access_token": "access-new", "refresh_token": "refresh-new",
             "id_token": "\(Self.idToken(workspace: "vendor-default"))"}
            """
        let result = try await CodexOAuth.refresh(
            Self.credential(), send: Self.reply(status: 200, body: body))
        XCTAssertEqual(result.accountId, Self.chosenWorkspace)
    }

    // MARK: - What the token endpoint's answer means

    private func renewalFailure(
        _ send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) async -> CodexOAuth.RenewalFailure? {
        do {
            _ = try await CodexOAuth.refresh(Self.credential(), send: send)
            return nil
        } catch {
            return error as? CodexOAuth.RenewalFailure
        }
    }

    func testAGrantTheEndpointRejectsEndsTheLink() async {
        let failure = await renewalFailure(
            Self.reply(status: 400, body: #"{"error": "invalid_grant"}"#))
        XCTAssertEqual(failure, .rejected)
    }

    func testAnEndpointThatIsDownDefersTheRenewal() async {
        let failure = await renewalFailure(Self.reply(status: 503))
        XCTAssertEqual(failure, .deferred(retryAfter: nil))
    }

    func testAnUnauthorisedRenewalEndsTheLink() async {
        let failure = await renewalFailure(Self.reply(status: 401))
        XCTAssertEqual(failure, .rejected)
    }

    /// A 400 is not a verdict on the grant unless it says so: a malformed
    /// request is Sissy's own, and the token it carried is still good.
    func testABadRequestThatNamesNoGrantDefersTheRenewal() async {
        let failure = await renewalFailure(
            Self.reply(status: 400, body: #"{"error": "invalid_request"}"#))
        XCTAssertEqual(failure, .deferred(retryAfter: nil))
    }

    func testARateLimitedRenewalWaitsAsLongAsTheVendorSays() async {
        let failure = await renewalFailure(
            Self.reply(status: 429, headers: ["Retry-After": "900"]))
        XCTAssertEqual(failure, .deferred(retryAfter: 900))
    }

    func testANetworkThatIsNotThereDefersTheRenewal() async {
        let failure = await renewalFailure { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(failure, .deferred(retryAfter: nil))
    }

    // MARK: - What a reader is handed

    func testARejectedRenewalReadsAsExpired() async {
        let keychain = Keychain(holding: Self.credential())
        let renewal = Self.renewal(keychain: keychain) { _ in
            throw CodexOAuth.RenewalFailure.rejected
        }
        let reading = await renewal.supply(account: Self.account, allowingInteraction: false)
        XCTAssertEqual(reading, .expired)
    }

    /// A transient failure keeps the last reading on the row, which is what
    /// `unreadable` means to a reader, and does not ask again before the
    /// backoff it earned has run.
    func testADeferredRenewalKeepsTheReadingAndBacksOff() async {
        let keychain = Keychain(holding: Self.credential())
        let requests = LockedValue(0)
        let renewal = Self.renewal(keychain: keychain) { _ in
            requests.update { $0 += 1 }
            throw CodexOAuth.RenewalFailure.deferred(retryAfter: nil)
        }
        let first = await renewal.supply(account: Self.account, allowingInteraction: false)
        let second = await renewal.supply(account: Self.account, allowingInteraction: false)
        guard case .unreadable = first, case .unreadable = second else {
            return XCTFail("a renewal that could not reach OpenAI is not a spent one")
        }
        XCTAssertEqual(requests.load(), 1)
    }

    func testARenewalIsFiledBeforeItIsHandedOver() async {
        let keychain = Keychain(holding: Self.credential())
        let renewal = Self.renewal(keychain: keychain) { _ in Self.renewed }
        let reading = await renewal.supply(account: Self.account, allowingInteraction: false)
        XCTAssertEqual(reading, .found(Self.renewed))
        XCTAssertEqual(keychain.items.load()[Self.account], Self.renewed)
    }

    // MARK: - What a caller cannot cause

    /// The Refresh button, a provider toggle and a quit all cancel the reader
    /// that asked. The rotation has happened at OpenAI by then, so the renewal
    /// runs to its save whatever became of the caller.
    func testACancelledCallerStillFilesTheRenewal() async {
        let keychain = Keychain(holding: Self.credential())
        let gate = Gate()
        let renewal = Self.renewal(keychain: keychain) { _ in
            await gate.arrive()
            return Self.renewed
        }
        let caller = Task {
            await renewal.supply(account: Self.account, allowingInteraction: false)
        }
        await gate.waitForArrival()
        caller.cancel()
        await gate.open()
        _ = await caller.value
        XCTAssertEqual(keychain.items.load()[Self.account], Self.renewed)
    }

    /// Two readers of one account, or a poll and a Refresh, would redeem the
    /// same one-time token twice, and the second redemption is what the
    /// vendor answers by revoking the family.
    func testTwoCallersShareOneRenewal() async {
        let keychain = Keychain(holding: Self.credential())
        let gate = Gate()
        let requests = LockedValue(0)
        let (loads, loaded) = AsyncStream<Void>.makeStream()
        let renewal = Self.renewal(keychain: keychain, loads: loaded) { _ in
            requests.update { $0 += 1 }
            await gate.arrive()
            return Self.renewed
        }
        var arrivals = loads.makeAsyncIterator()
        let first = Task { await renewal.supply(account: Self.account, allowingInteraction: false) }
        await gate.waitForArrival()
        _ = await arrivals.next()
        let second = Task {
            await renewal.supply(account: Self.account, allowingInteraction: false)
        }
        _ = await arrivals.next()
        await gate.open()
        let answers = [await first.value, await second.value]
        XCTAssertEqual(answers, [.found(Self.renewed), .found(Self.renewed)])
        XCTAssertEqual(requests.load(), 1)
    }

    // MARK: - A save that fails

    /// The item still holds the refresh token OpenAI has just retired, so
    /// handing the reader that one back is handing it a dead link.
    func testAFailedSaveHandsOverTheRenewalItHolds() async {
        let keychain = Keychain(holding: Self.credential())
        keychain.failures.store(Int.max)
        let renewal = Self.renewal(keychain: keychain) { _ in Self.renewed }
        _ = await renewal.supply(account: Self.account, allowingInteraction: false)
        let later = await renewal.supply(account: Self.account, allowingInteraction: false)
        XCTAssertEqual(later, .found(Self.renewed))
    }

    func testAFailedSaveIsRetriedUntilItLands() async {
        let keychain = Keychain(holding: Self.credential())
        keychain.failures.store(2)
        let renewal = Self.renewal(keychain: keychain) { _ in Self.renewed }
        _ = await renewal.supply(account: Self.account, allowingInteraction: false)
        await renewal.settle(account: Self.account)
        XCTAssertEqual(keychain.items.load()[Self.account], Self.renewed)
        XCTAssertEqual(keychain.saves.load(), 3)
    }

    /// Bounded, because a keychain that refuses every write refuses the
    /// hundredth one too: the renewal stays in memory for the reader either
    /// way, and the next poll starts a fresh round.
    func testASaveThatNeverLandsStopsRetrying() async {
        let keychain = Keychain(holding: Self.credential())
        keychain.failures.store(Int.max)
        let renewal = Self.renewal(keychain: keychain) { _ in Self.renewed }
        _ = await renewal.supply(account: Self.account, allowingInteraction: false)
        await renewal.settle(account: Self.account)
        XCTAssertEqual(keychain.saves.load(), 1 + CodexRenewal.saveAttempts)
    }

    /// An account unlinked while its renewal was out must not come back when
    /// the renewal lands: a save after the delete re-creates the item.
    func testAnAccountForgottenMidRenewalIsNotFiledAgain() async {
        let keychain = Keychain(holding: Self.credential())
        let gate = Gate()
        let renewal = Self.renewal(keychain: keychain) { _ in
            await gate.arrive()
            return Self.renewed
        }
        let caller = Task {
            await renewal.supply(account: Self.account, allowingInteraction: false)
        }
        await gate.waitForArrival()
        await renewal.forget(account: Self.account)
        keychain.items.store([:])
        await gate.open()
        _ = await caller.value
        XCTAssertNil(keychain.items.load()[Self.account])
    }

    /// A renewal that is filed supersedes one still held unsaved: the held one
    /// carries a refresh token the later renewal has spent, so handing it
    /// over, or filing it on retry, is handing over a dead link.
    func testAFiledRenewalReplacesAnEarlierUnsavedOne() async {
        let keychain = Keychain(holding: Self.credential())
        let spentSoon = Self.credential(access: "access-mid", refresh: "refresh-mid")
        keychain.refusing.store([spentSoon.accessToken])
        let replies = LockedValue([spentSoon, Self.renewed])
        let renewal = Self.renewal(keychain: keychain) { _ in
            var next: CodexCredential?
            replies.update { next = $0.isEmpty ? nil : $0.removeFirst() }
            guard let next else { throw CodexOAuth.RenewalFailure.rejected }
            return next
        }
        _ = await renewal.supply(account: Self.account, allowingInteraction: false)
        await renewal.settle(account: Self.account)
        _ = await renewal.supply(account: Self.account, allowingInteraction: false)
        await renewal.settle(account: Self.account)
        let later = await renewal.supply(account: Self.account, allowingInteraction: false)
        XCTAssertEqual(later, .found(Self.renewed))
        XCTAssertEqual(keychain.items.load()[Self.account], Self.renewed)
    }

    // MARK: - A link replaced while its renewal was out

    /// The rejection is of the grant the old link held. Read as `.expired` it
    /// told the reader the link it now serves had ended, one sign-in after the
    /// user made it.
    func testARejectionForAReplacedLinkDoesNotEndTheNewOne() async {
        let keychain = Keychain(holding: Self.credential())
        let gate = Gate()
        let renewal = Self.renewal(keychain: keychain) { _ in
            await gate.arrive()
            throw CodexOAuth.RenewalFailure.rejected
        }
        let caller = Task {
            await renewal.supply(account: Self.account, allowingInteraction: false)
        }
        await gate.waitForArrival()
        await renewal.forget(account: Self.account)
        keychain.items.store([Self.account: Self.renewed])
        await gate.open()
        let reading = await caller.value
        XCTAssertNotEqual(reading, .expired)
    }

    /// A backoff earned by the old link's grant is not the new link's: its
    /// first renewal goes out at once.
    func testADeferralForAReplacedLinkDoesNotHoldTheNewOne() async {
        let keychain = Keychain(holding: Self.credential())
        let gate = Gate()
        let requests = LockedValue(0)
        let renewal = Self.renewal(keychain: keychain) { _ in
            requests.update { $0 += 1 }
            await gate.arrive()
            throw CodexOAuth.RenewalFailure.deferred(retryAfter: nil)
        }
        let caller = Task {
            await renewal.supply(account: Self.account, allowingInteraction: false)
        }
        await gate.waitForArrival()
        await renewal.forget(account: Self.account)
        keychain.items.store([Self.account: Self.credential(access: "access-relinked")])
        await gate.open()
        _ = await caller.value
        _ = await renewal.supply(account: Self.account, allowingInteraction: false)
        XCTAssertEqual(requests.load(), 2)
    }

    // MARK: - A token refused before it expired

    /// OpenAI can revoke an access token early. The refresh token behind it
    /// may still be good, so a refusal is renewed once whatever the clock says.
    func testARefusedTokenIsRenewedAlthoughItHasNotExpired() async {
        let live = Self.credential(expiresAt: .distantFuture)
        let keychain = Keychain(holding: live)
        let requests = LockedValue(0)
        let renewal = Self.renewal(keychain: keychain) { _ in
            requests.update { $0 += 1 }
            return Self.renewed
        }
        let reading = await renewal.renewRefused(account: Self.account, refused: live)
        XCTAssertEqual(reading, .found(Self.renewed))
        XCTAssertEqual(keychain.items.load()[Self.account], Self.renewed)
        XCTAssertEqual(requests.load(), 1)
    }

    /// Another reader of the account renewed it already, so the refused token
    /// is not the one on file and redeeming again would spend a live grant.
    func testARefusalOfATokenAlreadyReplacedIsNotRenewedAgain() async {
        let keychain = Keychain(holding: Self.renewed)
        let requests = LockedValue(0)
        let renewal = Self.renewal(keychain: keychain) { _ in
            requests.update { $0 += 1 }
            return Self.credential(access: "access-third", expiresAt: .distantFuture)
        }
        let reading = await renewal.renewRefused(
            account: Self.account, refused: Self.credential(expiresAt: .distantFuture))
        XCTAssertEqual(reading, .found(Self.renewed))
        XCTAssertEqual(requests.load(), 0)
    }

    func testARefusedTokenWhoseRenewalIsRejectedReadsAsExpired() async {
        let live = Self.credential(expiresAt: .distantFuture)
        let keychain = Keychain(holding: live)
        let renewal = Self.renewal(keychain: keychain) { _ in
            throw CodexOAuth.RenewalFailure.rejected
        }
        let reading = await renewal.renewRefused(account: Self.account, refused: live)
        XCTAssertEqual(reading, .expired)
    }
}
