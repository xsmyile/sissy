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
    /// at 29% and 83%. The count stays and the button does not.
    func testAResetTheVendorWouldNotApplyIsNotUsable() {
        let row = codex(resets: LimitResets(available: 1, applicable: 0)).resets
        XCTAssertEqual(row?.headline, "1 available")
        XCTAssertEqual(row?.usable, false)
    }

    func testWithoutAnApplicableCountTheResetIsUsable() {
        XCTAssertEqual(codex(resets: LimitResets(available: 1, applicable: nil)).resets?.usable, true)
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
        XCTAssertEqual(row.resetTarget, CodexResetTarget(account: nil))
    }

    /// On a Mac whose `codex` is signed out the row is the lone linked
    /// account's reading, so a press on it spends that account's reset.
    func testTheRowOfALoneLinkedAccountSpendsThatAccountsCredential() {
        let row = codex(
            resets: LimitResets(available: 1, applicable: 1),
            accounts: [account("user-2", signedIn: false, resets: nil)])
        XCTAssertEqual(row.resetTarget, CodexResetTarget(account: "user-2"))
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
        XCTAssertEqual(byID["user-1"]?.resetTarget, CodexResetTarget(account: nil))
        XCTAssertEqual(byID["user-2"]?.resetTarget, CodexResetTarget(account: "user-2"))
        XCTAssertEqual(byID["user-2"]?.resets?.headline, "3 available")
    }

    func testAProviderWithoutResetsHasNoTarget() {
        let slice = ProviderSlice(id: ProviderID.claudeCode, tokens: 0, cost: 0)
        XCTAssertNil(UsagePanelSnapshot.make(frame: frame(slice)).providers[0].resetTarget)
    }

    // MARK: - The words

    func testTheConfirmationSaysWhatWaitingWouldCost() {
        XCTAssertEqual(
            CodexResetCopy.confirmBody(
                available: 2, naturalReset: (label: "Weekly", countdown: "in 3d 4h")),
            "Both windows go back to zero. This spends 1 of 2. Weekly resets on its own in 3d 4h.")
        XCTAssertEqual(
            CodexResetCopy.confirmBody(available: 1, naturalReset: nil),
            "Both windows go back to zero. This spends 1 of 1.")
    }

    func testEachAnswerIsItsOwnSentence() {
        let outcomes: [CodexResetOutcome] = [
            .reset, .nothingToReset, .noCredit, .unconfirmed, .refused, .unavailable,
        ]
        XCTAssertEqual(Set(outcomes.map(CodexResetCopy.outcome)).count, outcomes.count)
        XCTAssertEqual(CodexResetCopy.outcome(.reset), "Done. Both windows are back to zero.")
        XCTAssertEqual(
            CodexResetCopy.outcome(.unconfirmed),
            "No answer from OpenAI. Trying again cannot spend a second reset.")
    }
}
