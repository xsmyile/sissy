import ServiceManagement
import XCTest

@testable import Sissy

@MainActor
final class LoginItemControllerTests: XCTestCase {
    private static let absentPlist = "com.radonforge.sissy.tests.absent.plist"

    private func error(_ code: Int) -> NSError {
        NSError(domain: "SMAppServiceErrorDomain", code: code)
    }

    func testAServiceThatIsNotThereReportsNeitherEnabledNorPendingApproval() {
        let controller = LoginItemController(service: .agent(plistName: Self.absentPlist))

        controller.refresh()

        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(controller.requiresApproval)
    }

    func testAlreadyRegisteredIsSuccessWhenEnabling() {
        let alreadyRegistered = error(kSMErrorAlreadyRegistered)

        XCTAssertTrue(
            LoginItemController.isAlreadyInRequestedState(alreadyRegistered, enabling: true))
        XCTAssertFalse(
            LoginItemController.isAlreadyInRequestedState(alreadyRegistered, enabling: false))
    }

    func testJobNotFoundIsSuccessWhenDisabling() {
        let jobNotFound = error(kSMErrorJobNotFound)

        XCTAssertTrue(
            LoginItemController.isAlreadyInRequestedState(jobNotFound, enabling: false))
        XCTAssertFalse(
            LoginItemController.isAlreadyInRequestedState(jobNotFound, enabling: true))
    }

    func testEveryOtherFailureIsARealFailure() {
        let invalidSignature = error(kSMErrorInvalidSignature)

        XCTAssertFalse(
            LoginItemController.isAlreadyInRequestedState(invalidSignature, enabling: true))
        XCTAssertFalse(
            LoginItemController.isAlreadyInRequestedState(invalidSignature, enabling: false))
    }
}
