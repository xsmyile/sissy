import XCTest

@testable import Sissy

/// How a linked account is named in Settings, and what it falls back to.
///
/// The row takes the panel's own `AccountNaming`, so these hold the list to
/// being a preview of the panel: the same title, and a caption that says only
/// what the title leaves out.
final class LinkedAccountRowTests: XCTestCase {
    private let uuid = "a1b2c3d4"

    private func row(
        name: String? = nil,
        email: String? = "smyile@example.com",
        organization: String? = "Acme Srl",
        plan: String? = "team",
        naming: AccountNaming = AccountNaming()
    ) -> LinkedAccountRowSnapshot {
        LinkedAccountRowSnapshot.make(
            id: uuid,
            account: ProviderAccount(email: email, name: name, organization: organization),
            plan: plan,
            naming: naming)
    }

    /// A team seat leads on its organisation, with the address under it.
    func testATeamSeatLeadsOnItsOrganisationWithTheAddressUnder() {
        let row = row(name: "Davide")

        XCTAssertEqual(row.title, "Acme Srl")
        XCTAssertEqual(row.subtitle, "smyile@example.com")
    }

    /// A personal plan leads on its owner and never on the organisation
    /// claude.ai generated for it.
    func testAPersonalPlanLeadsOnItsOwnerAndDropsTheGeneratedOrganisation() {
        let row = row(
            name: "Davide", organization: "smyile@example.com's Organization", plan: "max")

        XCTAssertEqual(row.title, "Davide")
        XCTAssertEqual(row.subtitle, "smyile@example.com")
    }

    /// A row that said the same thing twice would read as two different facts.
    func testTheAddressIsNotRepeatedUnderItself() {
        let row = row(organization: nil, plan: "max")

        XCTAssertEqual(row.title, "smyile@example.com")
        XCTAssertNil(row.subtitle)
    }

    /// A rename shows in the list the moment it is made, with everything the
    /// new name leaves out under it.
    func testARenameTakesTheTitleAndKeepsTheRestUnder() {
        var naming = AccountNaming()
        naming.rename(uuid, to: "Radon")

        let row = row(naming: naming)

        XCTAssertEqual(row.title, "Radon")
        XCTAssertEqual(row.subtitle, "smyile@example.com · Acme Srl")
    }

    /// A credential filed before anything could name it still gets a row,
    /// under the key it is filed by.
    func testAnUnidentifiedAccountIsNamedByItsKey() {
        let row = LinkedAccountRowSnapshot.make(
            id: uuid, account: nil, plan: nil, naming: AccountNaming())

        XCTAssertEqual(row.title, uuid)
        XCTAssertNil(row.subtitle)
    }
}
