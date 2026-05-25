import XCTest

@testable import Sissy

final class ServiceManagementPackagingTests: XCTestCase {
    func testBundledLaunchAgentUsesServiceManagementLayout() throws {
        let appBundle = Bundle.main.bundleURL
        let plistURL = appBundle.appendingPathComponent(
            "Contents/Library/LaunchAgents/\(ServerServiceController.plistName)"
        )
        let daemonURL = appBundle.appendingPathComponent("Contents/MacOS/sissy-serverd")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: plistURL.path),
            "Expected LaunchAgent plist at \(plistURL.path)"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: daemonURL.path),
            "Expected bundled daemon at \(daemonURL.path)"
        )

        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["Label"] as? String, ServerServiceController.label)
        XCTAssertEqual(plist["BundleProgram"] as? String, "Contents/MacOS/sissy-serverd")
        XCTAssertTrue(ServerServiceController.bundledLaunchAgentIsPresent(in: appBundle))
    }

    func testCodesigningFailureIsRecognized() {
        let error = NSError(
            domain: "NSOSStatusErrorDomain",
            code: -67056,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Codesigning failure loading plist: com.radonforge.sissy.server.plist code: -67056"
            ]
        )

        XCTAssertTrue(ServerServiceController.isCodesignFailure(error))
    }
}
