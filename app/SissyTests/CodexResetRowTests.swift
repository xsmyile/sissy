import XCTest

@testable import Sissy

/// How a Codex account's resets read on its page, and what the page offers.
final class CodexResetRowTests: XCTestCase {
    private static let expiry = Date(timeIntervalSince1970: 1_792_693_897)

    private func frame(_ slice: ProviderSlice) -> FrameData {
        FrameData(
            tokens: slice.tokens, cost: slice.cost, burn: nil, providers: [slice],
            keepAwake: .off, history: [:], projects: [])
    }

    private func codex(resets: LimitResets?, accounts: [AccountSignals] = [])
        -> UsagePanelSnapshot.ProviderRow
    {
        var signals = ProviderSignals()
        signals.resets = resets
        signals.accounts = accounts
        let slice = ProviderSlice(id: ProviderID.codex, tokens: 0, cost: 0, signals: signals)
        return UsagePanelSnapshot.make(frame: frame(slice)).providers[0]
    }

    private func account(_ id: String, signedIn: Bool, resets: LimitResets?) -> AccountSignals {
        AccountSignals(
            id: id, account: ProviderAccount(email: "\(id)@example.com"), plan: "plus",
            planTier: nil, resets: resets, isSignedIn: signedIn)
    }

    // MARK: - The row

    /// No count is a reading nobody took, and a count of zero is a block that
    /// never changes: neither gets a row.
    func testNoRowWithoutAResetToSpend() {
        XCTAssertNil(codex(resets: nil).resets)
        XCTAssertNil(codex(resets: LimitResets(available: 0, applicable: 0)).resets)
    }

    func testTheHeadlineIsTheVendorsCount() {
        XCTAssertEqual(
            codex(resets: LimitResets(available: 2, applicable: nil)).resets?.headline,
            "2 available")
    }

    /// Measured 2026-09-24: one reset held, none applicable with the windows
    /// at 29% and 83%. The row stays, and says the vendor counts none needed.
    func testAResetTheVendorWouldNotApplyKeepsItsRow() {
        let row = codex(resets: LimitResets(available: 1, applicable: 0)).resets
        XCTAssertEqual(row?.headline, "1 available")
        XCTAssertEqual(row?.appliesNow, false)
    }

    func testWithoutAnApplicableCountTheResetIsNeeded() {
        XCTAssertEqual(
            codex(resets: LimitResets(available: 1, applicable: nil)).resets?.appliesNow, true)
    }

    func testTheCaptionCarriesTheVendorsTitleAndTheExpiry() {
        let row = codex(
            resets: LimitResets(
                available: 1, applicable: 1, nextExpiry: Self.expiry,
                title: "Full reset (Weekly + 5 hr)")
        ).resets
        let day = Self.expiry.formatted(.dateTime.day().month(.abbreviated))
        XCTAssertEqual(row?.caption, "Full reset (Weekly + 5 hr) · expires \(day)")
    }

    func testAResetWithNoTitleOrDateIsAFullReset() {
        XCTAssertEqual(
            codex(resets: LimitResets(available: 1, applicable: 1)).resets?.caption, "Full reset")
    }

    // MARK: - Whose credential a press spends

    func testTheRowSpendsTheCLIsCredential() {
        let row = codex(
            resets: LimitResets(available: 1, applicable: 1),
            accounts: [account("user-1", signedIn: true, resets: nil)])
        XCTAssertEqual(row.resetTarget, LimitResetTarget(provider: ProviderID.codex, account: nil))
    }

    /// On a Mac whose `codex` is signed out the row is the lone linked
    /// account's reading, so a press on it spends that account's reset.
    func testTheRowOfALoneLinkedAccountSpendsThatAccountsCredential() {
        let row = codex(
            resets: LimitResets(available: 1, applicable: 1),
            accounts: [account("user-2", signedIn: false, resets: nil)])
        XCTAssertEqual(row.resetTarget, LimitResetTarget(provider: ProviderID.codex, account: "user-2"))
    }

    func testEachAccountEntrySpendsItsOwnCredential() {
        let entries = UsagePanelSnapshot.accountEntries(
            readings: [
                account("user-1", signedIn: true, resets: LimitResets(available: 1, applicable: 1)),
                account("user-2", signedIn: false, resets: LimitResets(available: 3, applicable: 0)),
            ],
            known: ClaudeAccountRegistry.Snapshot(),
            provider: ProviderID.codex,
            reading: .used,
            now: Date())
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        XCTAssertEqual(
            byID["user-1"]?.resetTarget, LimitResetTarget(provider: ProviderID.codex, account: nil))
        XCTAssertEqual(
            byID["user-2"]?.resetTarget, LimitResetTarget(provider: ProviderID.codex, account: "user-2"))
        XCTAssertEqual(byID["user-2"]?.resets?.headline, "3 available")
    }

    func testAProviderWithoutResetsHasNoTarget() {
        let slice = ProviderSlice(id: "opencode", tokens: 0, cost: 0)
        XCTAssertNil(UsagePanelSnapshot.make(frame: frame(slice)).providers[0].resetTarget)
    }

    // MARK: - The words

    func testTheConfirmationSaysWhatWaitingWouldCost() {
        XCTAssertEqual(
            LimitResetCopy.confirmBody(
                available: 2, naturalReset: (label: "Weekly", countdown: "in 3d 4h"),
                appliesNow: true, provider: ProviderID.codex),
            "Both windows go back to zero. This spends 1 of 2. Weekly resets on its own in 3d 4h.")
        XCTAssertEqual(
            LimitResetCopy.confirmBody(
                available: 1, naturalReset: nil, appliesNow: true, provider: ProviderID.codex),
            "Both windows go back to zero. This spends 1 of 1.")
    }

    func testTheConfirmationSaysWhenOpenAICountsNoneNeeded() {
        XCTAssertEqual(
            LimitResetCopy.confirmBody(
                available: 1, naturalReset: (label: "Weekly", countdown: "in 1d 12h"),
                appliesNow: false, provider: ProviderID.codex),
            "Both windows go back to zero. This spends 1 of 1. Weekly resets on its own in 1d 12h. "
                + "OpenAI does not count one as needed yet and may decline it, which spends nothing.")
    }

    func testEachAnswerIsItsOwnSentence() {
        let outcomes: [LimitResetOutcome] = [
            .reset, .nothingToReset, .noCredit, .unconfirmed, .refused, .unavailable,
        ]
        XCTAssertEqual(
            Set(outcomes.map { LimitResetCopy.outcome($0, provider: ProviderID.codex) }).count, outcomes.count
        )
        XCTAssertEqual(
            LimitResetCopy.outcome(.reset, provider: ProviderID.codex), "Done. Both windows are back to zero."
        )
        XCTAssertEqual(
            LimitResetCopy.outcome(.nothingToReset, provider: ProviderID.codex),
            "Nothing was spent: OpenAI says this account does not need a reset right now.")
        XCTAssertEqual(
            LimitResetCopy.outcome(.unconfirmed, provider: ProviderID.codex),
            "No answer from OpenAI. Trying again cannot spend a second reset.")
    }
}
