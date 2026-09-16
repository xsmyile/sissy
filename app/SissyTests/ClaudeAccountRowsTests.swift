import XCTest

@testable import Sissy

/// Which accounts get a reading, a row and a gauge.
///
/// None of the three had a test, which is how a single-source install with a
/// second archived account put "no live source" under the account the CLI was
/// signed into and reading fine — measured on the dev build, 2026-09-16.
final class ClaudeAccountRowsTests: XCTestCase {
    private let signedInUUID = "c805523f"
    private let archivedUUID = "dbab20e1"

    private func window(_ percent: Double) -> UsageWindow {
        UsageWindow(minutes: 300, usedPercent: percent, resetsAt: .distantFuture)!
    }

    private func identity(_ uuid: String, organization: String) -> ClaudeAccountIdentity {
        ClaudeAccountIdentity(
            uuid: uuid,
            email: "\(organization.lowercased())@example.com",
            organization: organization,
            organizationType: "claude_team",
            rateLimitTier: nil)
    }

    private func reading(observedAt: Date) -> ProviderSignals {
        var signals = ProviderSignals(
            windows: [window(18)], limitsState: .quiet, limitsObservedAt: observedAt)
        signals.account = ProviderAccount(
            email: "master@example.com", organization: "Master Soft Srl", seat: nil)
        signals.plan = "team"
        return signals
    }

    // MARK: The reading

    /// The signed-in account is published whether or not a second one is
    /// readable. Withholding a lone reading left the account the CLI was on
    /// with no source at all as soon as a second account was archived.
    func testTheSignedInAccountIsPublishedAsTheOnlyReading() {
        let now = Date()
        let accounts = ClaudeCodeSignals.perAccount(
            reading(observedAt: now),
            sources: [],
            known: ClaudeAccountRegistry.Snapshot(
                accounts: [
                    identity(signedInUUID, organization: "Master Soft Srl"),
                    identity(archivedUUID, organization: "Radon Forge"),
                ],
                activeUUID: signedInUUID))

        XCTAssertEqual(accounts.map(\.id), [signedInUUID])
        XCTAssertEqual(accounts.first?.windows.map(\.usedPercent), [18])
        XCTAssertEqual(accounts.first?.limitsObservedAt, now)
        XCTAssertEqual(accounts.first?.isSignedIn, true)
    }

    /// No signed-in account and no session is no reading, rather than an
    /// entry standing in for one.
    func testNoSourceProducesNoReading() {
        XCTAssertTrue(
            ClaudeCodeSignals.perAccount(
                ProviderSignals(),
                sources: [],
                known: ClaudeAccountRegistry.Snapshot(accounts: [], activeUUID: nil)
            ).isEmpty)
    }

    // MARK: The rows

    private func entries(readings: [AccountSignals], known: [ClaudeAccountIdentity], now: Date)
        -> [UsagePanelSnapshot.AccountEntry]
    {
        UsagePanelSnapshot.accountEntries(
            readings: readings,
            known: ClaudeAccountRegistry.Snapshot(accounts: known, activeUUID: signedInUUID),
            reading: .used,
            now: now)
    }

    /// An account with a live source is readable even while the account
    /// beside it, archived and unlinked, is not.
    func testAnArchivedAccountDoesNotMakeTheReadOneUnreadable() {
        let now = Date()
        let rows = entries(
            readings: ClaudeCodeSignals.perAccount(
                reading(observedAt: now),
                sources: [],
                known: ClaudeAccountRegistry.Snapshot(
                    accounts: [], activeUUID: signedInUUID)),
            known: [
                identity(signedInUUID, organization: "Master Soft Srl"),
                identity(archivedUUID, organization: "Radon Forge"),
            ],
            now: now)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.id == signedInUUID }?.isReadable, true)
        XCTAssertEqual(rows.first { $0.id == signedInUUID }?.windows.map(\.percent), [18])
        XCTAssertEqual(rows.first { $0.id == archivedUUID }?.isReadable, false)
        XCTAssertEqual(rows.first { $0.id == archivedUUID }?.isSwitchable, true)
    }

    /// An unreadable account answers for nothing of its own, which is what
    /// the page must not fill in from the row beside it.
    func testAnUnreadableAccountCarriesNoReading() {
        let now = Date()
        let rows = entries(
            readings: [],
            known: [
                identity(signedInUUID, organization: "Master Soft Srl"),
                identity(archivedUUID, organization: "Radon Forge"),
            ],
            now: now)

        let archived = rows.first { $0.id == archivedUUID }
        XCTAssertEqual(archived?.windows, [])
        XCTAssertNil(archived?.windowsCaption)
        XCTAssertNil(archived?.credits)
    }

    /// An account reached through a session alone is named by its link.
    ///
    /// It has no archived CLI credential, so the account index holds nothing
    /// for it: without the link its reading carries no identity at all and the
    /// row it draws is labelled with the raw Anthropic uuid — the ordinary
    /// case the moment sessions can be linked rather than imported.
    func testALinkNamesAnAccountTheAccountIndexDoesNot() {
        let sessionOnly = ClaudeAccountIdentity(
            uuid: archivedUUID, email: "davide@radonforge.com", organization: "Radon Forge",
            organizationType: "claude_team", rateLimitTier: nil)
        let source = ClaudeWebSource(
            account: archivedUUID,
            sessionSource: { _ in .absent },
            fetchSource: { _, _ in throw ClaudeLimitsError.malformedPayload })

        let accounts = ClaudeCodeSignals.perAccount(
            ProviderSignals(),
            sources: [source],
            known: ClaudeAccountRegistry.Snapshot(accounts: [], activeUUID: signedInUUID),
            links: [archivedUUID: ClaudeWebLink(identity: sessionOnly, organization: "org-2")])

        let linked = accounts.first { $0.id == archivedUUID }
        XCTAssertEqual(linked?.account?.email, "davide@radonforge.com")
        XCTAssertEqual(linked?.account?.organization, "Radon Forge")
        XCTAssertEqual(linked?.plan, "team")
    }

    /// An archived account's plan reaches the row in the vocabulary the
    /// formatter words.
    ///
    /// The vendor prefixes both tokens and `.claude.json`'s reader strips
    /// them, so passing an identity's through raw labelled every account but
    /// the signed-in one "Claude Team", metered at "Default Claude Max 5x".
    func testAnArchivedAccountsPlanIsStrippedToTheFramesVocabulary() {
        let source = ClaudeWebSource(
            account: archivedUUID,
            sessionSource: { _ in .absent },
            fetchSource: { _, _ in throw ClaudeLimitsError.malformedPayload })

        let accounts = ClaudeCodeSignals.perAccount(
            ProviderSignals(),
            sources: [source],
            known: ClaudeAccountRegistry.Snapshot(
                accounts: [
                    ClaudeAccountIdentity(
                        uuid: archivedUUID, email: nil, organization: "Radon Forge",
                        organizationType: "claude_team",
                        rateLimitTier: "default_claude_max_5x")
                ],
                activeUUID: signedInUUID))

        let archived = accounts.first { $0.id == archivedUUID }
        XCTAssertEqual(archived?.plan, "team")
        XCTAssertEqual(archived?.planTier, "max_5x")
    }

    /// One account is no list: the picker is a control over a choice, and a
    /// single-account install must render exactly as it did before there were
    /// accounts at all.
    func testOneKnownAccountIsNoList() {
        let now = Date()
        XCTAssertTrue(
            entries(
                readings: ClaudeCodeSignals.perAccount(
                    reading(observedAt: now),
                    sources: [],
                    known: ClaudeAccountRegistry.Snapshot(
                        accounts: [], activeUUID: signedInUUID)),
                known: [identity(signedInUUID, organization: "Master Soft Srl")],
                now: now
            ).isEmpty)
    }
}
