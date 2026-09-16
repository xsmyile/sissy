import XCTest

@testable import Sissy

/// How a linked account is named in Settings, and what it falls back to.
///
/// The fallbacks are the substance of the row: only one of the two sources
/// Sissy identifies an account through is measured to answer with a name, so
/// every install has to read correctly without one.
final class LinkedAccountRowTests: XCTestCase {
    private let uuid = "c805523f"

    private func account(
        name: String? = nil,
        email: String? = "davide.tacchini@mastersoft.it",
        organization: String? = "Master Soft Srl"
    ) -> ClaudeWebAccount {
        ClaudeWebAccount(
            id: uuid,
            identity: ClaudeAccountIdentity(
                uuid: uuid,
                email: email,
                name: name,
                organization: organization,
                organizationType: "claude_team",
                rateLimitTier: nil))
    }

    /// The name leads and the address sits beside it, because the address is
    /// what the account is keyed by and the name is what it is recognised by.
    func testANamedAccountLeadsOnItsNameWithTheAddressBeside() {
        let row = LinkedAccountRowSnapshot.make(account(name: "Davide Tacchini"))

        XCTAssertEqual(row.title, "Davide Tacchini")
        XCTAssertEqual(row.address, "davide.tacchini@mastersoft.it")
        XCTAssertEqual(row.organization, "Master Soft Srl")
    }

    /// The row every account had before a name could be read, which is still
    /// every account claude.ai does not name.
    func testAnUnnamedAccountKeepsTheAddressAsItsTitle() {
        let row = LinkedAccountRowSnapshot.make(account())

        XCTAssertEqual(row.title, "davide.tacchini@mastersoft.it")
        XCTAssertNil(row.address)
        XCTAssertEqual(row.organization, "Master Soft Srl")
    }

    /// A row that said the same thing twice would read as two different facts.
    func testTheAddressIsNotRepeatedUnderItself() {
        let row = LinkedAccountRowSnapshot.make(account(name: nil, organization: nil))

        XCTAssertEqual(row.title, "davide.tacchini@mastersoft.it")
        XCTAssertNil(row.address)
        XCTAssertNil(row.organization)
    }

    /// An account the vendor named neither for falls to the organisation, and
    /// then to the uuid it is filed under: a poor label and the only honest
    /// one, and a row under it is what makes that session removable.
    ///
    /// The organisation that became the title takes its caption with it. A row
    /// printing "Master Soft Srl" over "Master Soft Srl" reads as two facts.
    func testAnAccountWithNoAddressFallsToTheOrganisationAndThenTheKey() {
        let organisationOnly = LinkedAccountRowSnapshot.make(account(email: nil))
        XCTAssertEqual(organisationOnly.title, "Master Soft Srl")
        XCTAssertNil(organisationOnly.address)
        XCTAssertNil(organisationOnly.organization)

        let nameless = LinkedAccountRowSnapshot.make(account(email: nil, organization: nil))
        XCTAssertEqual(nameless.title, uuid)
    }

    /// A session filed before anything could name it still gets a row.
    func testAnUnidentifiedSessionIsNamedByItsKey() {
        let row = LinkedAccountRowSnapshot.make(ClaudeWebAccount(id: uuid, identity: nil))

        XCTAssertEqual(row.title, uuid)
        XCTAssertNil(row.address)
        XCTAssertNil(row.organization)
    }
}
