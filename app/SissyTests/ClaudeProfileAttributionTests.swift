import XCTest

@testable import Sissy

/// Whose account `.claude.json` is answering for.
///
/// The file is Claude Code's and only Claude Code writes it, so a switch made
/// in Sissy reaches the keychain at once and that file not at all. Untested
/// when the switch shipped, which is how a row came to carry one account's id
/// under another account's name — measured 2026-09-16 on the dev build, on a
/// config whose profile had last been fetched four hours earlier.
final class ClaudeProfileAttributionTests: XCTestCase {
    private let activeUUID = "dbab20e1"
    private let staleUUID = "c805523f"

    private var activeIdentity: ClaudeAccountIdentity {
        ClaudeAccountIdentity(
            uuid: activeUUID,
            email: "davide@radonforge.com",
            organization: "Radon Forge",
            organizationType: "claude_team",
            rateLimitTier: "default_claude_max_5x")
    }

    private var credits: ProviderCredits {
        ProviderCredits(
            isEnabled: true, unit: .money(currency: "EUR", exponent: 2),
            usedMinor: 35934, capMinor: 37500, observedAt: Date(timeIntervalSince1970: 0))
    }

    /// The config file's own reading: an identity, a plan already stripped to
    /// the frame's vocabulary, and the seat only this source names.
    private func fileReading(
        profileOwner: String?,
        creditsOwner: String?
    ) -> ClaudeProfileSource.Attributed {
        var signals = ProviderSignals()
        signals.plan = "team"
        signals.planTier = "max_5x"
        signals.account = ProviderAccount(
            email: "davide.tacchini@mastersoft.it",
            organization: "Master Soft Srl",
            seat: "team_tier_1")
        signals.credits = credits
        return ClaudeProfileSource.Attributed(
            signals: signals, profileOwner: profileOwner, creditsOwner: creditsOwner)
    }

    private func snapshot(active: String?) -> ClaudeAccountRegistry.Snapshot {
        ClaudeAccountRegistry.Snapshot(accounts: [activeIdentity], activeUUID: active)
    }

    /// A profile fetched for another account says so, and the identity on the
    /// row comes from the registry instead.
    func testAProfileNamingAnotherAccountGivesWayToTheRegistry() {
        let signals = ClaudeCodeSignals.attributed(
            fileReading(profileOwner: staleUUID, creditsOwner: staleUUID),
            to: snapshot(active: activeUUID))

        XCTAssertEqual(signals.account?.email, "davide@radonforge.com")
        XCTAssertEqual(signals.account?.organization, "Radon Forge")
        XCTAssertEqual(signals.plan, "team")
        XCTAssertEqual(signals.planTier, "max_5x")
    }

    /// Credits stamped with another account are money this row cannot answer
    /// for, so they come off it rather than stand under a name they do not
    /// belong to.
    func testCreditsNamingAnotherAccountAreDropped() {
        let signals = ClaudeCodeSignals.attributed(
            fileReading(profileOwner: staleUUID, creditsOwner: staleUUID),
            to: snapshot(active: activeUUID))

        XCTAssertNil(signals.credits)
    }

    /// The two blocks are written at different moments and are judged apart:
    /// measured 2026-09-16, a usage cache refreshed 39 s after a switch was
    /// still stamped with the account the running CLI had started as.
    func testTheProfileAndTheCreditsAreAttributedSeparately() {
        let signals = ClaudeCodeSignals.attributed(
            fileReading(profileOwner: activeUUID, creditsOwner: staleUUID),
            to: snapshot(active: activeUUID))

        XCTAssertEqual(signals.account?.email, "davide.tacchini@mastersoft.it")
        XCTAssertNil(signals.credits)
    }

    /// A file that belongs to the signed-in account is kept whole: it is the
    /// richer of the two readings, and the only one that names the seat.
    func testAProfileNamingTheActiveAccountKeepsItsSeat() {
        let signals = ClaudeCodeSignals.attributed(
            fileReading(profileOwner: activeUUID, creditsOwner: activeUUID),
            to: snapshot(active: activeUUID))

        XCTAssertEqual(signals.account?.seat, "team_tier_1")
        XCTAssertEqual(signals.credits, credits)
    }

    /// A CLI old enough not to stamp the file names no account, which is no
    /// contradiction: the reading stands exactly as it did before any of this.
    func testAFileNamingNoAccountStands() {
        let signals = ClaudeCodeSignals.attributed(
            fileReading(profileOwner: nil, creditsOwner: nil),
            to: snapshot(active: activeUUID))

        XCTAssertEqual(signals.account?.email, "davide.tacchini@mastersoft.it")
        XCTAssertEqual(signals.credits, credits)
    }

    /// A registry that has identified nobody claims no active account — every
    /// install that never switched, and every engine built without one.
    /// Nothing may be discarded on its word.
    func testNoActiveAccountDiscardsNothing() {
        let signals = ClaudeCodeSignals.attributed(
            fileReading(profileOwner: staleUUID, creditsOwner: staleUUID),
            to: ClaudeAccountRegistry.Snapshot(accounts: [], activeUUID: nil))

        XCTAssertEqual(signals.account?.email, "davide.tacchini@mastersoft.it")
        XCTAssertEqual(signals.credits, credits)
    }

    /// Both owners are the vendor's own stamps on its own blocks, read off
    /// the file rather than derived from anything beside it.
    func testBothOwnersAreReadFromTheFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attribution-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(
            """
            {"oauthAccount":{"accountUuid":"\(staleUUID)","organizationType":"claude_team"},\
            "cachedUsageUtilization":{"accountUuid":"\(activeUUID)","fetchedAtMs":0,\
            "utilization":{}}}
            """.utf8
        ).write(to: url)

        let source = ClaudeProfileSource(url: url)
        source.refresh()

        let reading = source.currentAttributed()
        XCTAssertEqual(reading.profileOwner, staleUUID)
        XCTAssertEqual(reading.creditsOwner, activeUUID)
    }
}
