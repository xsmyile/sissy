import XCTest

@testable import Sissy

/// What two letters a credential row's disc is drawn with, which is the whole
/// of what tells one account from another in a list where every row carries
/// the same provider and often the same person's name.
final class CredentialMonogramTests: XCTestCase {
    /// The case the disc exists for: one person, two seats, told apart by the
    /// organisation rather than by a name that reads the same on both rows.
    func testAnOrganisationGivesOneLetterPerWord() {
        XCTAssertEqual(CredentialMonogram.initials(of: "Master Soft Srl"), "MS")
        XCTAssertEqual(CredentialMonogram.initials(of: "Radon Forge"), "RF")
    }

    func testASingleWordGivesOneLetter() {
        XCTAssertEqual(CredentialMonogram.initials(of: "Davide"), "D")
    }

    /// An address is the person's, its domain is their mail provider's, so a
    /// monogram off the whole spelling names the wrong party.
    func testAnAddressIsReadToItsLocalPart() {
        XCTAssertEqual(CredentialMonogram.initials(of: "openai@davidet.com"), "O")
        XCTAssertEqual(CredentialMonogram.initials(of: "davide.tacchini@mastersoft.it"), "DT")
    }

    /// An account filed before anything could name it is titled by its uuid,
    /// whose letter runs are the initials of nothing. Empty is the answer that
    /// sends the view to its glyph.
    func testAUUIDMonogramsNothing() {
        XCTAssertEqual(CredentialMonogram.initials(of: "7c31482a-768d-4750-8521-cd39b2669767"), "")
    }

    func testNothingAtAllMonogramsNothing() {
        XCTAssertEqual(CredentialMonogram.initials(of: ""), "")
    }
}
