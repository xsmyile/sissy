import XCTest

@testable import Sissy

final class AboutTests: XCTestCase {
    func testBundleExposesTheCopyrightAboutRenders() {
        XCTAssertFalse(
            Bundle.main.humanReadableCopyright.isEmpty,
            "NSHumanReadableCopyright is what About shows; an empty value blanks the line"
        )
    }

    /// The acknowledgements sheet used to render a bundled copy of the
    /// licence text, because SwiftNIO shipped inside the app. Nothing
    /// third-party ships now, so nothing should be bundled for it either —
    /// a stray copy would be a file claiming an obligation Sissy no longer
    /// has.
    func testNoLicenceTextIsBundled() {
        XCTAssertNil(Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md"))
        XCTAssertNil(Bundle.main.url(forResource: "CREDITS", withExtension: "md"))
    }
}
