import XCTest

@testable import Sissy

final class AboutTests: XCTestCase {
    func testBundleExposesTheCopyrightAboutRenders() {
        XCTAssertFalse(
            Bundle.main.humanReadableCopyright.isEmpty,
            "NSHumanReadableCopyright is what About shows; an empty value blanks the line"
        )
    }

    /// Sparkle ships inside the app, and the BSD terms among its licences ask
    /// for the notice to travel with the binary, so the sheet renders a
    /// bundled copy rather than a link. `CREDITS.md` credits what Sissy reads
    /// and is not an obligation, so it stays out of the bundle.
    func testSparkleNoticeShipsAsAnAppResource() throws {
        let text = try XCTUnwrap(
            ThirdPartyNotices.text(),
            "THIRD-PARTY-NOTICES.md is missing from the app bundle. Re-run xcodegen generate."
        )
        XCTAssertTrue(text.contains("Andy Matuschak"), "Expected Sparkle's copyright to be reproduced")
        XCTAssertTrue(text.contains("EXTERNAL LICENSES"), "Expected Sparkle's external licences too")
        XCTAssertNil(Bundle.main.url(forResource: "CREDITS", withExtension: "md"))
    }
}
