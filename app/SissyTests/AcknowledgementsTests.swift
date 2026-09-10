import XCTest

@testable import Sissy

final class AcknowledgementsTests: XCTestCase {
    func testNoticesShipAsAnAppResource() throws {
        let text = try XCTUnwrap(
            ThirdPartyNotices.text(),
            "THIRD-PARTY-NOTICES.md is missing from the app bundle. Re-run xcodegen generate."
        )

        XCTAssertTrue(text.contains("Apache License"), "Expected the Apache 2.0 text to be reproduced")
        XCTAssertTrue(text.contains("The SwiftNIO Project"), "Expected SwiftNIO's NOTICE to be reproduced")
    }

    func testBundleExposesTheCopyrightAboutRenders() {
        XCTAssertFalse(
            Bundle.main.humanReadableCopyright.isEmpty,
            "NSHumanReadableCopyright is what About shows; an empty value blanks the line"
        )
    }
}
