import XCTest

@testable import Sissy

/// One row per vendor, and which of that vendor's accounts it draws.
///
/// The first shape was a row per account, and it was wrong in the way a user
/// sees rather than the way a test does: two rows both headed "Claude", told
/// apart by a directory name, in a panel that got taller with every account.
/// What identifies an account — its address, its organisation, its plan — is
/// already on the row, so the vendor keeps one row and the account is picked
/// on the line that names it.
final class PanelAccountPickerTests: XCTestCase {
    private func frame(_ providers: [ProviderSlice]) -> FrameData {
        FrameData(
            tokens: providers.reduce(0) { $0 + $1.tokens },
            cost: providers.reduce(Decimal(0)) { $0 + $1.cost },
            burn: nil,
            providers: providers,
            keepAwake: .off,
            history: nil,
            projects: []
        )
    }

    private func slice(_ id: String, tokens: Int, email: String?) -> ProviderSlice {
        ProviderSlice(
            id: id,
            tokens: tokens,
            cost: Decimal(tokens) / 1000,
            account: ProviderAccount(email: email)
        )
    }

    private var twoClaudeAccountsAndCodex: FrameData {
        frame([
            slice(ProviderID.claudeCode, tokens: 1000, email: "me@personal.example"),
            slice("claude-code:work", tokens: 2000, email: "me@work.example"),
            slice(ProviderID.codex, tokens: 3000, email: nil),
        ])
    }

    func testAVendorGetsOneRowHoweverManyAccountsItHas() {
        let snapshot = UsagePanelSnapshot.make(frame: twoClaudeAccountsAndCodex)

        XCTAssertEqual(snapshot.providers.map(\.name), ["Claude", "Codex"])
    }

    func testTheFirstAccountIsDrawnUntilOneIsChosen() {
        let snapshot = UsagePanelSnapshot.make(frame: twoClaudeAccountsAndCodex)

        XCTAssertEqual(snapshot.providers.first?.id, ProviderID.claudeCode)
        XCTAssertEqual(snapshot.providers.first?.account?.email, "me@personal.example")
    }

    func testChoosingAnAccountDrawsThatOne() {
        let snapshot = UsagePanelSnapshot.make(
            frame: twoClaudeAccountsAndCodex,
            selected: [ProviderID.claudeCode: "claude-code:work"])

        XCTAssertEqual(snapshot.providers.first?.id, "claude-code:work")
        XCTAssertEqual(snapshot.providers.first?.account?.email, "me@work.example")
        XCTAssertEqual(snapshot.providers.first?.tokens, UsageFormat.tokens(2000))
    }

    /// A preference can outlive the account it names — the user removed it, or
    /// the CLI has not written that home today. The row falls back rather than
    /// disappearing, because a vendor that is metering something always has
    /// something to draw.
    func testAChoiceTheFrameNoLongerCarriesFallsBackToTheFirst() {
        let snapshot = UsagePanelSnapshot.make(
            frame: twoClaudeAccountsAndCodex,
            selected: [ProviderID.claudeCode: "claude-code:gone"])

        XCTAssertEqual(snapshot.providers.first?.id, ProviderID.claudeCode)
    }

    func testEveryAccountOfTheVendorIsOfferedWithTheDrawnOneMarked() {
        let snapshot = UsagePanelSnapshot.make(
            frame: twoClaudeAccountsAndCodex,
            selected: [ProviderID.claudeCode: "claude-code:work"])

        let choices = snapshot.providers.first?.accounts ?? []
        XCTAssertEqual(choices.map(\.label), ["me@personal.example", "me@work.example"])
        XCTAssertEqual(choices.filter(\.isSelected).map(\.id), ["claude-code:work"])
    }

    /// A picker over one choice is a control that does nothing, and most
    /// installs hold exactly one account per vendor.
    func testAVendorWithOneAccountOffersNoChoices() {
        let snapshot = UsagePanelSnapshot.make(frame: twoClaudeAccountsAndCodex)

        XCTAssertEqual(snapshot.providers.last?.name, "Codex")
        XCTAssertTrue(snapshot.providers.last?.accounts.isEmpty ?? false)
    }

    /// The day's headline stays every account's, because the money was spent
    /// whichever row is on screen.
    func testTheDayStillSumsEveryAccount() {
        let snapshot = UsagePanelSnapshot.make(
            frame: twoClaudeAccountsAndCodex,
            selected: [ProviderID.claudeCode: "claude-code:work"])

        XCTAssertEqual(snapshot.tokens, UsageFormat.tokens(6000))
    }

    /// An account nothing has read yet still has to be pickable: it is the one
    /// a user has just added and is looking for.
    func testAnAccountWithNoReadingIsNamedByItsKey() {
        let snapshot = UsagePanelSnapshot.make(
            frame: frame([
                slice(ProviderID.claudeCode, tokens: 1000, email: "me@personal.example"),
                slice("claude-code:work", tokens: 0, email: nil),
            ]))

        XCTAssertEqual(
            snapshot.providers.first?.accounts.map(\.label),
            ["me@personal.example", "work"])
    }
}
