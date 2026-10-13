import XCTest

@testable import Sissy

/// What each format calls an account, and what a rename does to it.
final class AccountNamingTests: XCTestCase {
    private let team = ProviderAccount(
        email: "davide@acme.example", name: "Davide", organization: "Acme Srl")
    private let personal = ProviderAccount(
        email: "davide@example.com", name: "Davide",
        organization: "davide@example.com's Organization")

    func testAutomaticNamesATeamSeatByItsOrganisationAndAPersonalPlanByItsOwner() {
        let naming = AccountNaming()

        XCTAssertEqual(naming.name(id: "a", account: team, plan: "team"), "Acme Srl")
        XCTAssertEqual(naming.name(id: "b", account: personal, plan: "max"), "Davide")
    }

    /// An owner the vendor named nothing for is called by the address.
    func testAPersonalPlanWithNoNameFallsToTheAddress() {
        let account = ProviderAccount(email: "davide@example.com", organization: "Org")

        XCTAssertEqual(
            AccountNaming().name(id: "a", account: account, plan: "pro"), "davide@example.com")
    }

    /// An unknown plan is not evidence of an organisation, so its name is not
    /// promoted over the person's.
    func testAnUnknownPlanDoesNotLeadOnTheOrganisation() {
        XCTAssertEqual(AccountNaming().name(id: "a", account: team, plan: nil), "Davide")
    }

    func testEmailNamesEveryAccountByItsAddress() {
        let naming = AccountNaming(format: .email)

        XCTAssertEqual(naming.name(id: "a", account: team, plan: "team"), "davide@acme.example")
        XCTAssertEqual(naming.name(id: "b", account: personal, plan: "max"), "davide@example.com")
    }

    func testNameAndOrganisationAddsTheOrganisationOnlyForATeamSeat() {
        let naming = AccountNaming(format: .nameAndOrganization)

        XCTAssertEqual(naming.name(id: "a", account: team, plan: "team"), "Davide · Acme Srl")
        XCTAssertEqual(naming.name(id: "b", account: personal, plan: "max"), "Davide")
    }

    func testARenameWinsOverEveryFormatAndABlankOneHandsTheAccountBack() {
        var naming = AccountNaming(format: .email)
        naming.rename("a", to: "  Work  ")
        XCTAssertEqual(naming.name(id: "a", account: team, plan: "team"), "Work")

        naming.rename("a", to: " ")
        XCTAssertEqual(naming.name(id: "a", account: team, plan: "team"), "davide@acme.example")
        XCTAssertTrue(naming.custom.isEmpty)
    }

    func testTheDetailCarriesOnlyWhatTheNameLeavesOut() {
        let naming = AccountNaming()

        XCTAssertEqual(
            naming.detail(name: "Acme Srl", account: team, plan: "team"), "davide@acme.example")
        XCTAssertNil(naming.detail(name: "davide@example.com", account: personal, plan: "max"))
        XCTAssertEqual(
            naming.detail(name: "Work", account: team, plan: "team"),
            "davide@acme.example · Acme Srl")
    }

    /// Nothing the vendor answered names the account, so the caller falls
    /// back to its own key.
    func testAnAccountNothingNamesHasNoName() {
        XCTAssertNil(AccountNaming().name(id: "a", account: nil, plan: "team"))
    }
}
